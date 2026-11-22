#!/bin/sh
# A stand-in for `jpr-review serve` in the Lua specs: answers by method name and
# ignores its arguments. FAKE_ENGINE_PROTOCOL overrides the protocol version it
# reports (default 5); FAKE_ENGINE_VERSION overrides its server version (default
# test). When FAKE_ENGINE_LOG names a file, every request line is appended to
# it, so a spec can check what the plugin sent. A fileDiff for BROKEN.md fails,
# and one for NULL.md answers null. A setViewed for BROKEN.md fails too.
pr='{"number":7,"title":"Fix the widget","headSha":"head1","baseSha":"base1"}'
tree='[{"depth":0,"name":"README.md","file":0}]'
view_synced='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","threads":1}],"tree":'"$tree"',"viewedCount":0,"threadCount":1,"draftCount":0,"conversationCount":1,"localUnsentCount":0,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_viewed='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"VIEWED","threads":1}],"tree":'"$tree"',"viewedCount":1,"threadCount":1,"draftCount":0,"conversationCount":1,"localUnsentCount":0,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_empty='{"files":[],"tree":[],"viewedCount":0,"threadCount":0,"draftCount":0,"conversationCount":0,"localUnsentCount":0,"queuedCount":0,"sync":{"state":"never"}}'
view_local_unsent='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","threads":1}],"tree":'"$tree"',"viewedCount":0,"threadCount":1,"draftCount":0,"conversationCount":1,"localUnsentCount":1,"queuedCount":0,"sync":{"state":"synced","at":1}}'
anchor_line='{"file":"README.md","kind":"line","side":"RIGHT","start":2,"end":2,"commit":"head1","snapshot":"new"}'
anchor_pr='{"file":null,"kind":"pr","side":"RIGHT","start":null,"end":null,"commit":null,"snapshot":null}'
msg_code='{"id":"M1","author":"alice","body":"nit: rename this","created":"2026-11-20T00:00:00Z","updated":"2026-11-20T00:00:00Z","sync":"published","viewerDidAuthor":false,"reactions":[]}'
msg_reacted='{"id":"M1","author":"alice","body":"nit: rename this","created":"2026-11-20T00:00:00Z","updated":"2026-11-20T00:00:00Z","sync":"published","viewerDidAuthor":false,"reactions":[{"content":"THUMBS_UP","count":1,"viewerHasReacted":true}]}'
msg_pr='{"id":"M_PR1","author":"alice","body":"Overall looks clean!","created":"2026-11-20T00:00:00Z","updated":"2026-11-20T00:00:00Z","sync":"published","viewerDidAuthor":false,"reactions":[]}'
msg_local='{"id":"loc-m-1","author":"reviewer","body":"please check this","created":"2026-11-20T00:00:00Z","updated":"2026-11-20T00:00:00Z","viewerDidAuthor":true,"reactions":[]}'
thread_code='{"id":"T1","origin":"github","anchor":'"$anchor_line"',"state":"open","outdated":false,"messages":['"$msg_code"']}'
thread_resolved='{"id":"T1","origin":"github","anchor":'"$anchor_line"',"state":"resolved","outdated":false,"messages":['"$msg_code"']}'
thread_reacted='{"id":"T1","origin":"github","anchor":'"$anchor_line"',"state":"open","outdated":false,"messages":['"$msg_reacted"']}'
thread_pr='{"id":"T_PR","origin":"github","anchor":'"$anchor_pr"',"state":"open","outdated":false,"messages":['"$msg_pr"']}'
thread_local='{"id":"loc-1","origin":"local","anchor":'"$anchor_line"',"state":"open","outdated":false,"messages":['"$msg_local"'],"agent":{"state":"unsent"}}'
thread_preview='{"threadId":"T1","origin":"github","anchor":'"$anchor_line"',"displayLine":2,"kind":"published","state":"open","outdated":false,"messageCount":1,"firstAuthor":"alice","snippet":"nit: rename this","messages":['"$msg_code"']}'
# README.md is "hello\nold\n" at the base and "hello\nnew\n" on disk.
file_diff='{"path":"README.md","binary":false,"baseText":"hello\nold\n","added":[{"line":2,"words":[{"start":0,"end":3}]}],"removed":[{"above":2,"lines":[{"text":"old","words":[{"start":0,"end":3}]}]}],"threads":['"$thread_preview"']}'
head_rows='{"kind":"file","path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","folded":false},{"kind":"hunk","path":"README.md","header":"@@ -1,2 +1,2 @@","target":1}'
hello='{"kind":"line","path":"README.md","left":{"line":1,"text":"hello","change":"context","words":[]},"right":{"line":1,"text":"hello","change":"context","words":[]},"target":1}'
old='{"line":2,"text":"old","change":"removed","words":[{"start":0,"end":3}]}'
new='{"line":2,"text":"new","change":"added","words":[{"start":0,"end":3}]}'
stream_unified='{"mode":"unified","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":null,"target":2},{"kind":"line","path":"README.md","left":null,"right":'"$new"',"target":2}]}'
stream_split='{"mode":"split","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":'"$new"',"target":2}]}'
submit_preview='{"draftCount":1,"drafts":[{"threadId":"T1","messageId":"M1","anchor":'"$anchor_line"',"snippet":"nit: rename this"}],"canApproveOrRequestChanges":true,"blockedReason":null}'
suggested_edit='{"anchor":'"$anchor_line"',"suggestionBody":"```suggestion\nbetter\n```","revertedText":"hello\nnew\n"}'
profile_claude='{"kind":"claude","pasteStyle":"bracketed","submitKey":"enter","submitDelayMs":200}'
profile_codex='{"kind":"codex","pasteStyle":"bracketed","submitKey":"tab","submitDelayMs":200}'
agent_round_send='{"round":1,"kind":"send","threadIds":["loc-1"],"prompt":"Review local thread loc-1","sentAt":1}'
agent_round_prepass='{"round":1,"kind":"prepass","threadIds":[],"prompt":"Run pre-pass review","sentAt":1}'
agent_round_conflict='{"round":1,"kind":"conflict","threadIds":[],"prompt":"Resolve conflicts in README.md","sentAt":1700000099}'
if [ -n "$FAKE_ENGINE_STDERR" ]; then printf '%s\n' "$FAKE_ENGINE_STDERR" >&2; fi
reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$1"; }
announce() { printf '{"jsonrpc":"2.0","method":"event","params":{"type":"%s","view":%s}}\n' "$1" "$2"; }
announce_round() { printf '{"jsonrpc":"2.0","method":"event","params":{"type":"agentRound","round":%s,"view":%s}}\n' "$1" "$2"; }
agent_profile() {
  case "$1" in
    *'"agent":"codex"'*) printf '%s' "$profile_codex" ;;
    *) printf '%s' "$profile_claude" ;;
  esac
}
agent_kind() {
  case "$1" in
    *'"agent":"codex"'*) printf 'codex' ;;
    *) printf 'claude' ;;
  esac
}
while IFS= read -r line; do
  if [ -n "$FAKE_ENGINE_LOG" ]; then printf '%s\n' "$line" >> "$FAKE_ENGINE_LOG"; fi
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) reply '{"protocolVersion":'"${FAKE_ENGINE_PROTOCOL:-5}"',"version":"'"${FAKE_ENGINE_VERSION:-test}"'"}' ;;
    *'"method":"snapshot"'*) reply "$view_empty" ;;
    *'"method":"sync"'*) announce synced "$view_synced"; reply "$view_synced" ;;
    *'"method":"push"'*)
      if [ -n "$FAKE_ENGINE_PUSH_SYNC_ERROR" ]; then
        reply '{"isPushed":true,"headSha":"abc1234","syncError":"'"$FAKE_ENGINE_PUSH_SYNC_ERROR"'","view":'"$view_synced"'}'
      else
        reply '{"isPushed":true,"headSha":"abc1234","view":'"$view_synced"'}'
      fi ;;
    *'"method":"fileDiff"'*'"BROKEN.md"'*|*'"BROKEN.md"'*'"method":"fileDiff"'*)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"BROKEN.md is not at the base"}}\n' "$id" ;;
    *'"method":"fileDiff"'*'"NULL.md"'*|*'"NULL.md"'*'"method":"fileDiff"'*) reply null ;;
    *'"method":"fileDiff"'*) reply "$file_diff" ;;
    *'"method":"stream"'*'"split"'*|*'"split"'*'"method":"stream"'*) reply "$stream_split" ;;
    *'"method":"stream"'*) reply "$stream_unified" ;;
    *'"method":"setViewed"'*'"BROKEN.md"'*|*'"BROKEN.md"'*'"method":"setViewed"'*)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"GitHub refused BROKEN.md"}}\n' "$id" ;;
    *'"method":"setViewed"'*) announce viewedChanged "$view_viewed"; reply "$view_viewed" ;;
    *'"method":"threads"'*) reply '{"threads":['"$thread_code"','"$thread_pr"']}' ;;
    *'"method":"mentions"'*) reply '{"candidates":[{"login":"alice","isParticipant":true},{"login":"bob","isParticipant":false}]}' ;;
    *'"method":"comment"'*'"origin":"local"'*|*'"origin":"local"'*'"method":"comment"'*)
      announce threadsChanged "$view_local_unsent"; reply '{"thread":'"$thread_local"',"view":'"$view_local_unsent"'}' ;;
    *'"method":"comment"'*) announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"reply"'*) announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"editMessage"'*) announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"deleteMessage"'*) announce threadsChanged "$view_synced"; reply "$view_synced" ;;
    *'"method":"setResolved"'*'"resolved":false'*|*'"resolved":false'*'"method":"setResolved"'*)
      announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"setResolved"'*) announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_resolved"',"view":'"$view_synced"'}' ;;
    *'"method":"toggleReaction"'*) announce threadsChanged "$view_synced"; reply '{"thread":'"$thread_reacted"',"view":'"$view_synced"'}' ;;
    *'"method":"retryMessage"'*) announce threadsChanged "$view_synced"; reply "$view_synced" ;;
    *'"method":"anchoredLines"'*) reply '{"text":"new"}' ;;
    *'"method":"suggestFromEdit"'*)
      announce threadsChanged "$view_synced"
      reply '{"suggested":'"$suggested_edit"',"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"submitPreview"'*) reply "$submit_preview" ;;
    *'"method":"submitReview"'*) announce threadsChanged "$view_synced"; reply "$view_synced" ;;
    *'"method":"prepareAgentLaunch"'*)
      reply '{"kind":"'"$(agent_kind "$line")"'","sessionId":"00000000-0000-4000-8000-000000000001","isResume":false,"socket":"/tmp/jpr-fake.sock","profile":'"$(agent_profile "$line")"'}' ;;
    *'"method":"prepareSend"'*)
      reply '{"round":1,"kind":"send","threadIds":["loc-1"],"prompt":"Review local thread loc-1","profile":'"$(agent_profile "$line")"'}' ;;
    *'"method":"confirmSend"'*'"kind":"prepass"'*|*'"kind":"prepass"'*'"method":"confirmSend"'*)
      announce_round "$agent_round_prepass" "$view_synced"
      reply '{"round":'"$agent_round_prepass"',"view":'"$view_synced"'}' ;;
    *'"method":"confirmSend"'*'"kind":"conflict"'*|*'"kind":"conflict"'*'"method":"confirmSend"'*)
      announce_round "$agent_round_conflict" "$view_synced"
      reply '{"round":'"$agent_round_conflict"',"view":'"$view_synced"'}' ;;
    *'"method":"confirmSend"'*)
      announce threadsChanged "$view_synced"
      announce_round "$agent_round_send" "$view_synced"
      reply '{"round":'"$agent_round_send"',"view":'"$view_synced"'}' ;;
    *'"method":"preparePrepass"'*)
      reply '{"round":1,"kind":"prepass","threadIds":[],"prompt":"Run pre-pass review","profile":'"$(agent_profile "$line")"'}' ;;
    *'"method":"prepareConflictResolution"'*)
      reply '{"round":1,"kind":"conflict","threadIds":[],"prompt":"Resolve conflicts in README.md","profile":'"$(agent_profile "$line")"'}' ;;
    *'"method":"promoteThread"'*)
      announce threadsChanged "$view_synced"
      reply '{"thread":'"$thread_code"',"view":'"$view_synced"'}' ;;
    *'"method":"updateLocalAnchors"'*) reply "$view_synced" ;;
    *'"method":"shutdown"'*) reply null; exit 0 ;;
    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id" ;;
  esac
done
