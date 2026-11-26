# Engine protocol (version 10)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests from the primary frontend arrive on stdin. Responses and notifications
leave on stdout and may interleave, so clients match responses by `id`. Logs go
to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
jpr-review serve --local [--base <ref>] [--repo <owner/name>] [--poll <seconds>]
```

Run it in the pull request's or local branch's worktree. `--poll` defaults to
60 seconds, and `--poll 0` turns background syncing off. While it polls a
linked PR session, the server also resends queued viewed marks and queued
comment operations every 20 seconds between syncs, and watches tracked worktree
files and git status every 2 seconds for on-disk and commit changes. In
`--local` mode (unlinked), background GitHub sync and retry polling stay off
until the session links to a PR, while the 2-second worktree watcher still
runs. Every PR sync sends queued viewed marks before pulling, and reconciles
and replays queued comment operations once the pull succeeds. In `--local`
mode, `snapshot` immediately returns the worktree's changed files against
`baseRef` (`localContext` set, `pr: null`), and `sync` probes GitHub via
`gh pr view` to upgrade the live session in-place when an open PR is found
(promoting locally `VIEWED` files to GitHub).

## Unix socket transport

Alongside stdio, `jpr-review serve` binds a Unix domain socket (`0600`
permissions) and records its path in `session.json` (`socket`). When Neovim
spawns the interactive agent terminal, it exports that path as `JPR_SOCKET`.

- Only an allowlisted set of methods is accepted over the socket: `snapshot`,
  `threads`, `agentReply`, and `prepassWrite`.
- Any other method (including `shutdown`, `initialize`, `sync`, `push`,
  `submitReview`, `promoteThread`, `confirmSend`,
  `prepareConflictResolution`, and `refreshWorktree`) is refused over the
  socket with `-32600` (`INVALID_REQUEST`).
- After a socket request runs, any events it produced (such as
  `threadsChanged`) are flushed immediately to the stdio client before the
  socket reply is written.

## Handshake

The client sends `initialize` first and compares both `protocolVersion` and
`version` with its own (`"test"` is accepted as `version` in test fixtures). On
a mismatch it stops the server and tells the user to rebuild the bundled engine
with `:Lazy build jpr-nvim`.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 10, "client": "..." }` (the server reads neither) | `{ "protocolVersion": 10, "version": "0.8.0" }` |
| `snapshot` | none | `SessionView` (carries `localContext` when unlinked, `pr` when linked) |
| `sync` | none | `SessionView`; in PR mode, error `-32001` (`AUTH_REQUIRED`) when `gh` is unauthenticated or `-32000` when GitHub fails otherwise, after a `syncFailed` event (announces `headMoved` before `synced` when `pr.headSha` changes); in local mode, probes `gh pr view` and upgrades the live session in-place if an open PR exists (promoting locally `VIEWED` files to GitHub), returns `-32001` when `gh` is unauthenticated, or returns an informational `-32000` error without `syncFailed` when no open PR exists yet |
| `push` | none | `PushResult`; pushes `HEAD` to `refs/heads/<headRef>` (stdio-only; refused over `JPR_SOCKET` with `-32600`); error `-32000` before the first sync, when local `HEAD` is behind or already at the remote head, when a cross-repository (`pr.isCrossRepository`) pull request lacks explicit fork tracking or targets the base repository, or when `git push` fails |
| `fileDiff` | `{ "path": "src/a.rs" }` | `FileDiffView`; error `-32000` for a file the pull request does not change, a side over 4 MiB, or before the first sync |
| `stream` | `{ "mode": "unified" \| "split" }` | `StreamView` (emits `streamProgress` notifications per file while running); error `-32000` before the first sync |
| `setViewed` | `{ "path": "src/a.rs", "viewed": true }` or `{ "paths": ["src/a.rs", "src/b.rs"], "viewed": true }` (provide exactly one of `path` or non-empty `paths`) | `SessionView`, after one `viewedChanged` event |
| `threads` | none | `{ "threads": Thread[] }` |
| `mentions` | none | `{ "candidates": MentionCandidate[] }` |
| `comment` | `{ "anchor": Anchor, "body": "...", "origin"?: "github" \| "local" }` (`origin` optional, defaults to `"github"`) | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
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
| `agentReply` | `{ "threadId": "...", "body": "...", "author"?: "..." \| null }` (`author` optional, defaults to `"agent"`) | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event; refuses GitHub threads with `-32000` |
| `promoteThread` | `{ "threadId": "...", "body": "..." }` | `{ "thread": Thread, "view": SessionView }`, after a `threadsChanged` event |
| `prepareAgentLaunch` | `{ "agent"?: "claude" \| "codex" \| null }` (`agent` optional, defaults to `"claude"`) | `AgentLaunchPlan` |
| `prepareSend` | `{ "threadId"?: "..." \| null, "agent"?: "claude" \| "codex" \| null }` (both optional) | `AgentDispatch`; error `-32000` if no unsent local thread matches or before the first sync |
| `confirmSend` | `{ "round": 1, "kind": "send" \| "prepass" \| "conflict", "threadIds": string[], "prompt": "..." }` | `{ "round": AgentRound, "view": SessionView }`, after `threadsChanged` (when `"send"` updates threads) and `agentRound` events (stdio-only; `"send"` requires non-empty `threadIds`, while `"prepass"` and `"conflict"` require `threadIds: []`) |
| `preparePrepass` | `{ "agent"?: "claude" \| "codex" \| null }` (`agent` optional, defaults to `"claude"`) | `AgentDispatch`; error `-32000` before the first sync |
| `prepareConflictResolution` | `{ "paths": string[], "agent"?: "claude" \| "codex" \| null }` (`agent` optional, defaults to `"claude"`) | `AgentDispatch` (`kind: "conflict"`, `threadIds: []`; stdio-only, refused over `JPR_SOCKET` with `-32600`); error `-32000` for empty or unsafe `paths` or before the first sync |
| `prepassWrite` | `{ "findings": PrepassFinding[] }` | `{ "threads": Thread[], "view": SessionView }`, after a `threadsChanged` event when threads are created |
| `updateLocalAnchors` | `{ "path": "src/a.rs", "updates": LocalAnchorUpdate[] }` | `SessionView`, after a `threadsChanged` event when any local anchor moves |
| `refreshWorktree` | `{ "renames"?: [{ "oldPath": string, "newPath": string }] }` (optional) | `SessionView`, after migrating local thread anchors and `localViewed` entries for `renames`, refreshing local worktree files/digests/status, and emitting `threadsChanged`, `filesChanged`, or `worktreeStatusChanged` when applicable (stdio-only; refused over `JPR_SOCKET` with `-32600`) |
| `shutdown` | none | `null`; the server stops reading and exits (refused over Unix socket) |

