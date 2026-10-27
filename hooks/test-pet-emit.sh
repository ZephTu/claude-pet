#!/bin/bash
# Test pet-emit.sh against a throwaway PET_HOME.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Point at the Swift binary; PET_EMIT can override it (packaging tests reuse this).
EMIT="${PET_EMIT:-$HERE/../.build/debug/PetEmit}"
if [ ! -x "$EMIT" ]; then
  echo "PetEmit binary not found: $EMIT"
  echo "run swift build before this test"
  exit 1
fi
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

# A secret in the command must not reach the log — this file lives for a day.
post sL /Users/dev/Projects/api Bash '{"command":"deploy --token sk-live-abc123"}' 10 false
check "a token in the command never lands in the log" \
  "$(grep -c 'sk-live-abc123' "$PET_HOME/activity/sL.jsonl" || true)" "0"

post sL /Users/dev/Projects/api Bash '{"command":"sleep 99"}' 400 true
check "an interruption is recorded as such" \
  "$(grep -c '"result":"interrupted"' "$PET_HOME/activity/sL.jsonl" || true)" "1"

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
pre_call sX t3; fail_call sX t3 true
check "an interrupt is not a failure" "$(field sX failStreak)" "2"
pre_call sX t4
printf '{"hook_event_name":"PostToolUse","session_id":"sX","cwd":"/tmp/x","tool_name":"Bash","tool_use_id":"t4","tool_response":{}}' | "$EMIT"
check "a success starts the count again" "$(field sX failStreak)" ""
check "a failed call reaches the activity log as failed" \
  "$(grep -c '"result":"failed"' "$PET_HOME/activity/sX.jsonl" | tr -d ' ')" "2"

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

# A multiple-choice question is answered on its card; Allow from outside would
# hand Claude no answers, so the pet must not offer it or hold the hook.
start=$(date +%s)
printf '{"hook_event_name":"PermissionRequest","session_id":"sA","cwd":"/tmp/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"a?"},{"question":"b?"}]}}' \
  | PET_PERMISSION_WAIT=10 "$EMIT" > "$PET_HOME/sA.out"
check "a question card does not hold the hook" "$(( $(date +%s) - start < 3 ))" "1"
check "...and answers nothing" "$(cat "$PET_HOME/sA.out")" ""
check "...but the session is waiting" "$(field sA state)" "waiting"
check "...on a reply, not an approval" "$(field sA waitingOn)|$(field sA askId)" "|"
check "...and says how many questions" "$(field sA detail)" "2 questions to answer"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
exit $((fails > 0))
