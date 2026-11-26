#!/bin/bash
# Test pet-emit.sh against a throwaway PET_HOME.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Point at the Swift binary; PET_EMIT can override it (packaging tests reuse this).
EMIT_BIN="${PET_EMIT:-$HERE/../.build/debug/PetEmit}"
if [ ! -x "$EMIT_BIN" ]; then
  echo "PetEmit binary not found: $EMIT_BIN"
  echo "run swift build before this test"
  exit 1
fi
# Claude Code puts transcript_path on every hook payload, and pet-emit ignores one without it
# (a hand-typed test, not a session). The fixtures below leave it out for brevity, so "$EMIT"
# is this function, which adds one to any payload that names a session and lacks it. Tests of
# that rule call "$EMIT_BIN" directly; so must anything run through `env`, which cannot see
# shell functions.
pet_emit() {
  if [ $# -gt 0 ]; then "$EMIT_BIN" "$@"; return; fi
  local p; p="$(cat)"
  case "$p" in
    *'"session_id"'*) case "$p" in
      *'"transcript_path"'*) ;;
      '{'*) p="{\"transcript_path\":\"/fixture/session.jsonl\",${p#\{}" ;;
      # Spliced in blind, this would be invalid JSON that the binary drops silently, and a
      # "writes nothing" test would then pass for the wrong reason.
      *) echo "pet_emit: a fixture must start with '{': $p" >&2; fails=$((fails + 1)); return 1 ;;
    esac ;;
  esac
  printf '%s' "$p" | "$EMIT_BIN"
}
EMIT=pet_emit
export PET_HOME="$(mktemp -d)/pet"
# A PermissionRequest holds its hook open for an answer from the pet; only the
# tests about that want it to.
export PET_PERMISSION_WAIT=0
trap 'rm -rf "$(dirname "$PET_HOME")"' EXIT

fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    echo "        expected: $3"
    echo "        actual:   $2"
    fails=$((fails + 1))
  fi
}

emit() {  # emit <event> <session_id> <cwd> [tool_name] [message]
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","tool_name":"%s","message":"%s"}' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" | "$EMIT"
}

field() {  # field <session_id> <key>
  /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" \
    "$PET_HOME/sessions/$1.json" "$2"
}

# Feeds a raw payload, for events whose shape the `emit` helper cannot express.
emit_json() { printf '%s' "$1" | "$EMIT"; }

# --- event -> state mapping ---
emit SessionStart s1 /Users/dev/Projects/demo-app
check "SessionStart writes idle" "$(field s1 state)" "idle"
check "project is cwd basename" "$(field s1 project)" "demo-app"
check "cwd is kept whole" "$(field s1 cwd)" "/Users/dev/Projects/demo-app"

emit_json '{"hook_event_name":"SessionStart","session_id":"sT","cwd":"/tmp/t","transcript_path":"/Users/dev/.claude/projects/-tmp-t/sT.jsonl"}'
check "the transcript path is kept for counting turns" "$(field sT transcript)" "/Users/dev/.claude/projects/-tmp-t/sT.jsonl"
rm -f "$PET_HOME/sessions/sT.json"

emit UserPromptSubmit s1 /Users/dev/Projects/demo-app
check "UserPromptSubmit writes busy" "$(field s1 state)" "busy"

emit PreToolUse s1 /Users/dev/Projects/demo-app Bash
check "PreToolUse writes busy" "$(field s1 state)" "busy"
check "PreToolUse records tool" "$(field s1 tool)" "Bash"

emit Notification s1 /Users/dev/Projects/demo-app "" "needs your permission"
check "Notification writes waiting" "$(field s1 state)" "waiting"
check "Notification records message" "$(field s1 detail)" "needs your permission"

# PostToolUse must be checked from a non-busy predecessor state (waiting),
# otherwise a broken/misspelled dict key would silently leave the prior
# "busy" value in place and this check would pass for the wrong reason.
emit PostToolUse s1 /Users/dev/Projects/demo-app Bash
check "PostToolUse writes busy" "$(field s1 state)" "busy"

emit Stop s1 /Users/dev/Projects/demo-app
check "Stop writes idle" "$(field s1 state)" "idle"

# --- since is carried forward while the state does not change ---
emit Notification s2 /tmp/proj "" "waiting one"
first_since="$(field s2 since)"
sleep 1
emit Notification s2 /tmp/proj "" "waiting two"
check "since is kept while state is unchanged" "$(field s2 since)" "$first_since"

emit Stop s2 /tmp/proj
changed_since="$(field s2 since)"
check "since is refreshed when state changes" \
  "$([ "$changed_since" != "$first_since" ] && echo yes || echo no)" "yes"

# --- updatedAt refreshes on every write ---
emit Stop s2 /tmp/proj
sleep 1
before_updated="$(field s2 updatedAt)"
emit Stop s2 /tmp/proj
check "updatedAt always moves" \
  "$([ "$(field s2 updatedAt)" != "$before_updated" ] && echo yes || echo no)" "yes"

# --- one file per session ---
check "one file per session" "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "2"

# --- never fails, whatever it is fed ---
echo 'not json at all' | "$EMIT"; check "garbage stdin exits 0" "$?" "0"
printf '{}' | "$EMIT"; check "empty json exits 0" "$?" "0"
printf '' | "$EMIT"; check "empty stdin exits 0" "$?" "0"
emit PreToolUse "" /tmp/x Bash; check "missing session_id exits 0" "$?" "0"
check "missing session_id writes nothing" "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "2"
emit PreToolUse "../escape" /tmp/x Bash; check "session_id with slash exits 0" "$?" "0"
check "session_id with slash writes nothing" "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "2"
# "../escape" would resolve outside sessions/ entirely (into $PET_HOME/escape.json),
# so an unchanged sessions/ count alone does not prove the guard held -- also assert
# the escape target itself was never created.
check "session_id with slash does not escape sessions dir" \
  "$([ -e "$PET_HOME/escape.json" ] && echo exists || echo absent)" "absent"