The server also exits when stdin closes. Methods without params ignore them,
so `null`, `{}` or a missing `params` all work. `push`,
`prepareConflictResolution`, `confirmSend`, and `refreshWorktree` are
stdio-only and rejected over the Unix domain socket (`JPR_SOCKET`) with
`-32600`. `setViewed` succeeds even when GitHub refuses the mark: the mark
stands, is counted in `queuedCount`, and is sent again by later retries and
syncs. For local-only worktree files (`isLocalOnly: true`), `setViewed` updates
`local.json` (`localViewed`) without calling GitHub.

Comment mutations behave consistently offline and on errors:

- `comment`, `reply`, `editMessage` return `-32000` if `body` is blank or (for
  GitHub threads) before the first sync. With `origin: "github"` (default),
  `comment` creates a draft thread in the pending review for
  `line`/`range`/`file` anchors, and a published PR comment for `pr` anchors;
  GitHub comments, `promoteThread`, and `suggestFromEdit` refuse local-only
  worktree files (`isLocalOnly: true`) with `-32000` until those files are
  pushed to GitHub. With `origin: "local"`, `comment`, `reply`, `editMessage`,
  `deleteMessage`, `setResolved`, and `toggleReaction` accept both PR files and
  local-only worktree files, updating `local.json` only and never calling
  GitHub (`retryMessage` refuses local messages with `-32000`).
