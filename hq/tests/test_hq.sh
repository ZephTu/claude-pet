#!/bin/bash
# End-to-end test of hq in a throwaway HOME. Run: hq/tests/test_hq.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool"}]}]}}' > "$HOME/.claude/settings.json"
unset CLAUDE_CODE_SESSION_ID HQ_ROOT HQ_HOOK_CHILD
HQ="$HOME/.claude/hq/bin/hq"
pass=0
ok() { pass=$((pass+1)); echo "  ok - $1"; }
fail() { echo "  FAIL - $1"; exit 1; }
hook() { echo "$1" | "$HQ" hook; }

"$SRC/install.sh" --root "$T/root" --yes >/dev/null
python3 - "$HOME/.claude/settings.json" <<'PY' && ok "install wires 3 hooks and keeps existing ones"
import json, sys
s = json.load(open(sys.argv[1]))["hooks"]
assert any(h["command"] == "other-tool" for g in s["Stop"] for h in g["hooks"])
for ev in ("SessionStart", "UserPromptSubmit", "Stop"):
    assert sum(".claude/hq/bin/hq hook" in h["command"] for g in s[ev] for h in g["hooks"]) == 1, ev
PY
"$SRC/install.sh" --yes >/dev/null
[ "$(grep -o 'hq/bin/hq hook' "$HOME/.claude/settings.json" | wc -l | tr -d ' ')" = 3 ] && ok "re-install is idempotent"
[ -f "$HOME/.claude/commands/task.md" ] && [ -f "$T/root/CLAUDE.md" ] && [ -f "$T/root/hq.json" ] && ok "commands and root scaffolded"
echo n | "$SRC/install.sh" >/dev/null 2>&1 && fail "install without --yes on a pipe should refuse" || ok "install refuses without confirmation"
H2="$T/home2"; mkdir -p "$H2/.claude"; echo '{}' > "$H2/.claude/settings.json"
HOME="$H2" "$SRC/install.sh" --root "$T/root2" --yes --no-hooks --no-commands >/dev/null
grep -q hq "$H2/.claude/settings.json" && fail "--no-hooks touched settings" || ok "--no-hooks leaves settings.json alone"
[ ! -e "$H2/.claude/commands/task.md" ] && ok "--no-commands skips slash commands"

out="$("$HQ" new "Benchmark vs Neo4j" --category benchmark --workdir "$T")"
TID="$(echo "$out" | head -1)"; [ "$TID" = "T-001" ] && ok "new task gets T-001"
"$HQ" new "Second" >/dev/null && [ -d "$T/root/tasks/T-002-second" ] && ok "ids increment"

[ -z "$(hook '{"session_id":"s-unbound","hook_event_name":"SessionStart"}')" ] && ok "unbound session: hook is silent"

"$HQ" bind T-001 --session sess-1 | grep -q "bound to HQ task T-001" && ok "bind prints protocol"
grep -q '"sess-1"' "$T"/root/tasks/T-001-*/TASK.md && ok "bind records session on card"
mkdir -p "$T/repo-a"; (cd "$T/repo-a" && CLAUDE_CODE_SESSION_ID=sess-in "$HQ" bind T-002 >/dev/null)
grep -q "repo-a" "$T"/root/tasks/T-002-*/TASK.md && ok "bind from inside a session records its workdir"
(cd "$HOME" && CLAUDE_CODE_SESSION_ID=sess-home "$HQ" bind T-002 >/dev/null)
grep -q "\"$HOME\"" "$T"/root/tasks/T-002-*/TASK.md && fail "home dir recorded as workdir" || ok "home dir is never a workdir"
"$HQ" unbind --session sess-in >/dev/null; "$HQ" unbind --session sess-home >/dev/null
hook '{"session_id":"sess-1","hook_event_name":"SessionStart"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "hq-asks" in c' && ok "SessionStart injects protocol"

MSG='Done.\n\n```hq-asks\n- Approve plan v2?\n- Ask Chengjie for the dataset\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
[ "$("$HQ" asks T-001 | wc -l | tr -d ' ')" = 2 ] && ok "Stop hook records asks from hq-asks block"

