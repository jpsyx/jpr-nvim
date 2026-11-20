#!/bin/sh
# A stand-in for `jpr-review serve` in the Lua specs: answers by method name and
# ignores its arguments. FAKE_ENGINE_PROTOCOL overrides the protocol version it
# reports (default 2). When FAKE_ENGINE_LOG names a file, every request line is
# appended to it, so a spec can check what the plugin sent. A fileDiff for
# BROKEN.md fails, and one for NULL.md answers null. A setViewed for BROKEN.md
# fails too.
pr='{"number":7,"title":"Fix the widget","headSha":"head1","baseSha":"base1"}'
tree='[{"depth":0,"name":"README.md","file":0}]'
view_synced='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","threads":1}],"tree":'"$tree"',"viewedCount":0,"threadCount":1,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_viewed='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"VIEWED","threads":1}],"tree":'"$tree"',"viewedCount":1,"threadCount":1,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_empty='{"files":[],"tree":[],"viewedCount":0,"threadCount":0,"queuedCount":0,"sync":{"state":"never"}}'
# README.md is "hello\nold\n" at the base and "hello\nnew\n" on disk.
file_diff='{"path":"README.md","binary":false,"baseText":"hello\nold\n","added":[{"line":2,"words":[{"start":0,"end":3}]}],"removed":[{"above":2,"lines":[{"text":"old","words":[{"start":0,"end":3}]}]}]}'
head_rows='{"kind":"file","path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","folded":false},{"kind":"hunk","path":"README.md","header":"@@ -1,2 +1,2 @@","target":1}'
hello='{"kind":"line","path":"README.md","left":{"line":1,"text":"hello","change":"context","words":[]},"right":{"line":1,"text":"hello","change":"context","words":[]},"target":1}'
old='{"line":2,"text":"old","change":"removed","words":[{"start":0,"end":3}]}'
new='{"line":2,"text":"new","change":"added","words":[{"start":0,"end":3}]}'
stream_unified='{"mode":"unified","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":null,"target":2},{"kind":"line","path":"README.md","left":null,"right":'"$new"',"target":2}]}'
stream_split='{"mode":"split","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":'"$new"',"target":2}]}'
reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$1"; }
announce() { printf '{"jsonrpc":"2.0","method":"event","params":{"type":"%s","view":%s}}\n' "$1" "$2"; }
while IFS= read -r line; do
  if [ -n "$FAKE_ENGINE_LOG" ]; then printf '%s\n' "$line" >> "$FAKE_ENGINE_LOG"; fi
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) reply '{"protocolVersion":'"${FAKE_ENGINE_PROTOCOL:-2}"',"version":"test"}' ;;
    *'"method":"snapshot"'*) reply "$view_empty" ;;
    *'"method":"sync"'*) announce synced "$view_synced"; reply "$view_synced" ;;
    *'"method":"fileDiff"'*'"BROKEN.md"'*|*'"BROKEN.md"'*'"method":"fileDiff"'*)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"BROKEN.md is not at the base"}}\n' "$id" ;;
    *'"method":"fileDiff"'*'"NULL.md"'*|*'"NULL.md"'*'"method":"fileDiff"'*) reply null ;;
    *'"method":"fileDiff"'*) reply "$file_diff" ;;
    *'"method":"stream"'*'"split"'*|*'"split"'*'"method":"stream"'*) reply "$stream_split" ;;
    *'"method":"stream"'*) reply "$stream_unified" ;;
    *'"method":"setViewed"'*'"BROKEN.md"'*|*'"BROKEN.md"'*'"method":"setViewed"'*)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"GitHub refused BROKEN.md"}}\n' "$id" ;;
    *'"method":"setViewed"'*) announce viewedChanged "$view_viewed"; reply "$view_viewed" ;;
    *'"method":"shutdown"'*) reply null; exit 0 ;;
    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id" ;;
  esac
done
