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

# --- an unknown event must not touch the state ---
emit PreCompact s1 /Users/dev/Projects/demo-app
check "unknown event leaves state alone" "$(field s1 state)" "idle"

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

# Ending the session takes its log with it: it describes something that no
# longer exists and nothing can reach it any more.
emit SessionEnd sL /Users/dev/Projects/api
check "SessionEnd removes the log" \
  "$([ -f "$PET_HOME/activity/sL.jsonl" ] && echo yes || echo no)" "no"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
exit $((fails > 0))
