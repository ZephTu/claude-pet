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
[ -f "$HOME/.claude/commands/task.md" ] && [ -f "$HOME/.claude/commands/hq-onboard.md" ] && [ -f "$T/root/CLAUDE.md" ] && [ -f "$T/root/hq.json" ] && ok "commands and root scaffolded"
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
"$HQ" asks T-001 --json | python3 -c 'import json,sys; a=json.load(sys.stdin)[0]; assert a["context"].startswith("Done.") and "hq-asks" not in a["context"], a' && ok "asks keep the reply that raised them"

"$HQ" ask resolve T-001.1 do "go with v2" --via board
ctx="$(hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$ctx" | grep -q "T-001.1 → do: go with v2" && ok "board answer injected on next prompt"
echo "$ctx" | grep -q "T-001.2: Ask Chengjie" && ok "still-open asks re-injected"
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "T-001.1 → do" && fail "board answer delivered twice" || ok "board answer delivered once"
"$HQ" ask add T-001 "Deploy now?" >/dev/null; "$HQ" ask resolve T-001.3 do --via board --note "yes"; "$HQ" ask delivered T-001.3 --session sess-1
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "T-001.3 → do" && fail "pushed answer injected again" || ok "an answer already sent to the session is not injected again"

MSG2='ok\n```hq-resolved\n- T-001.2 later: waiting on Chengjie\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG2\"}" >/dev/null
"$HQ" asks T-001 --all | grep -q "T-001.2.*\[later: waiting on Chengjie\]" && ok "hq-resolved block resolves ask"
"$HQ" ask reopen T-001.2 && "$HQ" asks T-001 | grep -q "T-001.2" && ok "ask reopen undoes a resolution"
"$HQ" ask resolve T-001.2 later --note "waiting on Chengjie"

printf '\n- [ ] @me review the plan\n- [ ] @claude draft the pilot\n' >> "$T"/root/tasks/T-001-*/TASK.md
"$HQ" todo T-001 1 done --via board
grep -q -- "- \[x\] @me review the plan" "$T"/root/tasks/T-001-*/TASK.md && ok "todo toggled"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["todos"][1]["owner"]=="claude"; assert len(t["asks"])==3' && ok "board --json exposes todos and asks"
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
"$HQ" ref add T-001 "https://example.com/doc" && "$HQ" ref add T-001 "QA-1" && "$HQ" board --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["tasks"][0]["refs"]==["https://example.com/doc","QA-1"]' && ok "ref add"
"$HQ" ref remove T-001 "QA-1" && "$HQ" board --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["tasks"][0]["refs"]==["https://example.com/doc"]' && ok "ref remove"
# projects: auto-assign by directory, rename / guarded remove like categories
mkdir -p "$T/proj-x/sub"
"$HQ" project add projx --path "$T/proj-x" && "$HQ" project list | grep -q "^projx" && ok "project add"
P="$("$HQ" new "in project" --workdir "$T/proj-x/sub" | head -1)"
grep -q "^project: projx" "$T"/root/tasks/$P-*/TASK.md && ok "new task gets its project from the workdir"
"$HQ" new "no dir" >/dev/null; Q="$(ls "$T/root/tasks" | grep no-dir | cut -d- -f1-2)"
(cd "$T/proj-x" && CLAUDE_CODE_SESSION_ID=sess-px "$HQ" bind "$Q" >/dev/null)
grep -q "^project: projx" "$T"/root/tasks/$Q-*/TASK.md && ok "binding a session in a project dir assigns the project"
"$HQ" unbind --session sess-px >/dev/null
"$HQ" project rename projx projy >/dev/null && grep -q "^project: projy" "$T"/root/tasks/$P-*/TASK.md && ok "project rename rewrites cards"
rc=0; "$HQ" project remove projy 2>/dev/null || rc=$?; [ "$rc" = 3 ] && ok "removing a used project needs --to"
"$HQ" project remove projy --to '' >/dev/null && grep -q "^project: *$" "$T"/root/tasks/$P-*/TASK.md && ok "remove --to '' leaves tasks without a project"
"$HQ" project add projz --path "$T/proj-x" >/dev/null && "$HQ" project auto | grep -q "assigned 2" && ok "project auto assigns by workdir"
printf -- '---\nid: T-099\nproject:                 # a comment\nstatus: active\n---\n' > /dev/null
"$HQ" board --json | python3 -c 'import json,sys; assert all(not str(t.get("project","")).startswith("#") for t in json.load(sys.stdin)["tasks"])' && ok "a blank field followed by a comment parses as empty"
"$HQ" project add pa >/dev/null; "$HQ" project add pb >/dev/null
"$HQ" project order pb pa && [ "$("$HQ" project list --json | python3 -c 'import json,sys; n=[p["name"] for p in json.load(sys.stdin) if p["listed"]]; print(n.index("pb") < n.index("pa"))')" = True ] && ok "project order"
# onboarding scan: a fake transcript in a git repo becomes a suggested project
mkdir -p "$T/repo-g/.git" "$HOME/.claude/projects/-x-repo-g"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$T/repo-g\",\"message\":{\"content\":\"fix the flaky test\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}" \
  "{\"type\":\"custom-title\",\"customTitle\":\"flaky test\"}" > "$HOME/.claude/projects/-x-repo-g/abcdef12-0000.jsonl"
"$HQ" scan --json | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for x in d["projects"] if x["name"]=="repo-g"][0]; assert p["count"]==1 and not p["existing"]; s=[x for x in d["sessions"] if x["sessionId"].startswith("abcdef12")][0]; assert s["title"]=="flaky test" and s["first"]=="fix the flaky test"' && ok "scan proposes a project per repo with its sessions"
"$HQ" scan --apply-projects --only repo-g >/dev/null && "$HQ" project list | grep -q "^repo-g" && ok "scan --apply-projects creates the chosen project"
"$HQ" scan --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert [x for x in d["projects"] if x["name"]=="repo-g"][0]["existing"]=="repo-g"' && ok "rescan marks it existing"
grep -q "@me ping Wenbing <!--t:" "$T"/root/tasks/T-001-*/TASK.md && ok "addtodo stamps a hidden creation time"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; o=[x for x in t["todos"] if x["state"]=="open"]; assert all(x["created"] for x in o) and not any("<!--" in x["text"] for x in t["todos"]), o' && ok "every open todo has a created time; the stamp is hidden"
"$HQ" set T-001 status=waiting-on-me "next=pick a dataset"
"$HQ" board | grep -q "你: ping Wenbing" && ok "set + board shows your next todo"
"$HQ" set T-002 "waiting_on_me=legacy text" && "$HQ" board | grep -q "legacy text" && ok "a leftover waiting_on_me still shows as yours"
"$HQ" set T-002 "waiting_on_me=" >/dev/null

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