# --- a payload without a transcript is not from Claude Code ---
# Another session testing the binary by hand once left a session called "x" on the board for an
# afternoon. Such a payload records nothing, and cannot end a real session either.
before="$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"x","prompt":"hi"}' | "$EMIT_BIN"
check "a payload without transcript_path exits 0" "$?" "0"
check "...and writes no session" "$([ -e "$PET_HOME/sessions/x.json" ] && echo yes || echo no)" "no"
printf '{"hook_event_name":"PreToolUse","session_id":"x","cwd":"/tmp/x","tool_name":"Bash","transcript_path":""}' | "$EMIT_BIN"
check "...nor does an empty transcript path" "$([ -e "$PET_HOME/sessions/x.json" ] && echo yes || echo no)" "no"
printf '{"hook_event_name":"SessionEnd","session_id":"s1"}' | "$EMIT_BIN"
check "...and a SessionEnd without one removes nothing" "$(field s1 state)" "idle"
check "...so the session count is unchanged" "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "$before"
printf '{"hook_event_name":"SessionStart","session_id":"sRel","cwd":"/w/app","transcript_path":"cfg/projects/sRel.jsonl"}' | "$EMIT_BIN"
check "a relative transcript path (CLAUDE_CONFIG_DIR) is still a session" "$(field sRel state)" "idle"
check "...whose path is not kept, the pet could not open it" "$(field sRel transcript)" ""
rm -f "$PET_HOME/sessions/sRel.json"

# --- an event we do not install must not touch the state ---
# SubagentStop is real but not one of ours; it stands in for anything a future
# Claude Code might send. PreCompact used to play this part and no longer can,
# which is the point: this has to name an event we genuinely ignore.
emit SubagentStop s1 /Users/dev/Projects/demo-app
check "an uninstalled event leaves state alone" "$(field s1 state)" "idle"

# --- Notification means two things: needing permission is waiting,
#     waiting for input is just done talking ---
emit Notification s3 /tmp/permproj "" "Claude needs your permission to use Bash"
check "permission notification means waiting" "$(field s3 state)" "waiting"

emit Notification s4 /tmp/inputproj "" "Claude is waiting for your input"
check "input notification is not waiting" "$(field s4 state)" "idle"
check "input notification keeps its message" "$(field s4 detail)" "Claude is waiting for your input"

# A repeated "waiting for your input" must not drag the session into waiting
emit Notification s4 /tmp/inputproj "" "Claude is waiting for your input"
check "repeated input notification stays idle" "$(field s4 state)" "idle"

# A genuine permission prompt stays waiting however often it repeats
emit Notification s3 /tmp/permproj "" "Claude needs your permission to use Read"
check "repeated permission notification stays waiting" "$(field s3 state)" "waiting"

# A Notification with no message is treated as the blocking kind:
# a false alarm is cheaper than a stuck session nobody notices
emit Notification s5 /tmp/blankproj "" ""
check "notification without message is waiting" "$(field s5 state)" "waiting"

# --- SessionEnd deletes the state file at once, without waiting for a timeout ---
before_end="$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')"
emit SessionEnd s4 /tmp/inputproj
check "SessionEnd removes the state file" \
  "$([ -f "$PET_HOME/sessions/s4.json" ] && echo present || echo gone)" "gone"
check "SessionEnd removes exactly one file" \
  "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "$((before_end - 1))"

emit SessionEnd unknown-session /tmp/x
check "SessionEnd for an unknown session exits 0" "$?" "0"
check "SessionEnd for an unknown session removes nothing" \
  "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "$((before_end - 1))"

emit SessionEnd "../escape" /tmp/x
check "SessionEnd honours the slash guard" "$?" "0"
check "SessionEnd slash guard deletes nothing outside sessions/" \
  "$([ -f "$PET_HOME/escape.json" ] && echo present || echo gone)" "gone"

echo

# --- PermissionRequest: structured, and says WHAT is blocked ---
emit_json '{"session_id":"s9","hook_event_name":"PermissionRequest","cwd":"/Users/dev/Projects/demo-app","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}'
check "PermissionRequest means waiting" "$(field s9 state)" "waiting"
check "the command is carried to the bubble" "$(field s9 waitingOn)" "rm -rf build/"

# The phrase has to survive the events that follow, or the bubble blanks out
emit Notification s9 /Users/dev/Projects/demo-app "" "needs your permission"
check "waitingOn survives a following Notification" "$(field s9 waitingOn)" "rm -rf build/"

# ...and has to be dropped once the session is no longer blocked
emit Stop s9 /Users/dev/Projects/demo-app
check "waitingOn is cleared when it stops waiting" "$(field s9 waitingOn)" ""

# ---- completion records -----------------------------------------------------
# A finished turn has to leave a record on disk. The app used to infer finishes
# by diffing two renders, which lost every turn that began and ended between
# them — and every one that finished while speech was suppressed.

events() { ls "$PET_HOME/events" 2>/dev/null | wc -l | tr -d ' '; }
event_field() {  # event_field <index> <key>
  f="$(ls "$PET_HOME/events"/*.json 2>/dev/null | sed -n "$1p")"
  [ -n "$f" ] || { echo "(no file)"; return; }
  /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" \
    "$f" "$2"
}

rm -rf "$PET_HOME/events"
emit UserPromptSubmit sA /Users/dev/Projects/api-server
emit Stop sA /Users/dev/Projects/api-server
check "a finished turn is recorded" "$(events)" "1"
check "the record names the project" "$(event_field 1 project)" "api-server"
check "the record names the session" "$(event_field 1 sessionId)" "sA"

# Claude Code redelivering the same Stop must not add a second row.
emit Stop sA /Users/dev/Projects/api-server
check "the same turn recorded twice stays one file" "$(events)" "1"

# A new turn is a new record, even for the same session.
emit UserPromptSubmit sA /Users/dev/Projects/api-server
emit Stop sA /Users/dev/Projects/api-server
check "a second turn is its own record" "$(events)" "2"

# The case the whole queue exists for: a turn that starts and ends between two
# renders of the app. Nothing here consults the app at all.
emit UserPromptSubmit sB /Users/dev/Projects/web
emit Stop sB /Users/dev/Projects/web
emit UserPromptSubmit sB /Users/dev/Projects/web
check "a turn that ended before anything could look is still on disk" "$(events)" "3"

# Events that are not a finished turn must not fabricate records.
emit PreToolUse sB /Users/dev/Projects/web Bash
emit Notification sB /Users/dev/Projects/web "" "needs your permission"
check "only Stop writes a record" "$(events)" "3"

# ---- a Stop held open by background work ------------------------------------
# Claude Code ends the turn the moment it dispatches a background agent, so Stop
# arrives while the work has not even started. Calling that a finish put a red
# dot on a session nine minutes before it had anything to show.
stop_with_tasks() {  # stop_with_tasks <session> <cwd> <background_tasks JSON>
  printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","background_tasks":%s}' \
    "$1" "$2" "$3" | "$EMIT"
}

