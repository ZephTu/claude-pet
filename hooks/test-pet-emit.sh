#!/bin/bash
# Test pet-emit.sh against a throwaway PET_HOME.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# Point at the Swift binary; PET_EMIT can override it (packaging tests reuse this).
EMIT="${PET_EMIT:-$HERE/../.build/debug/PetEmit}"
if [ ! -x "$EMIT" ]; then
  echo "找不到 PetEmit 二进制：$EMIT"
  echo "先跑 swift build 再执行本测试"
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

# --- 事件到 state 的映射 ---
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

# --- since 的维护：state 不变则沿用 ---
emit Notification s2 /tmp/proj "" "waiting one"
first_since="$(field s2 since)"
sleep 1
emit Notification s2 /tmp/proj "" "waiting two"
check "since is kept while state is unchanged" "$(field s2 since)" "$first_since"

emit Stop s2 /tmp/proj
changed_since="$(field s2 since)"
check "since is refreshed when state changes" \
  "$([ "$changed_since" != "$first_since" ] && echo yes || echo no)" "yes"

# --- updatedAt 每次都刷新 ---
emit Stop s2 /tmp/proj
sleep 1
before_updated="$(field s2 updatedAt)"
emit Stop s2 /tmp/proj
check "updatedAt always moves" \
  "$([ "$(field s2 updatedAt)" != "$before_updated" ] && echo yes || echo no)" "yes"

# --- 一个 session 一个文件 ---
check "one file per session" "$(ls "$PET_HOME/sessions" | wc -l | tr -d ' ')" "2"

# --- 绝不失败 ---
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

# --- 未知事件不该污染状态 ---
emit PreCompact s1 /Users/dev/Projects/demo-app
check "unknown event leaves state alone" "$(field s1 state)" "idle"

# --- Notification 分两类：等授权才算 waiting，等输入只是说完了 ---
emit Notification s3 /tmp/permproj "" "Claude needs your permission to use Bash"
check "permission notification means waiting" "$(field s3 state)" "waiting"

emit Notification s4 /tmp/inputproj "" "Claude is waiting for your input"
check "input notification is not waiting" "$(field s4 state)" "idle"
check "input notification keeps its message" "$(field s4 detail)" "Claude is waiting for your input"

# 等输入的提示重复到来，不能把 session 拖成 waiting
emit Notification s4 /tmp/inputproj "" "Claude is waiting for your input"
check "repeated input notification stays idle" "$(field s4 state)" "idle"

# 真的等授权时，重复通知仍然是 waiting
emit Notification s3 /tmp/permproj "" "Claude needs your permission to use Read"
check "repeated permission notification stays waiting" "$(field s3 state)" "waiting"

# 没有 message 的 Notification 按等授权处理（保守：宁可提醒也不漏）
emit Notification s5 /tmp/blankproj "" ""
check "notification without message is waiting" "$(field s5 state)" "waiting"

# --- SessionEnd 立刻删掉状态文件，不等 15 分钟超时 ---
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
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
exit $((fails > 0))
