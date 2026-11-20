# Engine protocol (version 1)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests arrive on stdin. Responses and notifications leave on stdout and may
interleave, so clients match responses by `id`. Logs go to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
```

Run it in the pull request's worktree. `--poll` defaults to 60 seconds, and
`--poll 0` turns background syncing off. The server does not sync on its own
at startup: until the first sync, `snapshot` returns what was saved last.

## Handshake

The client sends `initialize` first and compares `protocolVersion` with its
own. On a mismatch it stops the server and tells the user to install the plugin
and the engine from the same checkout.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 1, "client": "..." }` (the server reads neither yet) | `{ "protocolVersion": 1, "version": "0.1.0" }` |
| `snapshot` | none | `SessionView` |
| `sync` | none | `SessionView`; error `-32000` when GitHub fails, after a `syncFailed` event |
| `shutdown` | none | `null`; the server stops reading and exits |

The server also exits when stdin closes. Params are ignored by every method
in version 1, so `null`, `{}` or a missing `params` all work.

## Notifications (server to client)

`event`, with one of:

```json
{ "type": "synced", "view": SessionView }
{ "type": "syncFailed", "message": "gh timed out after 30s" }
```

Every sync announces one of these, whether a `sync` request or the background
poller started it. An event is written before the response to the request
that caused it, and every event is written before the `shutdown` response.

## Types

`SessionView`:

```json
{
  "pr": { "owner": "octo", "repo": "widgets", "number": 7, "title": "Fix the widget",
          "url": "https://github.com/octo/widgets/pull/7", "nodeId": "PR_7", "author": "alice",
          "headRef": "fix/widget", "headSha": "abc123", "baseRef": "main" },
  "files": [ { "path": "src/a.rs", "additions": 12, "deletions": 3, "viewed": "VIEWED", "threads": 2 } ],
  "viewedCount": 1,
  "threadCount": 2,
  "sync": { "state": "synced", "at": 1763510400 }
}
```

- `pr` is `null` until the first successful sync.
- `viewed` is `VIEWED`, `UNVIEWED` or `DISMISSED` (viewed, then changed on GitHub).
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.

## Errors

| Code | Meaning |
| --- | --- |
| -32700 | The line is not JSON (the response `id` is `null`) |
| -32600 | Not a request: no string `method`, or no `id` (the response `id` is `null` when there was none) |
| -32601 | Unknown method |
| -32602 | Invalid params; reserved, since no method in version 1 reads its params |
| -32000 | The engine could not do it; `message` says why |

## Versioning

Change `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and
`M.PROTOCOL_VERSION` in `lua/jpr/rpc.lua` together whenever a request, a
result or an event changes shape, and update this document in the same commit.