rm -rf "$PET_HOME/events"
emit UserPromptSubmit sBG /Users/dev/Projects/api-server
stop_with_tasks sBG /Users/dev/Projects/api-server \
  '[{"id":"t1","type":"subagent","status":"running","description":"Audit CORE-16919","agent_type":"merge-gate-audit-agent"}]'
check "a Stop waiting on an agent records no finish" "$(events)" "0"
check "...and the session keeps looking busy" "$(field sBG state)" "busy"
check "...and says what it is waiting for" "$(field sBG phase)" "awaiting-agent"
check "...naming the agent, not its free-text description" \
  "$(field sBG backgroundAgents)" "['merge-gate-audit-agent']"

# The turn the agent wakes ends with nothing in flight. THAT one is the finish,
# and it must still be recorded — a finish the user never sees is the one
# failure this whole queue exists to prevent.
stop_with_tasks sBG /Users/dev/Projects/api-server '[]'
check "the turn the agent wakes is recorded" "$(events)" "1"
check "...and the session is idle again" "$(field sBG state)" "idle"
check "...and the phase is cleared" "$(field sBG phase)" ""

# When a background agent finishes, Claude Code wakes the session with a real
# UserPromptSubmit carrying a <task-notification> envelope. That is the machine
# talking to itself, and it must not count as the user speaking — otherwise an
# agent dispatched an hour ago silently unmutes a session you put away.
prompt_with() {  # prompt_with <session> <cwd> <prompt text>
  /usr/bin/python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'UserPromptSubmit','session_id':sys.argv[1],
                  'cwd':sys.argv[2],'prompt':sys.argv[3]}))" "$1" "$2" "$3" | "$EMIT"
}

prompt_with sTYPED /Users/dev/Projects/web "fix the flaky test"
check "a typed prompt is the user speaking" \
  "$([ -n "$(field sTYPED lastPromptAt)" ] && echo yes)" "yes"
# Asserted on a session nobody has ever typed into, rather than by comparing two
# timestamps: these are second-resolution, so two writes inside one second are
# indistinguishable and the comparison would pass with the check removed. Empty
# versus not-empty cannot collapse that way.
prompt_with sWAKE /Users/dev/Projects/web '<task-notification>
<task-id>abc</task-id>
</task-notification>'
check "an agent waking a session is not" "$(field sWAKE lastPromptAt)" ""

# A backgrounded shell is NOT held work. Claude Code's own "Waiting for N
# background agents" line excludes it, and treating a parked dev server as
# unfinished would silence that session's finish notice for the rest of the day.
rm -rf "$PET_HOME/events"
emit UserPromptSubmit sSH /Users/dev/Projects/web
stop_with_tasks sSH /Users/dev/Projects/web \
  '[{"id":"t2","type":"shell","status":"running","description":"dev server","command":"npm run dev"}]'
check "a parked shell still counts as finished" "$(events)" "1"
check "...and the session goes idle" "$(field sSH state)" "idle"

# An older Claude Code sends no background_tasks at all. Absent must read as
# "nothing in flight", not as "unknown, so stay quiet".
rm -rf "$PET_HOME/events"
emit UserPromptSubmit sOLD /Users/dev/Projects/web
emit Stop sOLD /Users/dev/Projects/web
check "a payload with no background_tasks still finishes" "$(events)" "1"

# No temp files may be left lying around in either directory.
check "no stray temp files" \
  "$(ls "$PET_HOME/events" "$PET_HOME/sessions" 2>/dev/null | grep -c '\.tmp' || true)" "0"

# ---- activity log --------------------------------------------------------
rm -rf "$PET_HOME/activity"
# PostToolUse carries tool_use_id, duration_ms and tool_response; the plain
# emit() helper above sends none of them, so this one builds the payload itself.
post() {  # post <session> <cwd> <tool> <json tool_input> <duration> <interrupted>
  # One line: a backslash inside single quotes is a literal backslash, not a
  # line continuation, and it corrupted the JSON when this was wrapped.
  printf '{"hook_event_name":"PostToolUse","session_id":"%s","cwd":"%s","tool_name":"%s","tool_use_id":"toolu_%s","tool_input":%s,"duration_ms":%s,"tool_response":{"interrupted":%s}}' "$1" "$2" "$3" "$RANDOM" "$4" "$5" "$6" | "$EMIT"
}

post sL /Users/dev/Projects/api Bash '{"command":"npm test"}' 2900 false
check "a finished call is logged" \
  "$(wc -l < "$PET_HOME/activity/sL.jsonl" | tr -d ' ')" "1"
check "the log records what it ran" \
  "$(/usr/bin/python3 -c "import json;print(json.loads(open('$PET_HOME/activity/sL.jsonl').readline())['target'])")" \
  "npm test"
check "and how long Claude Code said it took" \
  "$(/usr/bin/python3 -c "import json;print(json.loads(open('$PET_HOME/activity/sL.jsonl').readline())['ms'])")" \
  "2900"

# A secret in the command must not reach the log.
post sL /Users/dev/Projects/api Bash '{"command":"deploy --token sk-live-abc123"}' 10 false
check "a token in the command never lands in the log" \
  "$(grep -c 'sk-live-abc123' "$PET_HOME/activity/sL.jsonl" || true)" "0"

post sL /Users/dev/Projects/api Bash '{"command":"sleep 99"}' 400 true
check "an interruption is recorded as such" \
  "$(grep -c '"result":"interrupted"' "$PET_HOME/activity/sL.jsonl" || true)" "1"
check "only the last call is kept, not a history" \
  "$(wc -l < "$PET_HOME/activity/sL.jsonl" | tr -d ' ')|$(grep -c 'npm test' "$PET_HOME/activity/sL.jsonl" || true)" "1|0"

# Trouble is a timestamp that CHANGES, not a flag that sits there — the app
# watches for the change so the warning fires once per failure.
post sT /Users/dev/Projects/api Bash '{"command":"npm test"}' 100 false
check "a clean call records no trouble" "$(field sT troubleAt)" ""
post sT /Users/dev/Projects/api Bash '{"command":"sleep 99"}' 400 true
FIRST_TROUBLE="$(field sT troubleAt)"
check "an interrupted call records when" \
  "$([ -n "$FIRST_TROUBLE" ] && echo yes || echo no)" "yes"