- `reply` on a GitHub thread posts immediately via REST when no pending review
  is active, or adds a draft reply when one is active.
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
{ "type": "syncFailed", "message": "gh timed out after 30s", "authRequired": false, "isBackground": false }
{ "type": "viewedChanged", "view": SessionView }
{ "type": "threadsChanged", "view": SessionView }
{ "type": "filesChanged", "paths": ["src/a.rs"], "view": SessionView }
{ "type": "agentRound", "round": AgentRound, "view": SessionView }
{ "type": "worktreeStatusChanged", "view": SessionView }
{ "type": "headMoved", "previousSha": "abc123", "headSha": "def456", "outcome": HeadMoveOutcome, "conflictedPaths": [], "message": "...", "view": SessionView }
```

Every sync announces `synced` or `syncFailed`, whether a `sync` request or the
background poller started it. `syncFailed` sets `authRequired: true` when `gh`
failed due to missing or expired GitHub authentication, and `isBackground: true`
when triggered by the background poller rather than an explicit client `sync`
request (allowing frontends to suppress unsolicited background auth modals
while still prompting on foreground actions). When a sync sees `pr.headSha` change (or retries
a prior `"failed"` head move), it reconciles the local checkout and announces
`headMoved` (`message` is omitted when absent) before `synced`. `viewedChanged`
follows every `setViewed` and every retry that got a queued mark through.
`threadsChanged` follows every comment mutation (`comment`, `reply`,
`editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`,
`suggestFromEdit`, `submitReview`, `agentReply`, `promoteThread`, `prepassWrite`
when creating threads, `confirmSend` when thread states change, and
`updateLocalAnchors` when any local anchor changes), every background retry
that got a queued comment operation through, and worktree file-watcher ticks
(`filesChanged`) that re-anchor local threads (local thread re-anchoring during
a head move is carried by `headMoved` and `synced`). `filesChanged` follows
worktree file-watcher ticks when tracked files change on disk;
`worktreeStatusChanged` follows worktree watcher ticks when `worktreeStatus`
changes without tracked PR file digest changes (for example after `git commit`
or `git reset`). `agentRound` follows `confirmSend`. A sync whose pull fails
after it got a queued mark through announces `viewedChanged` before
`syncFailed`; a sync that succeeds announces the shorter queue in `synced`. An
event is written before the response to the request that caused it, and every
event is written before the `shutdown` response.

`streamProgress`, emitted directly (outside the `event` envelope) while a
`stream` request executes on stdio, before the `stream` response arrives:

```json
{ "completed": 1, "total": 20, "path": "src/a.rs" }
```

- When the pull request has at least one changed file, the server emits an
  initial `{ "completed": 0, "total": N, "path": "" }` notification before
  reading files, followed by one notification per file as it completes
  (`completed` from `1` to `total`, with that file's repository-relative
  `path`).
- Pull requests with zero changed files emit no `streamProgress` notifications.

## Types

`SessionView`, `FileRow`, and `WorktreeStatus`:

```json
{
  "pr": { "owner": "octo", "repo": "widgets", "number": 7, "title": "Fix the widget",
          "url": "https://github.com/octo/widgets/pull/7", "nodeId": "PR_7", "author": "alice",
          "headRef": "fix/widget", "headSha": "abc123", "baseRef": "main", "baseSha": "base000",
          "isCrossRepository": false },
  "files": [ { "path": "src/a.rs", "additions": 12, "deletions": 3, "viewed": "VIEWED", "threads": 2, "isModified": false, "localThreads": 1, "isLocalOnly": false } ],
  "tree": [ { "depth": 0, "name": "src", "file": null }, { "depth": 1, "name": "a.rs", "file": 0 } ],
  "viewedCount": 1,
  "threadCount": 2,
  "draftCount": 1,
  "conversationCount": 1,
  "localUnsentCount": 0,
  "queuedCount": 0,
  "sync": { "state": "synced", "at": 1763510400 },
  "worktreeStatus": { "isDirty": false, "ahead": 0, "behind": 0, "modifiedPaths": [] }
}
```

- `pr` is `null` until the first successful sync; `pr.isCrossRepository` is
  `true` when the pull request's head branch lives in a fork repository.
- Each `FileRow` in `files` carries `viewed` (`VIEWED`, `UNVIEWED`, or
  `DISMISSED` when viewed and later changed on GitHub or edited on disk for a
  local-only file), `threads` (all GitHub and local threads anchored to
  `path`), `isModified` (`true` when `path` has uncommitted local changes in
  `worktreeStatus.modifiedPaths`), `localThreads` (open or resolved
  `origin: "local"` threads anchored to `path`), and `isLocalOnly` (`boolean`,
  `#[serde(default)]`; `true` when `path` exists only in the local worktree and
  has not been pushed to the pull request yet).
