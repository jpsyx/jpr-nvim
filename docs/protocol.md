# Engine protocol (version 2)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests arrive on stdin. Responses and notifications leave on stdout and may
interleave, so clients match responses by `id`. Logs go to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
```

Run it in the pull request's worktree. `--poll` defaults to 60 seconds, and
`--poll 0` turns background syncing off. While it polls, the server also
resends viewed marks GitHub refused every 20 seconds between syncs, and every
sync sends them before it pulls. The server does not sync on its own at
startup: until the first sync, `snapshot` returns what was saved last.

## Handshake

The client sends `initialize` first and compares `protocolVersion` with its
own. On a mismatch it stops the server and tells the user to install the
plugin and the engine from the same checkout.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 2, "client": "..." }` (the server reads neither) | `{ "protocolVersion": 2, "version": "0.2.0" }` |
| `snapshot` | none | `SessionView` |
| `sync` | none | `SessionView`; error `-32000` when GitHub fails, after a `syncFailed` event |
| `fileDiff` | `{ "path": "src/a.rs" }` | `FileDiffView`; error `-32000` for a file the pull request does not change, a side over 4 MiB, or before the first sync |
| `stream` | `{ "mode": "unified" \| "split" }` | `StreamView`; error `-32000` before the first sync |
| `setViewed` | `{ "path": "src/a.rs", "viewed": true }` | `SessionView`, after a `viewedChanged` event |
| `shutdown` | none | `null`; the server stops reading and exits |

The server also exits when stdin closes. Methods without params ignore them,
so `null`, `{}` or a missing `params` all work. `setViewed` succeeds even when
GitHub refuses the mark: the mark stands, is counted in `queuedCount`, and is
sent again by later retries and syncs.

## Notifications (server to client)

`event`, with one of:

```json
{ "type": "synced", "view": SessionView }
{ "type": "syncFailed", "message": "gh timed out after 30s" }
{ "type": "viewedChanged", "view": SessionView }
```

Every sync announces `synced` or `syncFailed`, whether a `sync` request or the
background poller started it. `viewedChanged` follows every `setViewed` and
every retry that got a queued mark through. A sync whose pull fails after it
got a queued mark through announces `viewedChanged` before `syncFailed`; a
sync that succeeds announces the shorter queue in `synced`. An event is
written before the response to the request that caused it, and every event is
written before the `shutdown` response.

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
- `queuedCount` counts viewed marks waiting for GitHub.
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.

`FileDiffView`, one file against the merge base of its base commit and the
checked-out head; the current side is the file on disk:

```json
{
  "path": "src/a.rs",
  "binary": false,
  "baseText": "fn main() {\nlet x = 1;\n}\n",
  "added": [ { "line": 2, "words": [ { "start": 8, "end": 9 } ] } ],
  "removed": [ { "above": 2, "lines": [ { "text": "let x = 1;", "words": [ { "start": 8, "end": 9 } ] } ] } ]
}
```

- Line numbers count from 1 in the current file. `above` is the line a block
  of removed lines sits above; one past the last line means after the end.
- `words` are byte ranges (`end` exclusive) of the words that changed inside
  an edited line; a line that was replaced rather than edited has none.
- `baseText` is `null` for an added file or a binary one; `binary` files have
  no `added` or `removed` lines.

`StreamView`:

```json
{
  "mode": "split",
  "rows": [
    { "kind": "file", "path": "src/a.rs", "additions": 1, "deletions": 1, "viewed": "UNVIEWED", "folded": false },
    { "kind": "hunk", "path": "src/a.rs", "header": "@@ -1,3 +1,3 @@", "target": 1 },
    { "kind": "line", "path": "src/a.rs", "target": 1,
      "left":  { "line": 1, "text": "fn main() {", "change": "context", "words": [] },
      "right": { "line": 1, "text": "fn main() {", "change": "context", "words": [] } },
    { "kind": "line", "path": "src/a.rs", "target": 2,
      "left":  { "line": 2, "text": "let x = 1;", "change": "removed", "words": [ { "start": 8, "end": 9 } ] },
      "right": { "line": 2, "text": "let x = 2;", "change": "added", "words": [ { "start": 8, "end": 9 } ] } },
    { "kind": "note", "path": "logo.png", "text": "binary file" }
  ]
}
```

- Files come in GitHub's order; each starts with a `file` row. Viewed files
  have `folded: true`.
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
| -32602 | Invalid params: a missing or mistyped `path`, `viewed` or `mode` |
| -32000 | The engine could not do it; `message` says why |

## Versioning

Change `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and
`M.PROTOCOL_VERSION` in `lua/jpr/rpc.lua` together whenever a request, a
result or an event changes shape, and update this document in the same commit.
Version 2 added `fileDiff`, `stream`, `setViewed`, the `viewedChanged` event,
and `tree`, `queuedCount` and `pr.baseSha` in `SessionView`.