post sT /Users/dev/Projects/api Bash '{"command":"npm test"}' 100 false
check "a later clean call does not erase it" "$(field sT troubleAt)" "$FIRST_TROUBLE"
emit UserPromptSubmit sT /Users/dev/Projects/api
check "a new turn clears it — last turn's trouble is not this turn's" \
  "$(field sT troubleAt)" ""

# PreCompact puts the session in a phase, and the phase is cleared by the first
# event that can only happen afterwards — never by a timer.
emit PreCompact sP /Users/dev/Projects/api
check "compaction is a phase" "$(field sP phase)" "compacting"
emit Notification sP /Users/dev/Projects/api "" "something"
check "an unrelated event does not end it" "$(field sP phase)" "compacting"
emit PostToolUse sP /Users/dev/Projects/api Bash
check "the first event that can only follow it does" "$(field sP phase)" ""

# Ending the session takes its log with it: it describes something that no
# longer exists and nothing can reach it any more.
emit SessionEnd sL /Users/dev/Projects/api
check "SessionEnd removes the log" \
  "$([ -f "$PET_HOME/activity/sL.jsonl" ] && echo yes || echo no)" "no"

# notification_type decides when it is present; the English sentence is only
# the fallback for builds that do not send it.
emit UserPromptSubmit sN /tmp/n
emit_json '{"hook_event_name":"Notification","session_id":"sN","cwd":"/tmp/n","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
check "permission_prompt is waiting" "$(field sN state)" "waiting"
emit_json '{"hook_event_name":"Notification","session_id":"sN","cwd":"/tmp/n","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
check "idle_prompt is idle" "$(field sN state)" "idle"
emit_json '{"hook_event_name":"Notification","session_id":"sN","cwd":"/tmp/n","notification_type":"agent_needs_input","message":"x"}'
check "agent_needs_input is waiting" "$(field sN state)" "waiting"
emit UserPromptSubmit sN /tmp/n
# Not about the user at all; the sentence test used to call these "waiting".
emit_json '{"hook_event_name":"Notification","session_id":"sN","cwd":"/tmp/n","notification_type":"agent_completed","message":"Background agent finished"}'
check "agent_completed leaves the session alone" "$(field sN state)" "busy"
emit_json '{"hook_event_name":"Notification","session_id":"sN","cwd":"/tmp/n","notification_type":"quota_auto_resume_scheduled","message":"Resuming at 3pm"}'
check "a quota notice leaves the session alone" "$(field sN state)" "busy"

# A turn killed by an API error fires StopFailure, never Stop.
emit UserPromptSubmit sF /tmp/f
emit PreToolUse sF /tmp/f Bash
emit_json '{"hook_event_name":"StopFailure","session_id":"sF","cwd":"/tmp/f","error":"rate_limit"}'
check "StopFailure ends the turn" "$(field sF state)" "idle"
check "StopFailure clears tools in flight" "$(field sF running)" "[]"
check "StopFailure records no finish" \
  "$(ls "$PET_HOME/events" 2>/dev/null | grep -c '^sF~' | tr -d ' ')" "0"

# Stop carries Claude's last message; the record keeps its first line only.
rm -rf "$PET_HOME/events"
emit UserPromptSubmit sL /tmp/l
emit_json '{"hook_event_name":"Stop","session_id":"sL","cwd":"/tmp/l","last_assistant_message":"## All 12 tests pass\n\nPR opened at https://example.com/pr/1 with token abc"}'
check "a finish keeps the first line of what Claude said" "$(event_field 1 summary)" "All 12 tests pass"
emit UserPromptSubmit sM /tmp/m
emit Stop sM /tmp/m
check "a Stop with no message records no summary" \
  "$(/usr/bin/python3 -c "import json,glob,sys;print('summary' in json.load(open(glob.glob(sys.argv[1])[0])))" "$PET_HOME/events/sM~*.json")" "False"

# ---- a tool call that fails ---------------------------------------------------
# Claude Code sends PostToolUseFailure INSTEAD of PostToolUse for a failed call.
fail_call() {  # fail_call <session> <tool_use_id> [is_interrupt]
  printf '{"hook_event_name":"PostToolUseFailure","session_id":"%s","cwd":"/tmp/x","tool_name":"Bash","tool_use_id":"%s","tool_input":{"command":"npm test"},"error":"exit 1 secret=abc","is_interrupt":%s}' \
    "$1" "$2" "${3:-false}" | "$EMIT"
}
pre_call() {  # pre_call <session> <tool_use_id>
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","cwd":"/tmp/x","tool_name":"Bash","tool_use_id":"%s","tool_input":{"command":"npm test"}}' \
    "$1" "$2" | "$EMIT"
}
emit UserPromptSubmit sX /tmp/x
pre_call sX t1; fail_call sX t1
check "a failed call is no longer running" "$(field sX running)" "[]"
check "...and the session is still working" "$(field sX state)" "busy"
check "one failure starts the count" "$(field sX failStreak)" "1"
check "the count names what failed" "$(field sX failTarget)" "Bash npm test"
check "the error text is not kept" "$(grep -c secret "$PET_HOME/sessions/sX.json" | tr -d ' ')" "0"
pre_call sX t2; fail_call sX t2
check "a failed call reaches the activity log as failed" \
  "$(grep -c '"result":"failed"' "$PET_HOME/activity/sX.jsonl" | tr -d ' ')" "1"
pre_call sX t3; fail_call sX t3 true
check "an interrupt is not a failure" "$(field sX failStreak)" "2"
pre_call sX t4
printf '{"hook_event_name":"PostToolUse","session_id":"sX","cwd":"/tmp/x","tool_name":"Bash","tool_use_id":"t4","tool_response":{}}' | "$EMIT"
check "a success starts the count again" "$(field sX failStreak)" ""

# ---- answering a permission prompt from the pet ------------------------------
ask() {  # ask <session> — a PermissionRequest that waits up to 10s, stdout to a file
  printf '{"hook_event_name":"PermissionRequest","session_id":"%s","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}' "$1" \
    | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/$1.out" &
}
await_ask() {  # waits for the session file to carry an askId
  for _ in $(seq 1 40); do
    id="$(field "$1" askId 2>/dev/null)"; [ -n "$id" ] && { echo "$id"; return; }; sleep 0.05
  done
}
answer() {  # answer <session> <askId> <allow|deny>
  mkdir -p "$PET_HOME/decisions"
  printf '{"askId":"%s","behavior":"%s"}' "$2" "$3" > "$PET_HOME/decisions/$1.json"
}
decision() {
  /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['hookSpecificOutput']['decision']['behavior'])" "$PET_HOME/$1.out" 2>/dev/null
}

