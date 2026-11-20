#!/bin/sh
# A stand-in for `jpr-review serve` in the Lua specs: answers by method name and
# ignores its arguments. FAKE_ENGINE_PROTOCOL overrides the protocol version it
# reports (default 1).
view_synced='{"pr":{"number":7,"title":"Fix the widget"},"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"VIEWED","threads":1}],"viewedCount":1,"threadCount":1,"sync":{"state":"synced","at":1}}'
view_empty='{"files":[],"viewedCount":0,"threadCount":0,"sync":{"state":"never"}}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":%s,"version":"test"}}\n' "$id" "${FAKE_ENGINE_PROTOCOL:-1}" ;;
    *'"method":"snapshot"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$view_empty" ;;
    *'"method":"sync"'*)
      printf '{"jsonrpc":"2.0","method":"event","params":{"type":"synced","view":%s}}\n' "$view_synced"
      printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$view_synced" ;;
    *'"method":"shutdown"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":null}\n' "$id"
      exit 0 ;;
    *)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id" ;;
  esac
done
