# Engine protocol (version 3)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests arrive on stdin. Responses and notifications leave on stdout and may
interleave, so clients match responses by `id`. Logs go to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
```

Run it in the pull request's worktree. `--poll` defaults to 60 seconds, and
`--poll 0` turns background syncing off. While it polls, the server also
resends queued viewed marks and queued comment operations every 20 seconds
between syncs. Every sync sends queued viewed marks before pulling, and
reconciles and replays queued comment operations once the pull succeeds. The
server does not sync on its own at startup: until the first sync, `snapshot`
returns what was saved last.

## Handshake

The client sends `initialize` first and compares `protocolVersion` with its
own. On a mismatch it stops the server and tells the user to install the
plugin and the engine from the same checkout.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 3, "client": "..." }` (the server reads neither) | `{ "protocolVersion": 3, "version": "0.3.0" }` |
| `snapshot` | none | `SessionView` |
| `sync` | none | `SessionView`; error `-32000` when GitHub fails, after a `syncFailed` event |
| `fileDiff` | `{ "path": "src/a.rs" }` | `FileDiffView`; error `-32000` for a file the pull request does not change, a side over 4 MiB, or before the first sync |
| `stream` | `{ "mode": "unified" \| "split" }` | `StreamView`; error `-32000` before the first sync |
| `setViewed` | `{ "path": "src/a.rs", "viewed": true }` | `SessionView`, after a `viewedChanged` event |
| `threads` | none | `{ "threads": Thread[] }` |
| `mentions` | none | `{ "candidates": MentionCandidate[] }` |
| `comment` | `{ "anchor": Anchor, "body": "..." }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `reply` | `{ "threadId": "...", "body": "..." }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `editMessage` | `{ "messageId": "...", "body": "..." }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `deleteMessage` | `{ "messageId": "..." }` | `SessionView`, after a `threadsChanged` event |
| `setResolved` | `{ "threadId": "...", "resolved": true \| false }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `toggleReaction` | `{ "messageId": "...", "content": ReactionContent }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `retryMessage` | `{ "messageId": "..." }` | `SessionView`, after a `threadsChanged` event |
| `anchoredLines` | `{ "anchor": Anchor }` | `{ "text": "..." }`; error `-32000` for `file`/`pr` anchors, invalid bounds, binary files, or before the first sync |
| `suggestFromEdit` | `{ "path": "src/a.rs", "editedText": "...", "cursorLine": 1, "commentBody": "..." \| null }` (`commentBody` optional) | `{ "suggested": SuggestedEdit, "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `submitPreview` | none | `SubmitPreview`; error `-32000` before the first sync |
| `submitReview` | `{ "event": ReviewEvent, "body": "..." \| null }` (`body` optional, defaults to `""`) | `SessionView`, after a `threadsChanged` event |
| `shutdown` | none | `null`; the server stops reading and exits |

The server also exits when stdin closes. Methods without params ignore them,
so `null`, `{}` or a missing `params` all work. `setViewed` succeeds even when
GitHub refuses the mark: the mark stands, is counted in `queuedCount`, and is
sent again by later retries and syncs.

Comment mutations behave consistently offline and on errors:

- `comment`, `reply`, `editMessage` return `-32000` if `body` is blank or before
  the first sync. `comment` creates a draft thread in the pending review for
  `line`/`range`/`file` anchors, and a published PR comment for `pr` anchors.
  `reply` posts immediately via REST when no pending review is active, or adds a
  draft reply when one is active.
- Transient forge failures on `comment`, `reply`, `editMessage`, `deleteMessage`,
  `setResolved`, `toggleReaction`, and `submitReview` queue the operation in
  `github.json` (assigning optimistic `tmp-*` ids and `sync: "queued"` where
  applicable) and succeed locally; `queuedCount` includes both queued viewed
  marks and queued comment operations.
- Forge validation rejections on `comment`, `reply`, and `editMessage` record an
  optimistic message with `sync: "failed"` and `syncError` so the reviewer can
  edit, retry (`retryMessage`), or delete it; rejections on `deleteMessage`,
  `setResolved`, and `toggleReaction` revert optimistic state and return
  `-32000`.
- `setResolved` refuses `pr` conversation threads with `-32000`.
- `submitReview` returns `-32000` if any comment is `pending`, `queued`, or
  `failed`, if a review submission or other comment operation is already queued,
  if `APPROVE` or `REQUEST_CHANGES` is requested on the viewer's own pull
  request, or if a zero-draft `COMMENT` or `REQUEST_CHANGES` review has an empty
  `body`.

## Notifications (server to client)

`event`, with one of:

```json
{ "type": "synced", "view": SessionView }
{ "type": "syncFailed", "message": "gh timed out after 30s" }
{ "type": "viewedChanged", "view": SessionView }
{ "type": "threadsChanged", "view": SessionView }
```

Every sync announces `synced` or `syncFailed`, whether a `sync` request or the
background poller started it. `viewedChanged` follows every `setViewed` and
every retry that got a queued mark through. `threadsChanged` follows every
comment mutation (`comment`, `reply`, `editMessage`, `deleteMessage`,
`setResolved`, `toggleReaction`, `retryMessage`, `suggestFromEdit`,
`submitReview`) and every background retry that got a queued comment operation
through. A sync whose pull fails after it got a queued mark through announces
`viewedChanged` before `syncFailed`; a sync that succeeds announces the shorter
queue in `synced`. An event is written before the response to the request that
caused it, and every event is written before the `shutdown` response.

## Types

`SessionView`:

```json
{
  "pr": { "owner": "octo", "repo": "widgets", "number": 7, "title": "Fix the widget",
          "url": "https://github.com/octo/widgets/pull/7", "nodeId": "PR_7", "author": "alice",
          "headRef": "fix/widget", "headSha": "abc123", "baseRef": "main", "baseSha": "base000" },
  "files": [ { "path": "src/a.rs", "additions": 12, "deletions": 3, "viewed": "VIEWED", "threads": 2 } ],
  "tree": [ { "depth": 0, "name": "src", "file": null }, { "depth": 1, "name": "a.rs", "file": 0 } ],
  "viewedCount": 1,
  "threadCount": 2,
  "draftCount": 1,
  "conversationCount": 1,
  "queuedCount": 0,
  "sync": { "state": "synced", "at": 1763510400 }
}
```

- `pr` is `null` until the first successful sync.
- `viewed` is `VIEWED`, `UNVIEWED` or `DISMISSED` (viewed, then changed on GitHub).
- `tree` is `files` drawn as a tree, in drawing order: directories first, then
  files, each sorted by name. A directory holding only one directory is joined
  to it (`"name": "docs/x"`). A file row's `file` is its index in `files`; a
  directory's is `null`.
- `threadCount` counts code-anchored review threads (excluding `pr` conversation
  threads).
- `draftCount` counts messages with `sync: "draft"` across all threads.
- `conversationCount` counts top-level PR conversation threads (`anchor.kind`
  equal to `"pr"`).
- `queuedCount` counts viewed marks and comment operations waiting for GitHub.
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.

`Anchor`:

```json
{
  "file": "src/a.rs",
  "kind": "line",
  "side": "RIGHT",
  "start": 2,
  "end": 2,
  "commit": "abc123",
  "snapshot": "let x = 2;"
}
```

- `kind` is `"line"`, `"range"`, `"file"`, or `"pr"`.
- `side` is `"LEFT"` (old file / merge base) or `"RIGHT"` (new file).
- `file` is `null` for `"pr"` anchors; `start` and `end` are 1-based line
  numbers for `"line"` and `"range"` anchors (`null` for `"file"` and `"pr"`).
- `commit` and `snapshot` are optional when sending an `Anchor` in a request.

`ReactionContent` and `Reaction`:

- `ReactionContent` is one of `"THUMBS_UP"`, `"THUMBS_DOWN"`, `"LAUGH"`,
  `"HOORAY"`, `"CONFUSED"`, `"HEART"`, `"ROCKET"`, or `"EYES"`.
- `Reaction` is `{ "content": ReactionContent, "count": 1, "viewerHasReacted": true }`.

`Message`:

```json
{
  "id": "PRRC_1",
  "author": "alice",
  "body": "nit: rename this",
  "created": "2026-11-20T00:00:00Z",
  "updated": "2026-11-20T00:00:00Z",
  "sync": "published",
  "viewerDidAuthor": false,
  "databaseId": "123456",
  "reactions": [ { "content": "THUMBS_UP", "count": 1, "viewerHasReacted": true } ]
}
```

- `sync` is `"draft"`, `"pending"`, `"published"`, `"failed"`, or `"queued"`, and
  is omitted for local threads (`origin: "local"`).
- `databaseId` (decimal string for REST thread replies), `syncError` (present
  when `sync` is `"failed"`), `recoverableBody` (local edit text preserved when
  a concurrent forge edit won), and empty `reactions` are omitted when absent.

`Thread`:

```json
{
  "id": "PRRT_1",
  "origin": "github",
  "anchor": { "file": "src/a.rs", "kind": "line", "side": "RIGHT", "start": 2, "end": 2, "commit": null, "snapshot": null },
  "state": "open",
  "outdated": false,
  "messages": [ Message ]
}
```

- `origin` is `"github"` or `"local"`; `state` is `"open"` or `"resolved"`.

`ThreadPreview`:

```json
{
  "threadId": "PRRT_1",
  "anchor": Anchor,
  "displayLine": 2,
  "kind": "published",
  "state": "open",
  "outdated": false,
  "messageCount": 1,
  "firstAuthor": "alice",
  "snippet": "nit: rename this",
  "messages": [ Message ]
}
```

- `displayLine` is the 1-based line in the current file where a unified overlay
  places the marker, or `0` for a file-level thread.
- `kind` is `"published"`, `"draft"` (draft, pending, or queued), `"failed"`, or
  `"local"`.

`MentionCandidate`:

```json
{ "login": "alice", "isParticipant": true }
```

`ReviewEvent`, `SubmitPreview`, and `SuggestedEdit`:

- `ReviewEvent` is `"COMMENT"`, `"APPROVE"`, or `"REQUEST_CHANGES"`.
- `SubmitPreview`:

```json
{
  "draftCount": 1,
  "drafts": [
    {
      "threadId": "PRRT_1",
      "messageId": "PRRC_1",
      "anchor": Anchor,
      "snippet": "nit: rename this"
    }
  ],
  "canApproveOrRequestChanges": true,
  "blockedReason": null
}
```

- `SuggestedEdit`:

```json
{
  "anchor": Anchor,
  "suggestionBody": "```suggestion\nlet x = 2;\n```",
  "revertedText": "let x = 1;\n"
}
```

`FileDiffView`, one file against the merge base of its base commit and the
checked-out head; the current side is the file on disk:

```json
{
  "path": "src/a.rs",
  "binary": false,
  "baseText": "fn main() {\nlet x = 1;\n}\n",
  "added": [ { "line": 2, "words": [ { "start": 8, "end": 9 } ] } ],
  "removed": [ { "above": 2, "lines": [ { "text": "let x = 1;", "words": [ { "start": 8, "end": 9 } ] } ] } ],
  "threads": [ ThreadPreview ]
}
```

- Line numbers count from 1 in the current file. `above` is the line a block
  of removed lines sits above; one past the last line means after the end.
- `words` are byte ranges (`end` exclusive) of the words that changed inside
  an edited line; a line that was replaced rather than edited has none.
- `baseText` is `null` for an added file or a binary one; `binary` files have
  no `added` or `removed` lines.
- `threads` holds `ThreadPreview` entries anchored on `path`.

`StreamView`:

```json
{
  "mode": "split",
  "rows": [
    { "kind": "file", "path": "src/a.rs", "additions": 1, "deletions": 1, "viewed": "UNVIEWED", "folded": false },
    { "kind": "thread", "path": "README.md", "thread": ThreadPreview, "target": 1 },
    { "kind": "hunk", "path": "src/a.rs", "header": "@@ -1,3 +1,3 @@", "target": 1 },
    { "kind": "line", "path": "src/a.rs", "target": 1,
      "left":  { "line": 1, "text": "fn main() {", "change": "context", "words": [] },
      "right": { "line": 1, "text": "fn main() {", "change": "context", "words": [] } },
    { "kind": "line", "path": "src/a.rs", "target": 2,
      "left":  { "line": 2, "text": "let x = 1;", "change": "removed", "words": [ { "start": 8, "end": 9 } ] },
      "right": { "line": 2, "text": "let x = 2;", "change": "added", "words": [ { "start": 8, "end": 9 } ] },
      "threads": [ ThreadPreview ] },
    { "kind": "note", "path": "logo.png", "text": "binary file" }
  ]
}
```

- Files come in GitHub's order; each starts with a `file` row. Viewed files
  have `folded: true`.
- File-level threads and threads whose anchored line is outside the visible
  hunks appear as `thread` rows right after their `file` row. Line- and
  range-anchored threads inside hunks appear in `threads` on their matching
  `line` row (`threads` is omitted when empty).
- Hunks carry 3 lines of context. In `unified` mode a changed block's removed
  rows (only `left`) come before its added rows (only `right`); context rows
  have both. In `split` mode a removed and an added line share a row, and a
  `null` side is filler that keeps the columns aligned.
- `target` is the current-file line a client jumps to from the row.
- A `note` stands in for lines that cannot be shown: `binary file`,
  `no changes against the base`, or `could not read this file: ...`.

## Errors

| Code | Meaning |
| --- | --- |
| -32700 | The line is not JSON (the response `id` is `null`) |
| -32600 | Not a request: no string `method`, or no `id` (the response `id` is `null` when there was none) |
| -32601 | Unknown method |
| -32602 | Invalid params: a missing or mistyped param (`path`, `viewed`, `mode`, `anchor`, `content`, `event`, `cursorLine`, etc.) |
| -32000 | The engine could not do it; `message` says why |

## Versioning

Change `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and
`M.PROTOCOL_VERSION` in `lua/jpr/rpc.lua` together whenever a request, a
result or an event changes shape, and update this document in the same commit.

- **Version 2** added `fileDiff`, `stream`, `setViewed`, the `viewedChanged`
  event, and `tree`, `queuedCount` and `pr.baseSha` in `SessionView`.
- **Version 3** added `threads`, `mentions`, `comment`, `reply`, `editMessage`,
  `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`,
  `anchoredLines`, `suggestFromEdit`, `submitPreview`, `submitReview`, the
  `threadsChanged` event, `draftCount` and `conversationCount` in `SessionView`,
  `threads` in `FileDiffView`, `thread` rows and `line.threads` in
  `StreamView`, and the `ThreadPreview`, `Reaction`, `ReactionContent`,
  `MentionCandidate`, `SubmitPreview`, `SuggestedEdit`, and `ReviewEvent` types.