ask sP; pid=$!; id="$(await_ask sP)"
check "a permission request names its ask" "$([ -n "$id" ] && echo yes)" "yes"
answer sP "$id" allow; wait $pid
check "a click on Allow becomes the hook's answer" "$(decision sP)" "allow"
check "...and the answer file is used up" "$([ -e "$PET_HOME/decisions/sP.json" ] && echo left || echo gone)" "gone"

ask sQ; pid=$!; id="$(await_ask sQ)"
answer sQ "$id" deny; wait $pid
check "a click on Deny denies" "$(decision sQ)" "deny"

ask sR; pid=$!; id="$(await_ask sR)"
answer sR "not-this-ask" allow
emit PostToolUse sR /tmp/p Bash   # the prompt was answered in the terminal
wait $pid
check "an answer to some other ask approves nothing" "$(cat "$PET_HOME/sR.out")" ""

# A multiple-choice question is answered on its card: the hook is held like a
# permission's, and the picks come back as the tool's input — Allow alone would
# hand Claude no answers.
qjson() { /usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(eval(sys.argv[2]),sort_keys=True))" "$1" "$2"; }
printf '{"hook_event_name":"PermissionRequest","session_id":"sQA","cwd":"/tmp/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"a?"},{"question":"b?"}]}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sQA.out" &
pid=$!; id="$(await_ask sQA)"
check "a question card holds the hook under an ask" "$([ -n "$id" ] && [ -n "$(field sQA askHeldBy)" ] && echo yes)" "yes"
check "...the session is waiting" "$(field sQA state)" "waiting"
check "...on a reply, not an approval" "$(field sQA waitingOn)|$(field sQA askKind)" "|question"
check "...and says how many questions" "$(field sQA detail)" "2 questions to answer"
check "...with the questions for the board's menu" "$(qjson "$PET_HOME/sessions/sQA.json" "[q['question'] for q in d['questions']]")" '["a?", "b?"]'
emit Notification sQA /tmp/p "" "Claude needs your input"
check "a Notification under the same prompt keeps the ask and its menu" \
  "$(field sQA askId)|$(field sQA askKind)|$(qjson "$PET_HOME/sessions/sQA.json" "len(d.get('questions', []))")" "$id|question|2"
mkdir -p "$PET_HOME/decisions"
printf '{"askId":"%s","behavior":"allow","answers":{"a?":"yes","b?":"no"}}' "$id" > "$PET_HOME/decisions/sQA.json"
wait $pid
check "the picks come back as the tool's answers, questions kept" \
  "$(qjson "$PET_HOME/sQA.out" "[d['hookSpecificOutput']['decision'][k] for k in ('behavior','updatedInput')]")" \
  '["allow", {"answers": {"a?": "yes", "b?": "no"}, "questions": [{"question": "a?"}, {"question": "b?"}]}]'

# A plan is approved in its own dialog (Claude Code ignores a hook's allow for it); the board
# sends one back as a denial carrying the user's words. Its text is kept for the board, cut.
/usr/bin/python3 -c 'import json;print(json.dumps({"hook_event_name":"PermissionRequest","session_id":"sPL","cwd":"/tmp/p","tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan\n"+"x"*40000}}))' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sPL.out" &
pid=$!; id="$(await_ask sPL)"
check "a plan is held under an ask, as a plan" "$([ -n "$id" ] && echo yes)|$(field sPL askKind)|$(field sPL waitingOn)" "yes|plan|"
check "...says so in its row" "$(field sPL detail)" "a plan to approve"
check "...and keeps its text for the board, cut to the limit" "$(qjson "$PET_HOME/sessions/sPL.json" "[d['plan'][:6], len(d['plan'])]")" '["# Plan", 40000]'
printf '{"askId":"%s","behavior":"deny","message":"keep it smaller"}' "$id" > "$PET_HOME/decisions/sPL.json"
wait $pid
check "sending a plan back denies it with the user's words" \
  "$(qjson "$PET_HOME/sPL.out" "[d['hookSpecificOutput']['decision'][k] for k in ('behavior','message')]")" '["deny", "keep it smaller"]'

# ---- a prompt while other agents keep working ----------------------------------
# PermissionRequest carries no tool_use_id; the ask is tied to the PreToolUse of the same call
# (same agent, same tool and input) and stays up until THAT call's PostToolUse. Tool events of
# a subagent, or of the main thread's other calls, must not wash it out.
agent_call() {  # agent_call <event> <session> <agent|-> <tool_use_id> <command>
  local agent=""; [ "$3" != "-" ] && agent="\"agent_id\":\"$3\",\"agent_type\":\"general-purpose\","
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"/tmp/a",%s"tool_name":"Bash","tool_use_id":"%s","tool_input":{"command":"%s"},"tool_response":{}}' \
    "$1" "$2" "$agent" "$4" "$5" | "$EMIT"
}
agent_ask() {  # agent_ask <session> <agent|-> <command> — a PermissionRequest, not held
  local agent=""; [ "$2" != "-" ] && agent="\"agent_id\":\"$2\",\"agent_type\":\"general-purpose\","
  printf '{"hook_event_name":"PermissionRequest","session_id":"%s","cwd":"/tmp/a",%s"tool_name":"Bash","tool_input":{"command":"%s"}}' \
    "$1" "$agent" "$3" | "$EMIT"
}
emit UserPromptSubmit sSA /tmp/a
agent_call PreToolUse sSA a1 u1 "rm -rf build/"
agent_ask sSA a1 "rm -rf build/"
ask1="$(field sSA askId)"
check "a subagent's prompt makes the session wait" "$(field sSA state)|$([ -n "$ask1" ] && echo ask)" "waiting|ask"
agent_call PreToolUse sSA a2 u2 "ls"
agent_call PostToolUse sSA a2 u2 "ls"
check "another subagent's tool calls leave the prompt up" \
  "$(field sSA state)|$(field sSA askId)|$(field sSA waitingOnFull)" "waiting|$ask1|rm -rf build/"