"$HQ" ask resolve T-001.1 do "go with v2" --via board
ctx="$(hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$ctx" | grep -q "T-001.1 → do: go with v2" && ok "board answer injected on next prompt"
echo "$ctx" | grep -q "T-001.2: Ask Chengjie" && ok "still-open asks re-injected"
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "T-001.1 → do" && fail "board answer delivered twice" || ok "board answer delivered once"

MSG2='ok\n```hq-resolved\n- T-001.2 later: waiting on Chengjie\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG2\"}" >/dev/null
"$HQ" asks T-001 --all | grep -q "T-001.2.*\[later: waiting on Chengjie\]" && ok "hq-resolved block resolves ask"

printf '\n- [ ] @me review the plan\n- [ ] @claude draft the pilot\n' >> "$T"/root/tasks/T-001-*/TASK.md
"$HQ" todo T-001 1 done --via board
grep -q -- "- \[x\] @me review the plan" "$T"/root/tasks/T-001-*/TASK.md && ok "todo toggled"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["todos"][1]["owner"]=="claude"; assert len(t["asks"])==2' && ok "board --json exposes todos and asks"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][1]; assert t["refs"]==[] and isinstance(t["workdirs"], list), t' && ok "list fields with template comments parse as lists"

"$HQ" addtodo T-001 "@me ping Wenbing" && grep -A2 "draft the pilot" "$T"/root/tasks/T-001-*/TASK.md | grep -q "@me ping Wenbing" && ok "addtodo appends after last todo"
"$HQ" bind T-002 --session sess-2 >/dev/null
hook '{"session_id":"sess-2","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "bound this session to an HQ task from the board" && ok "board-side bind announced on next prompt"
hook '{"session_id":"sess-2","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "from the board" && fail "announced twice" || ok "announcement only once"
# categories: generic defaults, add / rename / guarded remove
"$HQ" category list | grep -q "^feature" && ok "default categories are generic"
"$HQ" set T-002 category=bug >/dev/null
"$HQ" category add perf && "$HQ" category list | grep -q "^perf" && ok "category add"
"$HQ" category rename bug defect >/dev/null && grep -q "^category: defect" "$T"/root/tasks/T-002-*/TASK.md && ok "rename rewrites cards"
rc=0; "$HQ" category remove defect 2>/dev/null || rc=$?; [ "$rc" = 3 ] && ok "removing a used category needs --to"
"$HQ" category remove defect --to perf >/dev/null && grep -q "^category: perf" "$T"/root/tasks/T-002-*/TASK.md && ! "$HQ" category list | grep -q "^defect" && ok "remove --to moves tasks and logs it"
grep -q "category 'defect' → 'perf'" "$T"/root/tasks/T-002-*/TASK.md && ok "recategorize is logged on the card"
"$HQ" category remove perf --to '' >/dev/null && grep -q "^category: *$" "$T"/root/tasks/T-002-*/TASK.md && ok "remove --to '' leaves tasks uncategorized"
"$HQ" category add 'a#b' 2>/dev/null && fail "bad category accepted" || ok "category names are validated"
"$HQ" set T-001 status=waiting-on-me "waiting_on_me=pick a dataset"
"$HQ" board | grep -q "等你: pick a dataset" && ok "set + board"

# write-back guard: a long turn that never touched the card is nudged once
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["sess-1"]["turn_start"] = time.time() - 600; json.dump(s, open(p, "w"))
PY
touch -t 200001010000 "$T"/root/tasks/T-001-*/TASK.md
hook '{"session_id":"sess-1","hook_event_name":"Stop","last_assistant_message":"x"}' | grep -q '"decision": "block"' && ok "write-back guard blocks stale card"
hook '{"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"x"}' | grep -q block && fail "guard looped" || ok "guard does not loop"

"$SRC/uninstall.sh" >/dev/null
grep -q 'hq/bin/hq hook' "$HOME/.claude/settings.json" && fail "uninstall left hooks" || ok "uninstall removes hooks, keeps others"
grep -q other-tool "$HOME/.claude/settings.json" && [ -d "$T/root/tasks/T-001-benchmark-vs-neo4j" ] && ok "uninstall keeps other hooks and data"
echo "$pass passed"