- `tree` is `files` drawn as a tree, in drawing order: directories first, then
  files, each sorted by name. A directory holding only one directory is joined
  to it (`"name": "docs/x"`). A file row's `file` is its index in `files`; a
  directory's is `null`.
- `threadCount` counts code-anchored review threads (excluding `pr` conversation
  threads).
- `draftCount` counts messages with `sync: "draft"` across all threads.
- `conversationCount` counts top-level PR conversation threads (`anchor.kind`
  equal to `"pr"`).
- `localUnsentCount` counts open local threads (`origin: "local"`) in state
  `unsent` whose latest message was authored by the reviewer (`viewerDidAuthor`).
- `queuedCount` counts viewed marks and comment operations waiting for GitHub.
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.
- `worktreeStatus` (`WorktreeStatus`) reports `isDirty` (whether any tracked or
  untracked file is modified in the worktree), `ahead` (commits on `HEAD` not
  reachable from the pull request's remote head commit), `behind` (commits on
  the pull request's remote head commit not reachable from `HEAD`), and
  `modifiedPaths` (sorted safe repository-relative dirty or untracked paths).

`PushResult` and `HeadMoveOutcome`:

```json
{
  "isPushed": true,
  "headSha": "def456",
  "syncError": "gh timed out after 30s",
  "view": SessionView
}
```

- `PushResult` is returned by `push`: `isPushed` is `true` once `git push`
  succeeded, `headSha` is the full `HEAD` commit SHA pushed, and `syncError` is
  present only when the post-push GitHub sync failed (omitted otherwise).
- `HeadMoveOutcome` is one of:
  - `"alreadyAtTarget"`: local `HEAD` was already at `headSha` (for example
    right after `push`).
  - `"fastForwarded"`: local `HEAD` fast-forwarded cleanly (auto-stashing and
    restoring dirty edits when needed).
  - `"restoreConflict"`: fast-forward succeeded, but restoring the auto-stash
    conflicted in `conflictedPaths`; conflict markers (or colliding untracked
    paths) and the stash entry remain.
  - `"aheadOfTarget"`: local `HEAD` has unpushed commits ahead of `headSha`;
    left untouched.
  - `"diverged"`: local `HEAD` and `headSha` diverged; left untouched.
  - `"failed"`: fetching or fast-forwarding failed before changing `HEAD`.

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
  "messages": [ Message ],
  "agent": { "state": "unsent" },
  "promotedTo": "PRRT_2"
}
```

- `origin` is `"github"` or `"local"`; `state` is `"open"` or `"resolved"`.
- `agent` (`AgentThreadState`) is present for local threads and omitted for
  GitHub threads.
- `promotedTo` holds the target GitHub thread ID once a local thread has been
  promoted via `promoteThread`, and is omitted otherwise.

`ThreadPreview`:

```json
{
  "threadId": "PRRT_1",
  "origin": "github",
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
- `origin`, `agent` (omitted when absent), and `promotedTo` (omitted when
  absent) match `Thread`.

`AgentThreadState`:

- `{ "state": "unsent" }`: open local thread waiting for `:Jpr send`.
- `{ "state": "sent", "round": 1 }`: dispatched in 1-based round `round`,
  awaiting `agentReply`.
- `{ "state": "answered" }`: latest message is the agent's reply.

`AgentKind`, `AgentProfile`, `AgentLaunchPlan`, `AgentRound`, `AgentDispatch`,
`PrepassFinding`, and `LocalAnchorUpdate`:

- `AgentKind` is `"claude"` or `"codex"`.
- `AgentProfile` describes terminal paste/submit delivery for `kind`:

```json
{
  "kind": "claude",
  "pasteStyle": "bracketed",
  "submitKey": "enter",
  "submitDelayMs": 200
}
```

  (`"claude"` uses `"submitKey": "enter"`; `"codex"` uses `"submitKey": "tab"`.)
- `AgentLaunchPlan`:

```json
{
  "kind": "claude",
  "sessionId": "550e8400-e29b-41d4-a716-446655440000",
  "isResume": false,
  "socket": "/path/to/s.sock",
  "profile": AgentProfile
}
```

  (`socket` is omitted when the server is running without a Unix socket.)
- `AgentRoundKind` is `"send"`, `"prepass"`, or `"conflict"`.
- `AgentRound` (`threadIds` is `[]` for `"prepass"` and `"conflict"`):

```json
{
  "round": 1,
  "kind": "send",
  "threadIds": ["loc-1"],
  "prompt": "...",
  "sentAt": 1763510400
}
```

- `AgentDispatch` (`threadIds` is `[]` for `"prepass"` and `"conflict"`):

```json
{
  "round": 1,
  "kind": "send",
  "threadIds": ["loc-1"],
  "prompt": "...",
  "profile": AgentProfile
}
```

- `PrepassFinding`: `{ "anchor": Anchor, "body": "...", "author"?: "..." }`
  (`author` optional, defaults to `"agent"`).
- `LocalAnchorUpdate`: `{ "threadId": "loc-1", "start": 10, "end": 12 }`.

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
| -32600 | Not a request: no string `method`, no `id` (the response `id` is `null` when there was none), or a method disallowed on the Unix socket |
| -32601 | Unknown method |
| -32602 | Invalid params: a missing or mistyped param (`path`, `paths`, `viewed`, `mode`, `anchor`, `origin`, `agent`, `kind`, `round`, `threadIds`, `findings`, `updates`, `renames`, `content`, `event`, `cursorLine`, etc.) |
| -32000 | The engine could not do it; `message` says why |
| -32001 | GitHub authentication is required (`gh` is not logged in or credentials expired); frontends may run `gh auth login` and retry |

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
- **Version 4** added the Unix socket transport (allowlisting `snapshot`,
  `threads`, `agentReply`, and `prepassWrite`), `origin` on `comment`,
  `agentReply`, `promoteThread`, `prepareAgentLaunch`, `prepareSend`,
  `confirmSend`, `preparePrepass`, `prepassWrite`, `updateLocalAnchors`, the
  `filesChanged` and `agentRound` events, `localUnsentCount` in `SessionView`,
  `agent` and `promotedTo` on `Thread`, `origin`/`agent`/`promotedTo` on
  `ThreadPreview`, and the `AgentThreadState`, `AgentKind`, `AgentProfile`,
  `AgentLaunchPlan`, `AgentRoundKind`, `AgentRound`, `AgentDispatch`,
  `PrepassFinding`, and `LocalAnchorUpdate` types.
- **Version 5** added `push`, `prepareConflictResolution`, `"conflict"` in
  `AgentRoundKind` (`confirmSend`, `AgentRound`, `AgentDispatch`),
  `pr.isCrossRepository` and `worktreeStatus` (`WorktreeStatus`) in
  `SessionView`, `isModified` and `localThreads` on `FileRow`, the
  `worktreeStatusChanged` and `headMoved` (`HeadMoveOutcome`) events, and the
  `PushResult` type.
- **Version 6** added the `streamProgress` JSON-RPC notification
  (`{ "completed", "total", "path" }`) emitted per file while a `stream`
  request executes, before the `stream` response arrives.
- **Version 7** added `refreshWorktree` (optional `renames` array of
  `{ "oldPath", "newPath" }`, returning `SessionView`) and `isLocalOnly`
  (`boolean`, `#[serde(default)]`) on `FileRow`.
- **Version 8** added `localContext` on `SessionView` and unlinked `--local`
  mode with in-place `sync` upgrade to a live PR session.
- **Version 9** added JSON-RPC error code `-32001` (`AUTH_REQUIRED`) for
  unauthenticated `gh` failures across GitHub-backed requests, and added
  `authRequired` and `isBackground` booleans to the `syncFailed` notification.
- **Version 10** extended `setViewed` to accept either `{ "path": string, "viewed": bool }`
  or `{ "paths": string[], "viewed": bool }` (batched into parameterized aliased
  GraphQL mutations on GitHub, one atomic save, and one `viewedChanged` event).