agent_call PreToolUse sSA - m1 "git status"
agent_call PostToolUse sSA - m1 "git status"
check "...and so do the main thread's" "$(field sSA state)|$(field sSA askId)" "waiting|$ask1"
agent_call PreToolUse sSA a3 u3 "make deploy"
agent_ask sSA a3 "make deploy"
ask2="$(field sSA askId)"
check "a second prompt queues behind the first" "$(field sSA askId)" "$ask1"
agent_call PostToolUse sSA a1 u1 "rm -rf build/"
check "the first call finishing shows the next prompt" \
  "$(field sSA state)|$([ "$(field sSA askId)" != "$ask1" ] && [ -n "$(field sSA askId)" ] && echo next)|$(field sSA waitingOnFull)" \
  "waiting|next|make deploy"
agent_call PostToolUseFailure sSA a3 u3 "make deploy"
check "the last call ending stops the wait" "$(field sSA state)|$(field sSA askId)|$(field sSA waitingOn)" "busy||"

emit UserPromptSubmit sSB /tmp/a
agent_call PreToolUse sSB a1 u1 "rm -rf build/"
agent_ask sSB a1 "rm -rf build/"
emit Stop sSB /tmp/a
check "a turn ending clears its prompts" "$(field sSB state)|$(field sSB askId)" "idle|"

emit UserPromptSubmit sSQ /tmp/a
agent_ask sSQ - "rm -rf build/"
printf '{"hook_event_name":"PermissionRequest","session_id":"sSQ","cwd":"/tmp/a","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"a?"}]}}' | "$EMIT"
check "a question after a permission prompt carries no permission phrase" \
  "$(field sSQ askKind)|$(field sSQ waitingOn)|$(field sSQ askCommand)" "question||"

# Held: another agent's work must not make the hold give up, and the click still lands.
emit UserPromptSubmit sSH /tmp/a
agent_call PreToolUse sSH a1 h1 "rm -rf build/"
printf '{"hook_event_name":"PermissionRequest","session_id":"sSH","cwd":"/tmp/a","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sSH.out" &
pid=$!; id="$(await_ask sSH)"
agent_call PreToolUse sSH a2 h2 "ls"; agent_call PostToolUse sSH a2 h2 "ls"
sleep 0.4
answer sSH "$id" allow; wait $pid
check "a held prompt outlasts another agent's tool calls" "$(decision sSH)" "allow"

# Denied from the pet (or a plan sent back): Claude Code fires no PostToolUse and the turn goes
# on, so the hold itself takes its prompt down — else it hid the next prompt until Stop.
emit UserPromptSubmit sDN /tmp/a
agent_call PreToolUse sDN - d1 "rm -rf build/"
printf '{"hook_event_name":"PermissionRequest","session_id":"sDN","cwd":"/tmp/a","tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sDN.out" &
pid=$!; id="$(await_ask sDN)"
answer sDN "$id" deny; wait $pid
check "a prompt denied from the pet comes down at once" \
  "$(decision sDN)|$(field sDN state)|$(field sDN askId)|$(qjson "$PET_HOME/sessions/sDN.json" "[c['id'] for c in d['running']]")" "deny|busy||[]"
agent_call PreToolUse sDN - d2 "make deploy"
agent_ask sDN - "make deploy"
check "...and the next prompt is the one shown" \
  "$(field sDN waitingOnFull)|$(qjson "$PET_HOME/sessions/sDN.json" "len(d['asks'])")" "make deploy|1"

# Allowed from the pet while another agent's prompt waits behind it: the allowed call runs until
# its PostToolUse, but its prompt is answered — the next one comes first at once, and the call
# it was about stays running.
emit UserPromptSubmit sAQ /tmp/a
agent_call PreToolUse sAQ a1 q1 "sleep 90 && echo a"
printf '{"hook_event_name":"PermissionRequest","session_id":"sAQ","cwd":"/tmp/a","agent_id":"a1","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"sleep 90 && echo a"}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sAQ.out" &
pid=$!; id="$(await_ask sAQ)"
agent_call PreToolUse sAQ a2 q2 "touch /tmp/b"
agent_ask sAQ a2 "touch /tmp/b"
check "two agents' prompts queue, the first shown" \
  "$(field sAQ waitingOnFull)|$(qjson "$PET_HOME/sessions/sAQ.json" "len(d['asks'])")" "sleep 90 && echo a|2"
answer sAQ "$id" allow; wait $pid
check "allowing the first prompt shows the next one at once" \
  "$(decision sAQ)|$(field sAQ state)|$(field sAQ waitingOnFull)|$(qjson "$PET_HOME/sessions/sAQ.json" "[a['toolUseId'] for a in d['asks']]")" \
  'allow|waiting|touch /tmp/b|["q2"]'
check "...and the allowed call is still running" \
  "$(qjson "$PET_HOME/sessions/sAQ.json" "sorted(c['id'] for c in d['running'])")" '["q1", "q2"]'
agent_call PostToolUse sAQ a1 q1 "sleep 90 && echo a"
check "...until its PostToolUse, which leaves the next prompt up" \
  "$(field sAQ state)|$(field sAQ waitingOnFull)|$(qjson "$PET_HOME/sessions/sAQ.json" "[c['id'] for c in d['running']]")" \
  'waiting|touch /tmp/b|["q2"]'

# Allowed with nothing behind it: the session is busy running the call.
emit UserPromptSubmit sA1 /tmp/a
agent_call PreToolUse sA1 - r1 "make build"
printf '{"hook_event_name":"PermissionRequest","session_id":"sA1","cwd":"/tmp/a","tool_name":"Bash","tool_input":{"command":"make build"}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sA1.out" &
pid=$!; id="$(await_ask sA1)"
answer sA1 "$id" allow; wait $pid
check "a lone prompt allowed from the pet leaves the session busy on its call" \
  "$(decision sA1)|$(field sA1 state)|$(field sA1 askId)|$(qjson "$PET_HOME/sessions/sA1.json" "[c['id'] for c in d['running']]")" \
  'allow|busy||["r1"]'

# Two agents asking to run the same command: a shell running it can't tell whose it is, so
# neither prompt names its command for the app to watch for (StateAggregator.wasApproved).
emit UserPromptSubmit sSC /tmp/a
agent_call PreToolUse sSC a1 c1 "npm test"
printf '{"hook_event_name":"PermissionRequest","session_id":"sSC","cwd":"/tmp/a","agent_id":"a1","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sSC.out" &
pid=$!; id="$(await_ask sSC)"
check "a lone Bash prompt names its command" "$(field sSC askCommand)" "npm test"
agent_call PreToolUse sSC a2 c2 "npm test"
agent_ask sSC a2 "npm test"
check "...but not while another call runs the same command" "$(field sSC askCommand)" ""
answer sSC "$id" allow; wait $pid
check "...nor once the first is allowed and its call runs on" \
  "$(field sSC state)|$(field sSC waitingOnFull)|$(field sSC askCommand)|$(qjson "$PET_HOME/sessions/sSC.json" "[a['toolUseId'] for a in d['asks']]")" \
  'waiting|npm test||["c2"]'
agent_call PostToolUse sSC a1 c1 "npm test"
check "...and names it again when that call is done" "$(field sSC askCommand)" "npm test"

# Approved in the terminal: no hook says so, but Claude Code starts the shell that runs the
# command. A stand-in process named `claude` starts the holds and that shell, as Claude Code does.
FAKE="$(dirname "$PET_HOME")/fake"; mkdir -p "$FAKE"
cat > "$FAKE/claude.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(void) {  /* runs each line of stdin as a child, like Claude Code its hooks and shells */
  signal(SIGCHLD, SIG_IGN);
  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (*line && fork() == 0) { execl("/bin/sh", "sh", "-c", line, (char *)0); _exit(127); }
  }
  return 0;
}
C
if cc -o "$FAKE/claude" "$FAKE/claude.c" 2>/dev/null; then
  shell_case() {  # shell_case <session> <command A> <command B> [allow] — A asks first
    local s="$1"
    emit UserPromptSubmit "$s" /tmp/a
    agent_call PreToolUse "$s" a1 "${s}1" "$2"
    agent_call PreToolUse "$s" a2 "${s}2" "$3"
    for who in a1:"$2" a2:"$3"; do
      printf '{"transcript_path":"/f/s.jsonl","hook_event_name":"PermissionRequest","session_id":"%s","cwd":"/tmp/a","agent_id":"%s","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"%s"}}' \
        "$s" "${who%%:*}" "${who#*:}" > "$FAKE/$s-${who%%:*}.json"
    done
    # Write end here only, so closing it ends the stand-in (and the holds, which see it gone).
    rm -f "$FAKE/ctl"; mkfifo "$FAKE/ctl"
    "$FAKE/claude" < "$FAKE/ctl" > /dev/null 2>&1 & fake=$!
    exec 3> "$FAKE/ctl"
    for a in a1 a2; do
      echo "exec env PET_HOME='$PET_HOME' PET_PERMISSION_WAIT=10 '$EMIT_BIN' < '$FAKE/$s-$a.json' > '$FAKE/$s-$a.out'" >&3
      for _ in $(seq 1 40); do
        [ "$(qjson "$PET_HOME/sessions/$s.json" "sum(1 for a in d.get('asks', []) if a.get('heldBy'))" 2>/dev/null)" = "${a#a}" ] && break
        sleep 0.05
      done
    done
    [ "${4:-}" = allow ] && { answer "$s" "$(field "$s" askId)" allow; sleep 0.5; }
    echo "exec /bin/sh -c \"true /x/shell-snapshots/snapshot-1 && eval '$2'\"" >&3
    sleep 1.5
  }
  shell_done() { exec 3>&-; rm -f "$FAKE/ctl"; wait "$fake" 2>/dev/null; sleep 0.5; }

  shell_case sTS "sleep 3" "sleep 4"
  check "a prompt approved in the terminal comes down when its shell starts" \
    "$(field sTS state)|$(field sTS waitingOnFull)|$(qjson "$PET_HOME/sessions/sTS.json" "[a['toolUseId'] for a in d['asks']]")|$(cat "$FAKE/sTS-a1.out")" \
    'waiting|sleep 4|["sTS2"]|'
  check "...and the next prompt's hold goes on" "$(field sTS askHeldBy | grep -c .)" "1"
  shell_done

  shell_case sTT "sleep 3" "sleep 3" allow
  check "the same command asked twice: the first one's shell is not the second's approval" \
    "$(field sTT state)|$(field sTT waitingOnFull)|$(qjson "$PET_HOME/sessions/sTT.json" "[a['toolUseId'] for a in d['asks']]")|$(cat "$FAKE/sTT-a2.out")" \
    'waiting|sleep 3|["sTT2"]|'
  shell_done
else
  echo "  skip  approval seen in the shell (no C compiler)"
fi

# Denied in the terminal, the same: no PostToolUse. An agent has one prompt up at a time, so
# its next prompt replaces the one before.
emit UserPromptSubmit sDT /tmp/a
agent_call PreToolUse sDT a1 e1 "rm -rf build/"
agent_ask sDT a1 "rm -rf build/"
agent_call PreToolUse sDT a1 e2 "make deploy"
agent_ask sDT a1 "make deploy"
check "an agent's next prompt replaces the one it was denied" \
  "$(field sDT waitingOnFull)|$(qjson "$PET_HOME/sessions/sDT.json" "len(d['asks'])")" "make deploy|1"
agent_ask sDT a1 "make deploy"
check "...and the same call asking again is still one prompt" \
  "$(qjson "$PET_HOME/sessions/sDT.json" "[(a.get('toolUseId'), a.get('agent')) for a in d['asks']]")" '[["e2", "a1"]]'

# A subagent's PermissionRequest may come without agent_id: the call it matched names the agent,
# so a Stop that leaves the agent running keeps its prompt.
emit UserPromptSubmit sNA /tmp/a
agent_call PreToolUse sNA a7 n1 "rm -rf build/"
agent_ask sNA - "rm -rf build/"
emit_json '{"hook_event_name":"Stop","session_id":"sNA","cwd":"/tmp/a","background_tasks":[{"id":"t1","type":"subagent","status":"running","description":"x","agent_type":"general-purpose"}]}'
check "a subagent's prompt without agent_id outlasts the main thread's Stop" \
  "$(field sNA state)|$(qjson "$PET_HOME/sessions/sNA.json" "[a.get('agent') for a in d.get('asks', [])]")" 'waiting|["a7"]'

# ---- hooks of one session running at once ----------------------------------------
# Parallel tool calls fire their hooks together; every read-modify-write of the session file
# must see the one before it.
emit UserPromptSubmit sCC /tmp/c
lost=0
for round in 1 2 3; do
  for i in 1 2 3 4 5 6 7 8; do agent_call PreToolUse sCC - "c$round$i" "true $i" & done; wait
  n="$(qjson "$PET_HOME/sessions/sCC.json" "len(d['running'])")"
  [ "$n" = "8" ] || lost=$((lost + 1))
  for i in 1 2 3 4 5 6 7 8; do agent_call PostToolUse sCC - "c$round$i" "true $i" & done; wait
  n="$(qjson "$PET_HOME/sessions/sCC.json" "len(d['running'])")"
  [ "$n" = "0" ] || lost=$((lost + 1))
done
check "parallel hooks lose no update to the running list" "$lost" "0"
emit SessionEnd sCC /tmp/c
check "a session ending takes its lock with it" "$([ -e "$PET_HOME/sessions/.sCC.lock" ] && echo left || echo gone)" "gone"

# ---- an editor's integrated terminal ------------------------------------------
terminal() {  # terminal <session_id> → "kind handle"
  /usr/bin/python3 -c "import json,sys;t=json.load(open(sys.argv[1])).get('terminal') or {};print(t.get('kind',''),t.get('handle',''))" \
    "$PET_HOME/sessions/$1.json"
}
printf '{"hook_event_name":"SessionStart","session_id":"sC","cwd":"/w/app","transcript_path":"/fixture/sC.jsonl"}' \
  | env -u ORCA_TERMINAL_HANDLE -u ITERM_SESSION_ID TERM_PROGRAM=vscode \
        __CFBundleIdentifier=com.todesktop.230313mzl4w4u92 "$EMIT_BIN"
check "Cursor's terminal is recorded with the app and the directory" \
  "$(terminal sC)" "vscode com.todesktop.230313mzl4w4u92|/w/app"
printf '{"hook_event_name":"SessionStart","session_id":"sT","cwd":"/w/app","transcript_path":"/fixture/sT.jsonl"}' \
  | env -u ITERM_SESSION_ID ORCA_TERMINAL_HANDLE=term_stale TERM_PROGRAM=Apple_Terminal "$EMIT_BIN"
# Terminal.app tabs answer to their tty, resolved from the Claude Code process like Ghostty's.
# Under a test runner there may or may not be one; an inherited Orca handle is never used.
case "$(terminal sT)" in
  " "|"terminal /dev/tty"*) apple_handle="a tty path or nothing" ;;
  *) apple_handle="$(terminal sT)" ;;
esac
check "Terminal.app is addressed by tty or not at all, never by an inherited handle" \
  "$apple_handle" "a tty path or nothing"

# ---- Ghostty ------------------------------------------------------------------
# The handle is the Claude Code process's tty, resolved from its pid — the hook
# cannot read its own, being run detached. Whether one is resolvable depends on
# where this script runs: under a real session there is a Claude Code ancestor
# holding a terminal, in CI there is not. So what is asserted is the shape rather
# than a value. GHOSTTY_SURFACE_ID is exported precisely because it must NOT be
# used: it is an address, not the id Ghostty's scripting interface answers to,
# and a jump on it would match no tab.
printf '{"hook_event_name":"SessionStart","session_id":"sG","cwd":"/w/app","transcript_path":"/fixture/sG.jsonl"}' \
  | env -u ORCA_TERMINAL_HANDLE -u ITERM_SESSION_ID TERM_PROGRAM=ghostty \
        GHOSTTY_SURFACE_ID=0x26088a1939867766 "$EMIT_BIN"
case "$(terminal sG)" in
  " "|"ghostty /dev/tty"*) ghostty_handle="a tty path or nothing" ;;
  *) ghostty_handle="$(terminal sG)" ;;
esac
check "a ghostty handle is a tty path or nothing, never the surface id" \
  "$ghostty_handle" "a tty path or nothing"

# --- a scheduled job's Claude run ---
# Nobody is at that session: the hook writes nothing, so the pet neither shows it nor holds a
# permission prompt open for it.
printf '{"hook_event_name":"SessionStart","session_id":"sJob","cwd":"/w/app"}' | CLAUDE_PET_JOB=j1 "$EMIT"
printf '{"hook_event_name":"PermissionRequest","session_id":"sJob","cwd":"/w/app","tool_name":"Bash"}' | CLAUDE_PET_JOB=j1 "$EMIT"
check "a scheduled job's session leaves no session file" "$([ -e "$PET_HOME/sessions/sJob.json" ] && echo yes || echo no)" "no"

# --- one run of a scheduled job ---
mkdir -p "$PET_HOME/jobs/jt"
printf '{"id":"jt","name":"t","kind":"shell","command":"echo out-$CLAUDE_PET_JOB; exit 4","cwd":"/tmp"}' > "$PET_HOME/jobs/jt/job.json"
"$EMIT" --run-job jt --manual
last() { /usr/bin/python3 -c "import json,sys;print(json.loads(open(sys.argv[1]).read().splitlines()[-1]).get(sys.argv[2],''))" "$PET_HOME/jobs/jt/runs.jsonl" "$1"; }
check "a run records its end" "$(last event)" "end"
check "…its exit code" "$(last exitCode)" "4"
check "…as a failure" "$(last status)" "fail"
check "…with the last output line, which saw CLAUDE_PET_JOB" "$(last summary)" "out-jt"
check "an unknown job is an error" "$("$EMIT" --run-job nope >/dev/null 2>&1; echo $?)" "2"

# --- the statusline's per-session insight ---
# The app re-reads insight/ only when the folder's modification time moves. A file
# rewritten in place never moves it, so the pet saw a session's first reading and
# nothing after; a rename (a new inode each time) does.
sl() { printf '{"session_id":"sI","model":{"display_name":"%s"},"context_window":{"used_percentage":%s}}' "$1" "$2" \
  | "$EMIT_BIN" --statusline >/dev/null; }
INS="$PET_HOME/insight/sI.json"
sl Opus 10
first_inode="$(stat -f %i "$INS" 2>/dev/null)"
sl Sonnet 20
check "the insight file is replaced, not rewritten in place" \
  "$([ -n "$first_inode" ] && [ "$first_inode" != "$(stat -f %i "$INS")" ] && echo yes || echo no)" "yes"
check "…and holds the newest reading" "$(grep -c Sonnet "$INS" | tr -d ' ')" "1"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
exit $((fails > 0))
