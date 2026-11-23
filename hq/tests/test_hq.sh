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
echo "$ctx" | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "- T-001.1 \"Approve plan v2?\" → answer: go with v2" in c, c' && ok "board answer injected on next prompt"
echo "$ctx" | grep -q "T-001.2: Ask Chengjie" && ok "still-open asks re-injected"
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | python3 -c 'import json,sys; t=sys.stdin.read(); c=json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else ""; assert not any(x.startswith("- T-001.1 ") for x in c.splitlines()), c' && ok "board answer delivered once" || fail "board answer delivered twice"
"$HQ" ask add T-001 "Deploy now?" >/dev/null; "$HQ" ask resolve T-001.3 do --via board --note "yes"; "$HQ" ask delivered T-001.3 --session sess-1
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert not any(x.startswith("- T-001.3 ") for x in c.splitlines()), c' && ok "an answer already sent to the session is not injected again" || fail "pushed answer injected again"
"$HQ" ask add T-001 "$(printf 'x%.0s' {1..80}) long question" >/dev/null
"$HQ" ask resolve T-001.4 drop --via board >/dev/null
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; l=[x for x in c.splitlines() if x.startswith("- T-001.4 ")][0]; assert l == "- T-001.4 \"" + "x"*30 + "…\" → no", l' && ok "an injected answer quotes only the question's opening words"

MSG2='ok\n```hq-resolved\n- T-001.2 later: waiting on Chengjie\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG2\"}" >/dev/null
"$HQ" asks T-001 --all | grep -q "T-001.2.*\[later: waiting on Chengjie\]" && ok "hq-resolved block resolves ask"
"$HQ" ask reopen T-001.2 && "$HQ" asks T-001 | grep -q "T-001.2" && ok "ask reopen undoes a resolution"
"$HQ" ask resolve T-001.2 later --note "waiting on Chengjie"

printf '\n- [ ] @me review the plan\n- [ ] @claude draft the pilot\n' >> "$T"/root/tasks/T-001-*/TASK.md
"$HQ" todo T-001 1 done --via board
grep -q -- "- \[x\] @me review the plan" "$T"/root/tasks/T-001-*/TASK.md && ok "todo toggled"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["todos"][1]["owner"]=="claude"; assert len(t["asks"])==4' && ok "board --json exposes todos and asks"
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
"$HQ" ref remove T-001 "QA-1" >/dev/null && "$HQ" board --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["tasks"][0]["refs"]==["https://example.com/doc"]' && ok "ref remove"
"$HQ" ref add T-001 "doc v2 https://example.com/doc/" && "$HQ" board --json | python3 -c 'import json,sys; r=json.load(sys.stdin)["tasks"][0]["refs"]; assert r==["doc v2 https://example.com/doc/"], r' && ok "ref add with a known URL replaces the title in place"
"$HQ" ref add T-001 "QA-2" && "$HQ" ref remove T-001 "https://example.com/doc" >/dev/null && "$HQ" board --json | python3 -c 'import json,sys; r=json.load(sys.stdin)["tasks"][0]["refs"]; assert r==["QA-2"], r' && ok "ref remove by URL drops every entry with it"
refs() { "$HQ" board --json | python3 -c 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin)["tasks"] if t["id"]=="T-001"][0]["refs"], ensure_ascii=False))'; }
"$HQ" ref add T-001 "compare https://a.example/x https://b.example/y" && "$HQ" ref add T-001 "x https://a.example/x" && "$HQ" ref add T-001 "y https://b.example/y" \
  && [ "$(refs)" = '["QA-2", "compare https://a.example/x https://b.example/y", "x https://a.example/x", "y https://b.example/y"]' ] && ok "a ref with two URLs is keyed by its whole text, not its first link" || fail "multi-URL ref merged: $(refs)"
"$HQ" ref remove T-001 "https://a.example/x" >/dev/null && [ "$(refs)" = '["QA-2", "compare https://a.example/x https://b.example/y", "y https://b.example/y"]' ] && ok "removing a link leaves a two-URL ref that mentions it" || fail "multi-URL ref removed: $(refs)"
"$HQ" ref add T-001 "compare  https://a.example/x   https://b.example/y" && "$HQ" ref add T-001 "QA-2 " && [ "$(refs)" = '["QA-2", "compare  https://a.example/x   https://b.example/y", "y https://b.example/y"]' ] && ok "refs without one URL match with whitespace collapsed" || fail "whitespace key: $(refs)"
"$HQ" ref remove T-001 "compare https://a.example/x https://b.example/y" >/dev/null && "$HQ" ref remove T-001 "y https://b.example/y" >/dev/null && [ "$(refs)" = '["QA-2"]' ] || fail "cleanup: $(refs)"
"$HQ" ref add T-001 "see https://example.com/p/1)." && "$HQ" ref add T-001 "p1 https://example.com/p/1/;" && "$HQ" ref add T-001 "p1 merged https://example.com/p/1" \
  && [ "$(refs)" = '["QA-2", "p1 merged https://example.com/p/1"]' ] && ok "trailing / ) . , ; : don't split a link's key" || fail "punctuation split keys: $(refs)"
"$HQ" ref add T-001 "full-width https://example.com/p/1）。" && [ "$(refs)" = '["QA-2", "full-width https://example.com/p/1）。"]' ] && ok "full-width punctuation after a URL is not part of it" || fail "full-width: $(refs)"
# remove prints what went; restore puts every entry back where it was
C001="$(ls "$T"/root/tasks/T-001-*/TASK.md)"
python3 - "$C001" <<'PY2'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"^refs: .*$", 'refs: ["old https://example.com/r", "QA-2", "new https://example.com/r/"]', s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY2
out="$("$HQ" ref remove T-001 "new https://example.com/r/")"
[ "$out" = '{"removed": [{"i": 0, "ref": "old https://example.com/r"}, {"i": 2, "ref": "new https://example.com/r/"}]}' ] && [ "$(refs)" = '["QA-2"]' ] && ok "ref remove prints every entry it removed as JSON" || fail "remove output: $out / $(refs)"
"$HQ" ref restore T-001 "$out" && [ "$(refs)" = '["old https://example.com/r", "QA-2", "new https://example.com/r/"]' ] && ok "ref restore puts them all back in their places" || fail "restore: $(refs)"
"$HQ" ref restore T-001 "$out" && [ "$(refs)" = '["old https://example.com/r", "QA-2", "new https://example.com/r/"]' ] && ok "restoring again changes nothing" || fail "second restore: $(refs)"
"$HQ" ref restore T-001 "not json" 2>/dev/null && fail "restore took junk" || ok "restore refuses anything but remove's JSON"
"$HQ" ref remove T-001 "https://example.com/r" >/dev/null && [ "$(refs)" = '["QA-2"]' ] || fail "cleanup: $(refs)"
# projects: auto-assign by directory, rename / guarded remove like categories
mkdir -p "$T/proj-x/sub"
"$HQ" project add projx --path "$T/proj-x" >/dev/null && "$HQ" project list | grep -q "^projx" && ok "project add"
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

# PROJECT.md: a project is a goal or a duty, with a brief every session on its tasks is given.
PF="$T/root/projects/goalp/PROJECT.md"
"$HQ" project add goalp --kind goal --title "Ship v2" --due 2026-12-19 >/dev/null && [ -f "$PF" ] \
  && grep -q '^kind: goal' "$PF" && grep -q '^title: "Ship v2"' "$PF" && grep -q '^name: goalp' "$PF" && ok "project add writes PROJECT.md" || fail "project add PROJECT.md"
rc=0; "$HQ" project set goalp status=bogus 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "project set checks status" || fail "project set status"
rc=0; "$HQ" project set goalp due=12/19 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "project set checks the date" || fail "project set due"
rc=0; "$HQ" project add a/b 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a project name can't hold a /" || fail "project name with /"
"$HQ" project set goalp jira=QA-1,QA-2 >/dev/null && grep -q '^jira: \["QA-1", "QA-2"\]' "$PF" && ok "project set jira=a,b writes a list" || fail "project set jira"
python3 - "$PF" <<'PYX'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("<goal: what it achieves · duty: what it covers, and what it doesn't>", "Release HQ v2 to the team.")
s = s.replace("## Brief\n", "## Brief\nUse the worktree per task. Never install from a branch.\n")
open(p, "w").write(s)
PYX
"$HQ" project show goalp --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["defined"] and p["kind"]=="goal" and p["due"]=="2026-12-19" and p["goal"]=="Release HQ v2 to the team." and p["brief"].startswith("Use the worktree") and p["done_when"]=="", p' && ok "project show reads kind, goal and brief (template hints dropped)" || fail "project show"
"$HQ" project list | grep -q '^goalp .*\[goal · active · due 2026-12-19\]' && ok "project list shows kind, status, due" || fail "project list kind"
"$HQ" project list | grep -q '^repo-g .*\[no PROJECT.md\]' && ok "a project without PROJECT.md still lists" || fail "legacy project list"
GP="$("$HQ" new "Goal task" --project goalp --no-focus | head -1)"
"$HQ" bind "$GP" --session sess-p >/dev/null
ctx="$(hook '{"session_id":"sess-p","hook_event_name":"SessionStart","source":"startup"}')"
echo "$ctx" | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "belongs to project goalp: Ship v2 (a goal, due 2026-12-19)" in c and "Project goal: Release HQ v2 to the team." in c and "Never install from a branch." in c, c' && ok "SessionStart gives the project and its brief" || fail "SessionStart brief"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "Never install" && fail "brief repeated on a prompt" || ok "an unchanged brief is not repeated"
sed -i.bak 's/Never install from a branch./Install from main only./' "$PF" && rm -f "$PF.bak"
c1="$(hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c1" | grep -q "new or changed since you last saw it" && echo "$c1" | grep -q "Install from main only." && ok "a changed brief is given on the next prompt" || fail "changed brief"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "Install from main" && fail "changed brief given twice" || ok "a changed brief is given once"
(CLAUDE_CODE_SESSION_ID=sess-pin "$HQ" bind "$GP" | grep -q "Install from main only.") && ok "bind from inside prints the brief" || fail "bind brief"
"$HQ" unbind --session sess-pin >/dev/null
"$HQ" project brief goalp | grep -q "^Project brief — applies to every task in goalp" && ok "project brief prints what sessions get" || fail "project brief"
python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('Install from main only.', 'x'*2500))" "$PF"
"$HQ" project brief goalp | python3 -c 'import sys; t=sys.stdin.read(); assert "x"*1900 in t and "x"*2000 not in t and "cut short" in t, len(t)' && ok "a long brief is cut at 2000 characters" || fail "brief cut"
python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('x'*2500, 'Install from main only.'))" "$PF"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null
# project grants: same section and format as a card's, for every task in the project
"$HQ" grant add --project goalp "rerun the smoke test" >/dev/null && grep -q '^- rerun the smoke test <!--g:' "$PF" && ok "grant add --project writes PROJECT.md" || fail "project grant add"
(CLAUDE_CODE_SESSION_ID=x "$HQ" grant add --project goalp "anything" 2>/dev/null) && fail "a session added a project grant" || ok "project grants come from the user only"
"$HQ" grant list --project goalp | grep -q "1. rerun the smoke test" && ok "grant list --project" || fail "project grant list"
c2="$(hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c2" | grep -q "+ granted — a permission from now on, not a request to act now: rerun the smoke test" && ok "a new project grant reaches the session" || fail "project grant change"
hook '{"session_id":"sess-p","hook_event_name":"SessionStart","source":"compact"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "From project goalp (they hold for every task in it):\n- rerun the smoke test" in c, c' && ok "SessionStart lists project grants under the project" || fail "SessionStart project grants"
"$HQ" grant revoke --project goalp 1 >/dev/null && ! grep -q "rerun the smoke test <!--" "$PF" && ok "grant revoke --project" || fail "project grant revoke"
# hq-update `project:` moves a task to an existing project, never makes one
MSG='ok\n\n```hq-update\nproject: nosuch\n```'
hook "{\"session_id\":\"sess-p\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" | grep -q "is not a project" && ok "hq-update project: refuses a project that doesn't exist" || fail "hq-update unknown project"
grep -q '^project: goalp' "$T"/root/tasks/$GP-*/TASK.md || fail "refused block changed the project"
MSG='ok\n\n```hq-update\nproject: repo-g\n```'
hook "{\"session_id\":\"sess-p\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
grep -q '^project: repo-g' "$T"/root/tasks/$GP-*/TASK.md && grep -q "project 'goalp' → 'repo-g'" "$T"/root/tasks/$GP-*/TASK.md && ok "hq-update project: moves the task and logs it" || fail "hq-update project"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "no longer has a project brief" && ok "moving to a project without a brief says the old one is gone" || fail "brief gone"
"$HQ" set "$GP" project=goalp >/dev/null
# board --json: project fields and counts, and each task's repo (a worktree counts as its repo)
mkdir -p "$T/repo-main/.git/worktrees/wt" "$T/repo-main-wt/sub"
echo "gitdir: $T/repo-main/.git/worktrees/wt" > "$T/repo-main-wt/.git"
RP="$("$HQ" new "In a worktree" --workdir "$T/repo-main-wt/sub" --no-focus | head -1)"
RG="$("$HQ" new "In a removed worktree" --workdir "$T/repo-main-gone" --no-focus | head -1)"
"$HQ" board --json | python3 -c '
import json,sys; d=json.load(sys.stdin)
p=[x for x in d["projects"] if x["name"]=="goalp"][0]
assert p["defined"] and p["kind"]=="goal" and p["title"]=="Ship v2" and p["stats"]["open"]==1, p
assert [x for x in d["projects"] if x["name"]=="repo-g"][0]["defined"] is False
r={t["id"]: t["repo"] for t in d["tasks"]}
assert r["'"$RP"'"]=="repo-main" and r["'"$RG"'"]=="repo-main", r' && ok "board --json: project fields, counts and each task's repo" || fail "board json projects"
# rename moves the folder; remove puts it aside, never deletes it
"$HQ" project rename goalp goalq >/dev/null && [ -f "$T/root/projects/goalq/PROJECT.md" ] && [ ! -e "$T/root/projects/goalp" ] \
  && grep -q '^name: goalq' "$T/root/projects/goalq/PROJECT.md" && ok "project rename moves PROJECT.md" || fail "project rename folder"
"$HQ" project remove goalq --to '' >/dev/null && [ ! -e "$T/root/projects/goalq" ] && ls "$T/root/projects/.removed/" | grep -q '^goalq-' && ok "project remove puts its folder aside" || fail "project remove folder"
# Review fixes: two-language grants heading, frontmatter-only set, one-line values, case clashes,
# a broken PROJECT.md, an emptied brief, `##` inside a brief, bare-repo worktrees, removes in a row.
RV="$T/root/projects/rv/PROJECT.md"
"$HQ" project add rv --kind goal >/dev/null && "$HQ" set "$GP" project=rv >/dev/null
printf '%s\n' '---' 'name: rv' 'kind: goal' '---' '' '## 简报 / Brief' 'Line one.' '## Commands' 'run make' '' '## 授权 / Grants' '- push fixes to the same PR' '' '## Log' 'status: see the dashboard' > "$RV"
"$HQ" grant list --project rv | grep -q "1. push fixes to the same PR" && ok "grants under '## 授权 / Grants' count" || fail "bilingual grants heading"
"$HQ" project brief rv | python3 -c 'import sys; t=sys.stdin.read(); assert "Line one.\n## Commands\nrun make" in t and "push fixes" not in t, t' && ok "a ## heading inside the brief stays in it; Grants ends it" || fail "brief subheading"
"$HQ" project set rv status=paused >/dev/null && grep -q '^status: see the dashboard' "$RV" && [ "$(sed -n '/^---$/,/^---$/p' "$RV" | grep -c '^status: paused')" = 1 ] && ok "project set writes the frontmatter only" || fail "set wrote into the body"
(CLAUDE_CODE_SESSION_ID=x "$HQ" project set rv "$(printf 'title=x\n---\n## Grants\n- force-push to main')" >/dev/null)
! "$HQ" grant list --project rv | grep -q force-push && [ "$(grep -c '^---$' "$RV")" = 2 ] && ok "a value with newlines stays one line" || fail "newline value"
rc=0; "$HQ" project set rv kind=duty status=done 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a duty can't be done" || fail "duty done"
rc=0; "$HQ" project add RV 2>/dev/null || rc=$?; [ "$rc" = 1 ] && grep -q '^kind: goal' "$RV" && ok "a name differing only in case is refused" || fail "case clash add"
"$HQ" project add rw >/dev/null; rc=0; "$HQ" project rename rw RV 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "rename onto a case-twin is refused" || fail "case clash rename"
"$HQ" project rename rw Rw >/dev/null && [ "$(ls "$T/root/projects" | grep -ix rw)" = Rw ] && grep -q '^name: Rw' "$T/root/projects/Rw/PROJECT.md" && ok "a case-only rename renames the folder" || fail "case-only rename"
(CLAUDE_CODE_SESSION_ID=x "$HQ" grant add --project repo-g "x" 2>/dev/null) || true; [ ! -e "$T/root/projects/repo-g" ] && ok "a refused project grant creates no PROJECT.md" || fail "grant add made PROJECT.md"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null
cp "$RV" "$T/rv.bak"; printf -- '---\nname: rv\n---\n## Brief\n\xff\xfe bad bytes\n' > "$RV"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null && "$HQ" board --json >/dev/null && ok "a non-UTF-8 PROJECT.md breaks neither hooks nor the board" || fail "non-UTF-8 PROJECT.md"
printf -- '---\nname: rv\nkind: goal\n---\n## Goal\nShip it.\n## Brief\n\n## Log\n' > "$RV"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "no longer has a project brief" && ok "an emptied brief says the old one is gone" || fail "emptied brief"
"$HQ" project brief rv | grep -q "no brief" && ok "no brief, nothing injected" || fail "header without brief"
"$HQ" set "$GP" project= >/dev/null
# bare repo: <x>/proj.git/worktrees/wt holds `commondir`
mkdir -p "$T/proj.git/worktrees/wt" "$T/proj-T1"; echo "../.." > "$T/proj.git/worktrees/wt/commondir"
echo "gitdir: $T/proj.git/worktrees/wt" > "$T/proj-T1/.git"
BR="$("$HQ" new "Bare worktree" --workdir "$T/proj-T1" --no-focus | head -1)"
"$HQ" board --json | python3 -c 'import json,sys; r={t["id"]: t["repo"] for t in json.load(sys.stdin)["tasks"]}; assert r["'"$BR"'"]=="proj", r' && ok "a bare repo's worktree counts as the repo" || fail "bare worktree repo"
"$HQ" project add q1 >/dev/null; "$HQ" project remove q1 >/dev/null; "$HQ" project add q1 >/dev/null
"$HQ" project remove q1 >/dev/null && [ "$(ls "$T/root/projects/.removed" | grep -c '^q1-')" = 2 ] && ok "removing twice in a second keeps both folders" || fail "double remove"
"$HQ" project add dp >/dev/null; DT="$("$HQ" new "Old done" --project dp --no-focus | head -1)"
"$HQ" set "$DT" status=done >/dev/null && grep -q "^closed: $(date +%F)" "$T"/root/tasks/$DT-*/TASK.md && ok "closing a task records when" || fail "closed date"
sed -i.bak "s/^closed: .*/closed: 2000-01-01/" "$T"/root/tasks/$DT-*/TASK.md && "$HQ" log "$DT" "late note" >/dev/null
"$HQ" project show dp --json | python3 -c 'import json,sys; s=json.load(sys.stdin)["stats"]; assert s["done"]==1 and s["done_7d"]==0, s' && ok "done in 7 days goes by when it closed, not the last edit" || fail "done_7d"
grep -q "@me ping Wenbing <!--t:" "$T"/root/tasks/T-001-*/TASK.md && ok "addtodo stamps a hidden creation time"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; o=[x for x in t["todos"] if x["state"]=="open"]; assert all(x["created"] for x in o) and not any("<!--" in x["text"] for x in t["todos"]), o' && ok "every open todo has a created time; the stamp is hidden"
# Focus: new tasks join it, and it stays until you take a task off — no daily reset.
"$HQ" focus --json | python3 -c 'import json,sys; f=json.load(sys.stdin); assert "T-001" in f["ids"] and "T-002" in f["ids"], f' && ok "new tasks join Focus"
"$HQ" focus remove T-002 && "$HQ" focus --json | python3 -c 'import json,sys; assert "T-002" not in json.load(sys.stdin)["ids"]' && ok "focus remove"
# An old per-day focus.json reads as its latest day's list, and the next change writes the new form.
python3 - "$T/root/focus.json" <<'PY'
import json, sys
json.dump({"days": {"2000-01-01": ["T-002"], "2000-01-02": ["T-001", "T-002"]}}, open(sys.argv[1], "w"))
PY
"$HQ" focus --json | python3 -c 'import json,sys; f=json.load(sys.stdin); assert f["ids"]==["T-001","T-002"] and not f["carry"], f' && ok "an old per-day focus file carries its latest list into Focus"
python3 - "$T/root/focus.json" <<'PY'
import json, sys
json.dump({"days": {"2000-01-01": ["T-002", "T-001"], "2000-01-02": ["T-001"], "2000-01-03": [], "x": None}}, open(sys.argv[1], "w"))
PY
"$HQ" focus --json | python3 -c 'import json,sys; f=json.load(sys.stdin); assert f["ids"]==["T-001","T-002"], f' && ok "migration keeps the day before's picks too, and skips malformed days" || fail "old focus migration lost picks or crashed"
"$HQ" set T-002 status=done >/dev/null; "$HQ" focus --json | python3 -c 'import json,sys; assert "T-002" not in json.load(sys.stdin)["ids"]' && ok "a finished task leaves Focus" || fail "a done task stayed in Focus"
"$HQ" set T-002 status=active >/dev/null; "$HQ" focus --json | python3 -c 'import json,sys; assert "T-002" in json.load(sys.stdin)["ids"]' && ok "reopened, it is back in Focus" || fail "a reopened task did not come back to Focus"
"$HQ" focus add T-001 >/dev/null; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"focus":["T-001","T-002"]}, d' "$T/root/focus.json" && ok "Focus is saved as one list, not per day"
"$HQ" board --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["focus"]["ids"]==["T-001","T-002"]' && ok "board --json includes Focus"
"$HQ" set T-001 status=waiting-on-me "next=pick a dataset"
"$HQ" board | grep -q "你: ping Wenbing" && ok "set + board shows your next todo"
"$HQ" set T-002 "waiting_on_me=legacy text" && "$HQ" board | grep -q "legacy text" && ok "a leftover waiting_on_me still shows as yours"
"$HQ" set T-002 "waiting_on_me=" >/dev/null

# code review fixes (PR #37)
a1="$("$HQ" ask add T-002 "Ship it now?")"; a2="$("$HQ" ask add T-002 "ship it   NOW?")"
[ "$a1" = "$a2" ] && [ "$("$HQ" asks T-002 | grep -c 'hip it')" = 1 ] && ok "a question still open is not recorded twice"
TS="$("$HQ" new "todo shift" --no-focus | head -1)"
"$HQ" addtodo "$TS" "@me first thing" && "$HQ" addtodo "$TS" "@me second thing"
python3 - "$T"/root/tasks/"$TS"-*/TASK.md <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("- [ ] @me first thing", "- [ ] @claude slipped in by a session\n- [ ] @me first thing", 1); open(p, "w").write(s)
PY
"$HQ" todo "$TS" 1 done --via board --text "first thing" >/dev/null
grep -q -- "- \[x\] @me first thing" "$T"/root/tasks/"$TS"-*/TASK.md && grep -q -- "- \[ \] @claude slipped in" "$T"/root/tasks/"$TS"-*/TASK.md && ok "todo follows its text when positions shifted"
rc=0; "$HQ" todo "$TS" 2 done --text "no such todo" 2>/dev/null || rc=$?
[ "$rc" != 0 ] && ok "todo refuses when its text is gone"
TT="$("$HQ" new "tilde dir" --no-focus --workdir "~/somewhere" | head -1)"
grep -q "$HOME/somewhere" "$T"/root/tasks/"$TT"-*/TASK.md && ! grep -q '/~/' "$T"/root/tasks/"$TT"-*/TASK.md && ok "workdir with ~ is expanded"
"$HQ" focus --json | python3 -c 'import json,sys; f=json.load(sys.stdin); assert "'"$TS"'" not in f["ids"]' && ok "new --no-focus stays out of Focus"
for i in 1 2 3 4 5 6 7 8 9 10; do "$HQ" bind T-001 --session "par-$i" >/dev/null & done; wait
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert all(f"par-{i}" in s for i in range(1,11)) and "sess-1" in s, sorted(s)' "$HOME/.claude/hq/state/sessions.json" && ok "parallel binds all survive"
for i in 1 2 3 4 5 6 7 8 9 10; do "$HQ" unbind --session "par-$i" >/dev/null; done
BAD="$T/odd: name, #with [chars] and a folder name well over forty characters"
mkdir -p "$BAD/.git" "$HOME/.claude/projects/-x-odd"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$BAD\",\"message\":{\"content\":\"hi\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}" > "$HOME/.claude/projects/-x-odd/abcdef99-0000.jsonl"
"$HQ" scan --apply-projects >/dev/null && "$HQ" project list --json | python3 -c 'import json,sys,re; n=[p["name"] for p in json.load(sys.stdin)]; assert any(x.startswith("odd- name- -with -chars-") or x.startswith("odd") for x in n), n; assert all(len(x)<=40 and not re.search(r"[:,#\[\]]", x) for x in n), n' && ok "scan makes odd folder names into valid project names"

# write-back guard: a long turn that never touched the card is nudged once
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["sess-1"]["turn_start"] = time.time() - 600; json.dump(s, open(p, "w"))
PY
touch -t 200001010000 "$T"/root/tasks/T-001-*/TASK.md
hook '{"session_id":"sess-1","hook_event_name":"Stop","last_assistant_message":"x"}' | grep -q '"decision": "block"' && ok "write-back guard blocks stale card"
hook '{"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"x"}' | grep -q block && fail "guard looped" || ok "guard does not loop"

# hq-update: card bookkeeping written in the reply, applied by the Stop hook (no tool calls)
stop() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"Stop","last_assistant_message":sys.argv[2]}))' "$1" "$2" | "$HQ" hook; }
C1="$(ls "$T"/root/tasks/T-001-*/TASK.md)"
hook '{"session_id":"sess-1","hook_event_name":"SessionStart"}' | grep -q 'hq-update' && ok "protocol teaches the hq-update block"
out="$(stop sess-1 "$(printf 'Fixed it.\n\n```hq-update\nstatus: blocked\nnext: wait for the token\nstate: build is green\nstate: waiting on infra for the token\ntodo: @me send the token request\ntodo: @claude rerun the suite\nlog: picked plan v2 because it is cheaper\nref: PR #9 https://example.com/pr/9\nworkdir: %s\n```' "$T/repo-a")")"
[ -z "$out" ] && ok "a clean hq-update block does not block the turn" || fail "clean block blocked: $out"
python3 - "$C1" "$T/repo-a" <<'PY' && ok "hq-update sets status/next/state/todos/log/ref/workdir"
import sys, re
t = open(sys.argv[1]).read()
assert "status: blocked" in t and 'next: "wait for the token"' in t, t
assert re.search(r"## Status\nbuild is green\nwaiting on infra for the token\n\n## ", t), t
assert "- [ ] @me send the token request" in t and "- [ ] @claude rerun the suite" in t, t
assert ": picked plan v2 because it is cheaper" in t and "PR #9 https://example.com/pr/9" in t, t
assert sys.argv[2] in t, t
PY
stop sess-1 "$(printf 'ok\n```hq-update\ndone: rerun the suite\ndrop: @me send the token request\n```')" >/dev/null
grep -q -- "- \[x\] @claude rerun the suite" "$C1" && grep -q -- "- \[-\] @me send the token request" "$C1" && ok "done/drop find the todo by its text"
stop sess-1 "$(printf 'ok\n```hq-update\nref: PR #9 (merged) https://example.com/pr/9\n```')" >/dev/null
grep -q "PR #9 (merged) https://example.com/pr/9" "$C1" && [ "$(grep -o "example.com/pr/9" "$C1" | wc -l | tr -d ' ')" = 1 ] && ok "hq-update ref with a known URL renames it instead of adding a duplicate" || fail "ref duplicated: $(grep refs "$C1")"
out="$(stop sess-1 "$(printf 'ok\n```hq-update\nstatus: finished\ndone: no such todo\nwhatever this is\n```')")"
echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin)["reason"]; assert "status must be one of" in r and "no such todo" in r and "whatever this is" in r, r' && ok "lines it cannot apply are sent back once"
python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"```hq-update\nstatus: nope\n```"}))' | "$HQ" hook | grep -q block && fail "bad block looped" || ok "a bad block is not sent back twice"
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["sess-1"]["turn_start"] = time.time() - 600; json.dump(s, open(p, "w"))
PY
touch -t 200001010000 "$C1"
[ -z "$(stop sess-1 "$(printf 'nothing new\n```hq-update\ntouch\n```')")" ] && ok "a touch-only block satisfies the write-back guard"

# hq-update review fixes (PR #51): what is a block, all-or-nothing, matching, leniency, locking
cardof() { cat "$C1"; }
before="$(cardof)"
stop sess-1 "$(printf 'The protocol says to write:\n\n```hq-update\nstatus: active | waiting-on-me | blocked | done | abandoned\nnext: <the next concrete action>\nstate: <where it stands>\ntodo: @owner <text>\nlog: <a decision and why>\nref: <short title> <full URL>\n```\n\nand then carry on.')" >/dev/null
[ "$(cardof)" = "$before" ] && ok "a block shown mid-reply is an example, not an update" || fail "mid-reply example was applied"
stop sess-1 "$(printf 'ok\n\n```hq-update\nnext: <the next concrete action>\ntodo: @owner <text>\nref: <short title> <full URL>\n```')" >/dev/null
[ "$(cardof)" = "$before" ] && ok "a trailing block of template placeholders is ignored" || fail "placeholder block applied"
stop sess-1 "$(printf 'Docs:\n\n````markdown\n```hq-update\ntodo: @me quoted example todo\n```\n````')" >/dev/null
grep -q "quoted example todo" "$C1" && fail "block inside a 4-backtick fence applied" || ok "a block quoted inside a longer fence is not applied"
out="$(stop sess-1 "$(printf 'Mentioning ```hq-update``` inline is fine.\n\nHere is the diff:\n```\nx\n```')")"
[ -z "$out" ] && ok "an inline mention does not swallow the rest of the reply" || fail "inline mention: $out"
stop sess-1 "$(printf 'ok\n```hq-update\nlog: switched to ```bash``` wrapper\ntodo: @claude after the backticks\n```')" >/dev/null
grep -q "switched to \`\`\`bash\`\`\` wrapper" "$C1" && grep -q "@claude after the backticks" "$C1" && ok "a value holding \`\`\` does not cut the block short" || fail "a value holding \`\`\` does not cut the block short"
grep -c "after the backticks" "$C1" | grep -qx 1 || fail "block applied more than once"
BAD='ok\n```hq-update\nstatus: finished\ntodo: @me only once\nlog: only once too\n```'
stop sess-1 "$(printf "$BAD")" | grep -q "NOT applied" && ! grep -q "only once" "$C1" && ok "a block with a bad line writes nothing" || fail "a block with a bad line writes nothing"
stop sess-1 "$(printf 'ok\n```hq-update\nstatus: blocked\ntodo: @me only once\nlog: only once too\n```')" >/dev/null
stop sess-1 "$(printf 'ok\n```hq-update\nstatus: blocked\ntodo: @me only once\nlog: only once too\n```')" >/dev/null
[ "$(grep -c "@me only once" "$C1")" = 1 ] && [ "$(grep -c ": only once too$" "$C1")" = 1 ] && ok "the same block twice adds its todo and log once" || fail "the same block twice adds its todo and log once"
stop sess-1 "$(printf 'ok\n```hq-update\ntodo: @claude rerun lint\ntodo: @claude rerun lint on CI\n```')" >/dev/null
stop sess-1 "$(printf 'ok\n```hq-update\ndone: rerun lint\n```')" >/dev/null
stop sess-1 "$(printf 'ok\n```hq-update\ndone: rerun lint\n```')" >/dev/null
grep -q -- "- \[x\] @claude rerun lint <" "$C1" && grep -q -- "- \[ \] @claude rerun lint on CI" "$C1" && ok "done on an already-done todo is a no-op, not a substring hit elsewhere" || fail "done on an already-done todo is a no-op, not a substring hit elsewhere"
stop sess-1 "$(printf 'ok\n```hq-update\ntodo: @claude deploy to staging\ntodo: @claude deploy to prod\n```')" >/dev/null
out="$(stop sess-1 "$(printf 'ok\n```hq-update\ndone: deploy\n```')")"
echo "$out" | grep -q "deploy to staging" && echo "$out" | grep -q "deploy to prod" && ok "an ambiguous done lists the candidates" || fail "an ambiguous done lists the candidates"
stop sess-1 "$(printf 'ok\n```hq-update\nStatus：\"Active\"\nnext: \"wait for the token\"\nlog：选了方案 v2\n```')" >/dev/null
grep -q "^status: active" "$C1" && grep -q '^next: "wait for the token"' "$C1" && grep -q ": 选了方案 v2$" "$C1" && ok "full-width colon, key case and quoted values are accepted" || fail "full-width colon, key case and quoted values are accepted"
stop sess-1 "$(printf 'ok\n```hq-update\nstate: - [ ] CI green\n```')" >/dev/null
grep -q "^CI green$" "$C1" && ok "a checkbox in state: does not become a todo" || fail "a checkbox in state: does not become a todo"
WD="$T/repo-a"
stop sess-1 "$(printf 'ok\n```hq-update\nworkdir: %s/\nworkdir: %s\n```' "$WD" "$WD")" >/dev/null
python3 - "$C1" "$WD" <<'PY' && ok "workdir is normalised and not repeated" || fail "workdir is normalised and not repeated"
import sys, re, json
t = open(sys.argv[1]).read(); w = json.loads(re.search(r"^workdirs: (.*)$", t, re.M).group(1))
assert w.count(sys.argv[2]) == 1 and sys.argv[2] + "/" not in w, w
PY
stop sess-1 "$(printf 'ok\n```hq-update\nworkdir: %s\n```' "$HOME")" | grep -q "never a workdir" && ok "home is refused as a workdir, as bind refuses it" || fail "home is refused as a workdir, as bind refuses it"
python3 -c 'import json; print(json.dumps({"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"ok\n```hq-update\nstatus: nope\n```"}))' | "$HQ" hook >/dev/null
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "status must be one of" && ok "a block refused while another Stop hook held the turn is reported next prompt" || fail "a block refused while another Stop hook held the turn is reported next prompt"
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "status must be one of" && fail "refusal reported twice" || ok "and only once"
for i in 0 1 2 3 4 5; do
  stop sess-1 "$(printf 'ok\n```hq-update\ntodo: @claude parallel %s\nlog: parallel log %s\n```' $i $i)" >/dev/null &
done; wait
[ "$(grep -c "@claude parallel " "$C1")" = 6 ] && [ "$(grep -c ": parallel log " "$C1")" = 6 ] && ok "parallel Stop hooks on one card lose nothing" || fail "parallel Stop hooks on one card lose nothing"

# Two sessions on one task: an answer goes to the session that asked it, and only to it.
"$HQ" new "Shared work" >/dev/null
SID="$(basename "$(ls -d "$T"/root/tasks/T-*-shared-work)" | cut -d- -f1-2)"
"$HQ" bind "$SID" --session sess-a >/dev/null; "$HQ" bind "$SID" --session sess-b >/dev/null
MSG2='ok.\n\n```hq-asks\n- Run the review?\n- Draft the note?\n```'
hook "{\"session_id\":\"sess-a\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG2\"}" >/dev/null
ctxof() { hook "{\"session_id\":\"$1\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}" | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else "")'; }
ctxof sess-b | grep -q "$SID.1 (asked by another session on this task)" && ok "open asks say which ones another session on the task raised"
"$HQ" ask resolve "$SID.1" do --via board >/dev/null
ctxof sess-b | grep -q "$SID.1 \"" && fail "another session on the task got the answer" || ok "an answer is not given to another session on the same task"
ctxof sess-a | grep -q "^- $SID.1 \"Run the review?\" → yes" && ok "the session that asked gets its answer"
"$HQ" ask resolve "$SID.2" drop --via board >/dev/null
"$HQ" unbind --session sess-a >/dev/null
ctxof sess-b | grep -q "^- $SID.2 \"Draft the note?\" → no" && ok "once the asker has left the task, the next session on it takes the answer"
ctxof sess-b | grep -q "^- $SID.1 " && fail "an answer the asker already had went out again after it was unbound" || ok "an answer already given to the asker is not given again once it leaves"
# The asker ended: with the pet installed it drops a dead session's record, and the answer must
# not wait for that session forever.
"$HQ" bind "$SID" --session sess-c >/dev/null
hook "{\"session_id\":\"sess-c\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"ok.\\n\\n\`\`\`hq-asks\\n- Ship it?\\n\`\`\`\"}" >/dev/null
"$HQ" ask resolve "$SID.3" do --via board >/dev/null
mkdir -p "$HOME/.claude/pet/sessions"
echo "{\"pid\": $$}" > "$HOME/.claude/pet/sessions/sess-c.json"
ctxof sess-b | grep -q "^- $SID.3 " && fail "a live asker's answer went to another session" || ok "a live asker keeps its answer"
rm "$HOME/.claude/pet/sessions/sess-c.json"
ctxof sess-b | grep -q "^- $SID.3 \"Ship it?\" → yes" && ok "once the asker has ended, the next session on the task takes the answer"
rm -rf "$HOME/.claude/pet"

# history: the sessions that worked on a task, with what resuming one needs.
HSID=0a1b2c3d-1111-2222-3333-444455556666
mkdir -p "$HOME/.claude/projects/-tmp-repo"
printf '%s\n' '{"type":"custom-title","customTitle":"perf run"}' '{"type":"assistant","cwd":"/tmp/repo","message":{"content":[{"type":"text","text":"All done."}]}}' > "$HOME/.claude/projects/-tmp-repo/$HSID.jsonl"
"$HQ" bind "$SID" --session "$HSID" >/dev/null
"$HQ" history "$SID" --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["sessionId"]=="'"$HSID"'"][0]; assert r["cwd"]=="/tmp/repo" and r["title"]=="perf run" and r["lastText"]=="All done." and r["live"] is False, r' && ok "history lists a task's sessions with id, directory, name and last words"

# peek: a prompt typed while Claude was busy is stored as a queued_command attachment, not a user
# entry; it is still the user's message. Queued task notifications and peer messages are not.
PSID=feedface-1111-2222-3333-444455556666
printf '%s\n' \
  '{"type":"user","message":{"content":"first ask"},"timestamp":"2026-01-01T00:00:00Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]},"timestamp":"2026-01-01T00:00:01Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"typed while busy","commandMode":"prompt","origin":{"kind":"human"}},"timestamp":"2026-01-01T00:00:02Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>x</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}},"timestamp":"2026-01-01T00:00:03Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"from a peer","commandMode":"prompt","origin":{"kind":"peer"}},"timestamp":"2026-01-01T00:00:04Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2026-01-01T00:00:05Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$PSID.jsonl"
"$HQ" peek "$PSID" --json | python3 -c 'import json,sys; m=json.load(sys.stdin); assert [(x["role"],x["text"]) for x in m]==[("user","first ask"),("assistant","working"),("user","typed while busy"),("assistant","done")], m; assert m[2]["ts"]=="2026-01-01T00:00:02Z", m' && ok "peek shows prompts typed while the session was busy" || fail "peek missed a prompt queued in the terminal"

# The same prompt now and then lands twice: as the user entry that starts a turn, and a moment later
# as a queued_command folded into it. Peek shows it once; the same words typed a minute later are a
# new message. A queued prompt with an image keeps its text.
DSID=feedface-2222-2222-3333-444455556666
printf '%s\n' \
  '{"type":"user","message":{"content":"open the PR"},"timestamp":"2026-01-01T00:00:00.000Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"open the PR","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-01-01T00:00:00.400Z"},"timestamp":"2026-01-01T00:00:00.400Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"opening"}]},"timestamp":"2026-01-01T00:00:01Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"open the PR","commandMode":"prompt","origin":{"kind":"human"}},"timestamp":"2026-01-01T00:01:00Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"see [Image #1]"},{"type":"image","source":{"type":"base64","data":"AAAA"}}],"commandMode":"prompt","origin":{"kind":"human"}},"timestamp":"2026-01-01T00:01:05Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$DSID.jsonl"
"$HQ" peek "$DSID" --json | python3 -c 'import json,sys; m=json.load(sys.stdin); assert [(x["role"],x["text"]) for x in m]==[("user","open the PR"),("assistant","opening"),("user","open the PR"),("user","see [Image #1]")], m' && ok "peek shows a prompt written twice once, and keeps a queued prompt with an image" || fail "peek doubled a prompt or lost a queued image prompt"

# peek: screenshots make a transcript big without adding messages. The n messages are found
# however many megabytes of images sit between them.
ISID=feedface-5555-2222-3333-444455556666
IMG=$(python3 -c 'print("A" * 4_000_000)')
{ for i in 1 2 3; do
    printf '{"type":"user","message":{"content":"ask %s"},"timestamp":"2026-01-01T00:0%s:00Z"}\n' "$i" "$i"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r%s","content":[{"type":"image","source":{"type":"base64","data":"%s"}}]}]},"timestamp":"2026-01-01T00:0%s:01Z"}\n' "$i" "$IMG" "$i"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"answer %s"}]},"timestamp":"2026-01-01T00:0%s:02Z"}\n' "$i" "$i"
  done; } > "$HOME/.claude/projects/-tmp-repo/$ISID.jsonl"
"$HQ" peek "$ISID" -n 6 --json | python3 -c 'import json,sys; m=json.load(sys.stdin); assert [x["text"] for x in m]==["ask 1","answer 1","ask 2","answer 2","ask 3","answer 3"], m' && ok "peek reads past megabytes of screenshots to find its n messages" || fail "peek stopped short behind screenshots"

# peek --meta: tool calls between the messages, paired with their results; Claude's todo list;
# the turn in progress. Request records repeating a call must not hide its diff in --tool.
ASID=feedface-3333-2222-3333-444455556666
printf '%s\n' \
  '{"type":"system","subtype":"turn_duration","durationMs":5000,"timestamp":"2026-01-01T00:00:00Z"}' \
  '{"type":"user","message":{"content":"fix the board"},"timestamp":"2026-01-01T00:01:00Z"}' \
  '{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":100,"input_tokens":5,"cache_read_input_tokens":1000},"content":[{"type":"tool_use","id":"tA","name":"Bash","input":{"command":"cd /tmp/repo && make test","description":"Run tests"}}]},"timestamp":"2026-01-01T00:01:01Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tA","content":"2 failed","is_error":true}]},"toolUseResult":"Error: 2 failed","timestamp":"2026-01-01T00:01:05Z"}' \
  '{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":50,"input_tokens":5,"cache_read_input_tokens":2000},"content":[{"type":"tool_use","id":"tB","name":"Edit","input":{"file_path":"/tmp/repo/board.js","old_string":"a","new_string":"b"}}]},"timestamp":"2026-01-01T00:01:06Z"}' \
  '{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":50,"input_tokens":5,"cache_read_input_tokens":2000},"content":[{"type":"tool_use","id":"tT","name":"TodoWrite","input":{"todos":[{"content":"Fix tests","status":"completed","activeForm":"Fixing tests"},{"content":"Ship","status":"in_progress","activeForm":"Shipping"}]}}]},"timestamp":"2026-01-01T00:01:06Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tB","content":"updated"}]},"toolUseResult":{"structuredPatch":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":3,"lines":[" x","-a","+b","+c"]}]},"timestamp":"2026-01-01T00:01:07Z"}' \
  '{"type":"api-request-blob","message":{"content":[{"type":"tool_result","tool_use_id":"tB","content":"updated"}]}}' \
  '{"type":"assistant","message":{"id":"m3","usage":{"output_tokens":30},"content":[{"type":"text","text":"Edited; agent checking."},{"type":"tool_use","id":"tC","name":"Agent","input":{"description":"Review the fix","prompt":"look"}},{"type":"tool_use","id":"tD","name":"mcp__claude_ai_Atlassian__getJiraIssue","input":{"issueIdOrKey":"QA-1"}},{"type":"tool_use","id":"tE","name":"Bash","input":{"command":"sleep 99"}}]},"timestamp":"2026-01-01T00:01:08Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tC","content":"Async agent launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched"},"timestamp":"2026-01-01T00:01:09Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tD","content":"QA-1: open"}]},"timestamp":"2026-01-01T00:01:09Z"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<tool-use-id>tC</tool-use-id>\n<status>completed</status>\n<result>Looks right.</result>\n</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}},"timestamp":"2026-01-01T00:02:00Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$ASID.jsonl"
"$HQ" peek "$ASID" --json --meta | python3 -c '
import json,sys; d=json.load(sys.stdin); it=d["items"]
row=lambda i: {k: i.get(k) for k in ("kind","title","label","status","stat")}
got=[(i["kind"], i.get("title") or i.get("role"), i.get("label") or i.get("text"), i.get("status"), i.get("stat")) for i in it]
assert got==[("msg","user","fix the board",None,None),
             ("tool","Bash","make test","error",None),
             ("tool","Edit","board.js","ok","+2 −1"),
             ("msg","assistant","Edited; agent checking.",None,None),
             ("tool","Agent","Review the fix","ok",None),
             ("tool","Atlassian · getJiraIssue","QA-1","ok",None),
             ("tool","Bash","sleep 99","pending",None)], got
assert it[4]["bg"]=="completed", it[4]
assert d["todos"]==[{"text":"Fix tests","status":"completed","active":"Fixing tests"},{"text":"Ship","status":"in_progress","active":"Shipping"}], d["todos"]
t=d["turn"]; assert t["start"]=="2026-01-01T00:01:00Z" and not t["done"] and t["tokens"]==180 and t["context"]==2005, t
assert [m["text"] for m in d["messages"]]==["fix the board","Edited; agent checking."], d["messages"]
' && ok "peek --meta pairs tool calls with results (errors, edits, background agents, MCP), reads Claude's todos and the open turn" || fail "peek --meta tool calls / todos / turn"
"$HQ" peek "$ASID" --tool tB --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["output"].splitlines()==["@@ -1,2 +1,3 @@"," x","-a","+b","+c"] and d["input"]=="/tmp/repo/board.js" and d["done"], d' && ok "peek --tool shows an edit as its diff" || fail "peek --tool edit diff"
"$HQ" peek "$ASID" --tool tC --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["output"].endswith("— completed —\nLooks right.") and d["input"].startswith("Review the fix"), d' && ok "peek --tool shows a background agent's result once it finished" || fail "peek --tool background result"
"$HQ" peek "$ASID" --tool nope --json >/dev/null 2>&1 && fail "peek --tool accepted an unknown id" || ok "peek --tool refuses an unknown id"

# A finished turn (turn_duration logged after it): its length; TaskCreate / TaskUpdate build the
# todo list when Claude uses those instead of TodoWrite.
BSID=feedface-4444-2222-3333-444455556666
printf '%s\n' \
  '{"type":"user","message":{"content":"plan it"},"timestamp":"2026-01-01T00:00:00Z"}' \
  '{"type":"assistant","message":{"id":"n1","usage":{"output_tokens":7},"content":[{"type":"tool_use","id":"c1","name":"TaskCreate","input":{"subject":"Write parser","activeForm":"Writing parser"}},{"type":"tool_use","id":"c2","name":"TaskCreate","input":{"subject":"Render rows"}}]},"timestamp":"2026-01-01T00:00:01Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"Task #1 created successfully: Write parser"}]},"timestamp":"2026-01-01T00:00:02Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c2","content":"Task #2 created successfully: Render rows"}]},"timestamp":"2026-01-01T00:00:02Z"}' \
  '{"type":"assistant","message":{"id":"n2","usage":{"output_tokens":3},"content":[{"type":"tool_use","id":"u1","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}},{"type":"text","text":"On it."}]},"timestamp":"2026-01-01T00:00:03Z"}' \
  '{"type":"system","subtype":"turn_duration","durationMs":4000,"timestamp":"2026-01-01T00:00:04Z"}' \
  '{"type":"custom-title","customTitle":"plan"}' \
  > "$HOME/.claude/projects/-tmp-repo/$BSID.jsonl"
"$HQ" peek "$BSID" --json --meta | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["turn"]["done"] and d["turn"]["ms"]==4000 and d["turn"]["tokens"]==10, d["turn"]
assert [(t["text"],t["status"]) for t in d["todos"]]==[("Write parser","in_progress"),("Render rows","pending")], d["todos"]
assert all(i["kind"]=="msg" for i in d["items"]), d["items"]
' && ok "peek --meta: a finished turn's length, and the todo list TaskCreate / TaskUpdate built" || fail "peek --meta finished turn / Task todos"

# Background calls that end without a tool-use id: TaskStop on a command, an agent's notification
# naming only its agentId, one that was killed; an interrupted turn; odd input and a U+0085 result.
CSID=feedface-5555-2222-3333-444455556666
printf '%s\n' \
  '{"type":"user","message":{"content":"go"},"timestamp":"2026-01-02T00:00:00Z"}' \
  '{"type":"assistant","message":{"id":"p1","usage":{"output_tokens":5},"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"sleep 999","run_in_background":true}},{"type":"tool_use","id":"g1","name":"Agent","input":{"description":"dig","prompt":"dig in"}},{"type":"tool_use","id":"g2","name":"Agent","input":{"description":"killme","prompt":"x"}},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":{"oops":1}}},{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/x/odd.txt"}}]},"timestamp":"2026-01-02T00:00:01Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"started"}]},"toolUseResult":{"backgroundTaskId":"bgx1"},"timestamp":"2026-01-02T00:00:02Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g1","content":"launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agentA"},"timestamp":"2026-01-02T00:00:02Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g2","content":"launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agentB"},"timestamp":"2026-01-02T00:00:02Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"?"}]},"timestamp":"2026-01-02T00:00:02Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":"odd\u0085line"}]},"timestamp":"2026-01-02T00:00:02Z"}' \
  '{"type":"assistant","message":{"id":"p2","usage":{"output_tokens":5},"content":[{"type":"tool_use","id":"s1","name":"TaskStop","input":{"task_id":"bgx1"}}]},"timestamp":"2026-01-02T00:00:03Z"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"stopped"}]},"timestamp":"2026-01-02T00:00:04Z"}' \
  '{"type":"user","message":{"content":"<task-notification>\n<task-id>agentA</task-id>\n<status>completed</status>\n<result>Found it.</result>\n</task-notification>"},"timestamp":"2026-01-02T00:00:05Z"}' \
  '{"type":"user","message":{"content":"<task-notification>\n<task-id>agentB</task-id>\n<status>killed</status>\n</task-notification>"},"timestamp":"2026-01-02T00:00:06Z"}' \
  '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-01-02T00:00:10Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$CSID.jsonl"
"$HQ" peek "$CSID" --json --meta | python3 -c '
import json,sys; d=json.load(sys.stdin)
st={i["id"]:i["status"] for i in d["items"] if i["kind"]=="tool"}
assert st=={"b1":"stopped","g1":"ok","g2":"stopped","q1":"ok","r1":"ok","s1":"ok"}, st
assert d["turn"]["done"] and d["turn"]["ms"]==10000 and d["turn"]["tokens"]==10, d["turn"]
' && ok "peek --meta: TaskStop, agentId-only and killed notifications end background rows; an interrupt ends the turn" || fail "peek --meta background endings / interrupt"
"$HQ" peek "$CSID" --tool g1 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["output"].endswith("— completed —\nFound it."), d' && ok "peek --tool finds an agent's result by its agentId" || fail "peek --tool agentId notification"
"$HQ" peek "$CSID" --tool b1 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "stopped" in d["output"], d' && ok "peek --tool says a TaskStop ended the command" || fail "peek --tool TaskStop"
printf '%s\n' \
  '{"type":"user","message":{"content":"again"},"timestamp":"2026-01-02T00:01:00Z"}' \
  '{"type":"assistant","message":{"id":"p3","usage":{"output_tokens":4},"content":[{"type":"text","text":"Sure."}]},"timestamp":"2026-01-02T00:01:02Z"}' \
  >> "$HOME/.claude/projects/-tmp-repo/$CSID.jsonl"
"$HQ" peek "$CSID" --json --meta | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert not d["turn"]["done"] and d["turn"]["start"]=="2026-01-02T00:01:00Z" and d["turn"]["tokens"]==4, d["turn"]
' && ok "peek --meta: the turn after an interrupt starts at its own prompt" || fail "peek --meta turn after interrupt"

# Slash commands for the board's message boxes: the newest full skill listing plus what was added after it.
KSID=feedface-7777-2222-3333-444455556666
printf '%s\n' \
  '{"type":"attachment","attachment":{"type":"skill_listing","content":"- gone: from before the resume","names":["gone"],"isInitial":true}}' \
  '{"type":"attachment","attachment":{"type":"skill_listing","content":"- review: Review the diff\n  over two lines\n- hud:setup: Configure: the HUD\n- hud: The bare plugin","names":["review","hud:setup","hud"],"isInitial":true}}' \
  '{"type":"user","message":{"content":"quoting {\"type\":\"skill_listing\",\"names\":[\"fake\"]}"}}' \
  '{"type":"attachment","attachment":{"type":"skill_listing","content":"- late: Turned up later","names":["late","review"],"isInitial":false}}' \
  > "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl"
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["found"] and d["skills"]==[{"name":"review","desc":"Review the diff"},{"name":"hud:setup","desc":"Configure: the HUD"},{"name":"hud","desc":"The bare plugin"},{"name":"late","desc":"Turned up later"}], d
' && ok "peek --commands: the newest full listing plus later additions, plugin names with colons" || fail "peek --commands listing"
"$HQ" peek "$KSID" --commands | head -1 | grep -qx "/review  Review the diff" && ok "peek --commands prints /name  description lines" || fail "peek --commands text"
: > "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl"
"$HQ" peek "$KSID" --commands --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"found":True,"skills":[]}, d' && ok "peek --commands: an empty transcript has no skills" || fail "peek --commands empty"
"$HQ" peek feedface-0000-0000-0000-000000000000 --commands --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"found":False,"skills":[]}, d' && ok "peek --commands: an unknown session is not found" || fail "peek --commands unknown"

"$HQ" log "$SID" "timed entry" >/dev/null
grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}: timed entry$' "$T"/root/tasks/"$SID"-*/TASK.md && ok "a log entry is stamped to the second"

# A template's placeholder todo ("- [ ] ...") is not listed, and numbering stays the card's own.
"$HQ" new "Placeholder" >/dev/null
PC="$(ls "$T"/root/tasks/T-*-placeholder/TASK.md)"; PID="$(basename "$(dirname "$PC")" | cut -d- -f1-2)"
printf '%s\n' '- [ ] ...' '- [ ] real one' >> "$PC"
"$HQ" board --json | python3 -c 'import json,sys; t=[x for x in json.load(sys.stdin)["tasks"] if x["id"]=="'"$PID"'"][0]; assert [(x["i"],x["text"]) for x in t["todos"]]==[(2,"real one")], t["todos"]' && ok "a placeholder todo is not listed, and the next keeps its number"
"$HQ" todo "$PID" 2 done --text "real one" >/dev/null && grep -q '^- \[x\] real one' "$PC" && ok "ticking by that number ticks the right line" || fail "ticking by number missed"

# "Later": the ask stays open, out of sight until tomorrow; the session hears it's coming later.
"$HQ" ask add "$PID" "Which index type?" >/dev/null
LID="$("$HQ" asks "$PID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Which index type?"][0])')"
"$HQ" ask snooze "$LID" >/dev/null
"$HQ" asks "$PID" --json | python3 -c 'import json,sys,datetime as d; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LID"'"][0]; assert a["state"]=="open" and d.datetime.fromisoformat(a["snoozed_until"]) > d.datetime.now(), a' && ok "Later keeps the ask open until tomorrow"
"$HQ" bind "$PID" --session sess-later >/dev/null
hook '{"session_id":"sess-later","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "$LID (the user will answer this later" && ok "the session is told an ask is coming later"
"$HQ" ask snooze "$LID" --until "" >/dev/null
"$HQ" asks "$PID" --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LID"'"][0]; assert a["state"]=="open" and not a.get("snoozed_until"), a' && ok "Later can be cleared" || fail "clearing Later left it hidden"
# A Later typed into the session must not stop the real answer, later, from reaching it.
"$HQ" ask snooze "$LID" >/dev/null; "$HQ" ask delivered "$LID" --session sess-later >/dev/null
"$HQ" ask resolve "$LID" do --via board --note "btree" >/dev/null
ctxof sess-later | grep -q "^- $LID \".*\" → answer: btree" && ok "an answer after a delivered Later still reaches the session" || fail "the answer after Later was never delivered"
# --until is normalised to local time, and nonsense is refused rather than written.
"$HQ" ask add "$PID" "Offsets?" >/dev/null
OID="$("$HQ" asks "$PID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Offsets?"][0])')"
"$HQ" ask snooze "$OID" --until 2030-01-01T00:00:00+00:00 >/dev/null && "$HQ" asks "$PID" >/dev/null && "$HQ" asks "$PID" --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$OID"'"][0]; assert "+" not in a["snoozed_until"] and len(a["snoozed_until"])==19, a' && ok "a snooze time with an offset is stored as local time" || fail "offset snooze broke hq asks"
"$HQ" ask snooze "$OID" --until tomorrow >/dev/null 2>&1 && fail "nonsense --until was accepted" || ok "nonsense --until is refused"

# SessionStart lists the card's open @claude todos — every source, text exactly as on the card —
# so a session that was compacted or cleared still ticks and drops them. Not on every prompt.
CT="$("$HQ" new "todo memory" | head -1)"; CC="$(ls "$T"/root/tasks/$CT-*/TASK.md)"
printf '\n## 待办\n- [ ] @me review the PR <!--t:2026-11-22T08:00:00+08:00-->\n- [x] @claude finished thing\n- [ ] @claude comment the #34019 result on PR #3262, then "ask" `x` <!--t:2026-11-22T09:00:00+08:00-->\n- [ ] @Claude delete the cluster  of #3260\n- [-] @claude dropped thing\n- [ ] @wenbing send the dataset\n' >> "$CC"
"$HQ" bind "$CT" --session sess-todo >/dev/null
startctx() { hook "{\"session_id\":\"sess-todo\",\"hook_event_name\":\"SessionStart\",\"source\":\"$1\"}" | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else "")'; }
c="$(startctx startup)"
echo "$c" | python3 -c '
import sys; c = sys.stdin.read()
assert "Open @claude todos on '"$CT"' (2)" in c, c
lines = c.splitlines()
assert "- comment the #34019 result on PR #3262, then \"ask\" `x`" in lines, c
assert "- delete the cluster  of #3260" in lines, c
for no in ("review the PR", "finished thing", "dropped thing", "send the dataset", "<!--t:"):
    assert no not in c, no
assert "done: <text>" in c and "drop: <text>" in c' && ok "SessionStart lists the open @claude todos, text exactly as on the card" || fail "SessionStart todo list: $c"
"$HQ" board --json | python3 -c 'import json,sys; t=[t for t in json.load(sys.stdin)["tasks"] if t["id"]=="'"$CT"'"][0]; o=[x["owner"] for x in t["todos"] if "delete the cluster" in x["text"]]; assert o==["claude"], o' && ok "@Claude is Claude's on the board too" || fail "@Claude owner not normalised"
for src in resume clear compact; do startctx $src | grep -q "^- delete the cluster  of #3260$" || fail "no todo list on SessionStart source=$src"; done; ok "resume, clear and compact get the list too"
startctx compact | grep -q "just compacted" && ok "after a compaction the session is told the list is the card's" || fail "compact note missing"
startctx startup | grep -q "compacted" && fail "compact note on a fresh start" || ok "a fresh start has no compaction note"
hook '{"session_id":"sess-todo","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "Open @claude todos" && fail "todo list injected on a prompt" || ok "the todo list is not repeated on every prompt"
stop sess-todo "$(printf 'ok\n```hq-update\ndone: comment the #34019 result on PR #3262, then "ask" `x`\ndrop: delete the cluster  of #3260\n```')" >/dev/null
grep -q -- '- \[x\] @claude comment the #34019' "$CC" && grep -q -- '- \[-\] @Claude delete the cluster' "$CC" && ok "done: / drop: with the listed text tick and drop them" || fail "listed text did not match: $(grep '@claude\|@Claude' "$CC")"
[ -z "$(startctx startup | grep "Open @claude todos")" ] && ok "no list when nothing is open for Claude" || fail "empty todo list shown"
python3 - "$CC" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s += "".join(f"- [ ] @claude item {i:02d} do the thing\n" for i in range(1, 26))
open(p, "w", encoding="utf-8").write(s)
PY
startctx startup | python3 -c '
import sys; c = sys.stdin.read(); l = [x for x in c.splitlines() if x.startswith("- item ")]
assert len(l) == 20 and l[0] == "- item 06 do the thing" and l[-1] == "- item 25 do the thing", l
assert "- … 5 older ones not shown" in c and "(25)" in c, c' && ok "the list keeps the newest 20 and counts the rest" || fail "20-item cap"
python3 - "$CC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"^- \[ \] @claude item .*\n", "", s, flags=re.M)
s += "".join(f"- [ ] @claude long {i:02d} " + "x" * 290 + "\n" for i in range(1, 11))
open(p, "w", encoding="utf-8").write(s)
PY
startctx startup | python3 -c '
import sys; c = sys.stdin.read(); l = [x for x in c.splitlines() if x.startswith("- long ")]
assert 1 <= len(l) < 10 and sum(len(x) for x in l) <= 2000 + 2 * len(l) and l[-1].startswith("- long 10 "), l
assert f"- … {10 - len(l)} older ones not shown" in c, c' && ok "and stays within about 2000 characters" || fail "character cap"
"$HQ" unbind --session sess-todo >/dev/null

# Refs are keyed by the thing a link points to: a PR's /files or /commits is the PR, a Jira board
# page the issue, a Jenkins console or test report the build. A link to one comment, and any other
# #fragment, stays its own. hq and board.js agree.
python3 - "$HQ" <<'PY' && ok "canonical keys for GitHub, Jira, Jenkins, Confluence and other URLs" || fail "canonical keys"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hqmod", sys.argv[1])
spec = importlib.util.spec_from_loader("hqmod", loader); hq = importlib.util.module_from_spec(spec); loader.exec_module(hq)
GH, JI, JK = "https://github.com/tigergraph/bigtest", "https://graphsql.atlassian.net", "https://jenkins.graphtiger.com/job"
cases = [
    (f"{GH}/pull/3261#issuecomment-7075621457", f"{GH}/pull/3261#issuecomment-7075621457"),
    (f"{GH}/pull/3261", f"{GH}/pull/3261"),
    (f"{GH}/pull/3261/", f"{GH}/pull/3261"),
    (f"{GH}/pull/12/files", f"{GH}/pull/12"),
    (f"{GH}/pull/12/files#diff-abc123", f"{GH}/pull/12"),
    (f"{GH}/pull/12/commits/0a1b2c3", f"{GH}/pull/12"),
    (f"{GH}/pull/12/checks?check_run_id=9", f"{GH}/pull/12"),
    (f"{GH}/pull/12#discussion_r1234", f"{GH}/pull/12#discussion_r1234"),
    (f"{GH}/pull/12/files#r987", f"{GH}/pull/12/files#r987"),
    (f"{GH}/pull/12#pullrequestreview-55", f"{GH}/pull/12#pullrequestreview-55"),
    ("https://GitHub.com/ZephTu/claude-pet/issues/7#issuecomment-1", "https://github.com/ZephTu/claude-pet/issues/7#issuecomment-1"),
    (f"{GH}/commit/0a1b2c3d#diff-1", f"{GH}/commit/0a1b2c3d#diff-1"),
    (f"{GH}/blob/master/a.py#L10-L20", f"{GH}/blob/master/a.py#L10-L20"),
    (f"{GH}/pulls", f"{GH}/pulls"),
    (f"{GH}/tree/fix/x", f"{GH}/tree/fix/x"),
    ("https://github.example.com/o/r/pull/3/files", "https://github.example.com/o/r/pull/3"),
    (f"{JI}/browse/GLE-13975", f"{JI}/browse/GLE-13975"),
    (f"{JI}/browse/QA-9517?focusedCommentId=123&page=x#comment-123", f"{JI}/browse/QA-9517?focusedCommentId=123"),
    (f"{JI}/browse/QA-9517?filter=1", f"{JI}/browse/QA-9517"),
    (f"{JI}/browse/CORE-6234#comment-9", f"{JI}/browse/CORE-6234?focusedCommentId=9"),
    (f"{JI}/jira/software/c/projects/QA/issues/QA-9517?jql=project%3DQA", f"{JI}/browse/QA-9517"),
    (f"{JI}/jira/software/projects/QA/boards/12?selectedIssue=QA-77", f"{JI}/browse/QA-77"),
    (f"{JI}/jira/servicedesk/projects/TSE/queues/custom/1/TSE-1061", f"{JI}/browse/TSE-1061"),
    ("https://jira.example.com/jira/browse/ABC-1#x", "https://jira.example.com/jira/browse/ABC-1"),
    (f"{JK}/release_test_all/33911/", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/console", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/consoleFull", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/consoleText", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/testReport/junit/a/b/", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/artifact/logs/x.log", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/pipeline-console/?selected-node=12", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_all/33911/display/redirect", f"{JK}/release_test_all/33911"),
    (f"{JK}/release_test_pipeline/57353/console#footer", f"{JK}/release_test_pipeline/57353"),
    (f"{JK}/org/job/repo/job/PR-12/5/console", f"{JK}/org/job/repo/job/PR-12/5"),
    ("https://jenkins.graphtiger.com/view/QA/job/release_test/31416/console", "https://jenkins.graphtiger.com/view/QA/job/release_test/31416"),
    (f"{JK}/release_test_all/", f"{JK}/release_test_all"),
    (f"{JK}/release_test_all/lastBuild/console", f"{JK}/release_test_all/lastBuild/console"),
    (f"{JK}/folder/job/123", f"{JK}/folder/job/123"),
    ("https://ci.example.com/job/x/42/console", "https://ci.example.com/job/x/42"),
    ("https://careers.example.com/job/engineer/12345/apply", "https://careers.example.com/job/engineer/12345/apply"),
    ("https://jenkins.example.com/job/x/42/anything", "https://jenkins.example.com/job/x/42"),
    (f"{JI}/wiki/spaces/QA/pages/1643216972/VENTI+QWENTI+reservation+status", f"{JI}/wiki/spaces/QA/pages/1643216972/VENTI+QWENTI+reservation+status"),
    (f"{JI}/wiki/spaces/QA/pages/1643216972/VENTI+QWENTI+reservation+status#Hosts", f"{JI}/wiki/spaces/QA/pages/1643216972/VENTI+QWENTI+reservation+status#Hosts"),
    (f"{JI}/wiki/pages/viewpage.action?pageId=5377851394", f"{JI}/wiki/pages/viewpage.action?pageId=5377851394"),
    (f"{JI}/wiki/pages/viewpage.action?pageId=5377851394#comment-9", f"{JI}/wiki/pages/viewpage.action?pageId=5377851394#comment-9"),
    (f"{JI}/wiki/x/AwDkNgE", f"{JI}/wiki/x/AwDkNgE"),
    ("https://qa-hub.graphtiger.com/releases/plans/release-test-all-k8s", "https://qa-hub.graphtiger.com/releases/plans/release-test-all-k8s"),
    ("https://qa-hub.graphtiger.com/releases/runs/release_test_all/33903", "https://qa-hub.graphtiger.com/releases/runs/release_test_all/33903"),
    ("https://tigergraph-release-prebuild.s3.amazonaws.com/prebuild/tigergraph-4.2.7-prod_sv4-wip_test_82526-offline.tar.gz",
     "https://tigergraph-release-prebuild.s3.amazonaws.com/prebuild/tigergraph-4.2.7-prod_sv4-wip_test_82526-offline.tar.gz"),
    ("https://claude.ai/artifact/Rr6LsqTHQYTSQZZfafzcZa", "https://claude.ai/artifact/Rr6LsqTHQYTSQZZfafzcZa"),
    ("https://Example.COM/Path/#frag", "https://example.com/Path/#frag"),
    ("https://Example.COM/Path/#", "https://example.com/Path"),
    ("https://app.example.com/#/runs/1", "https://app.example.com/#/runs/1"),
    ("http://example.com:8080/a?b=1#c", "http://example.com:8080/a?b=1#c"),
    ("https://example.com/p/1).", "https://example.com/p/1"),
]
bad = [(u, hq.ref_key(f"title {u}"), want) for u, want in cases if hq.ref_key(f"title {u}") != want]
assert not bad, "\n".join(map(str, bad))
assert hq.ref_key("QA-1  x") == "QA-1 x" and hq.ref_key(f"a {GH}/pull/1 b {GH}/pull/1#c") == f"a {GH}/pull/1 b {GH}/pull/1#c"
PY
python3 - "$HQ" <<'PY' && ok "merging: canonical URL kept, its title preferred, else the newest; merging again changes nothing" || fail "merge_refs"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("hqmod", sys.argv[1])
spec = importlib.util.spec_from_loader("hqmod", loader); hq = importlib.util.module_from_spec(spec); loader.exec_module(hq)
GH, JK = "https://github.com/tigergraph/bigtest/pull", "https://jenkins.graphtiger.com/job/release_test_all"
card = [f"PR #3260 remote_segment rotate + replica count {GH}/3260", f"smoke #33911 {JK}/33911/", f"smoke #33911 (passed) {JK}/33911/",
        f"PR #3261 replica check version range {GH}/3261", f"PR #3261 verification comment {GH}/3261#issuecomment-7075621457",
        f"PR #3260 remote-segment verification comment {GH}/3260#issuecomment-7075987355", "QA-9517",
        f"PR #3260 re-verify comment (#34021) {GH}/3260#issuecomment-7076621584",
        f"console of #5 https://jenkins.example.com/job/x/5/console", f"report of #5 https://jenkins.example.com/job/x/5/testReport/"]
want = [f"PR #3260 remote_segment rotate + replica count {GH}/3260", f"smoke #33911 (passed) {JK}/33911/",
        f"PR #3261 replica check version range {GH}/3261", card[4], card[5], "QA-9517", card[7],  # comments stay
        "report of #5 https://jenkins.example.com/job/x/5/"]  # what followed the URL (here its /) stays
got = hq.merge_refs(card, [])
assert got == want, got
assert hq.merge_refs(got, []) == got and hq.merge_refs(got, card) == got
assert hq.merge_refs(got, [f"PR #3261 (merged) {GH}/3261/"]) == want[:2] + [f"PR #3261 (merged) {GH}/3261/"] + want[3:]
# A link with nothing to merge with is left exactly as written; different #/routes are different links.
assert hq.merge_refs([f"see {GH}/9/files)."], []) == [f"see {GH}/9/files)."]
assert hq.merge_refs(["a https://app.example.com/#/runs/1"], ["b https://app.example.com/#/runs/2"]) == ["a https://app.example.com/#/runs/1", "b https://app.example.com/#/runs/2"]
assert hq.merge_refs(["same https://e.com/x/", "same https://e.com/x/"], []) == ["same https://e.com/x/"]
PY
LT="$("$HQ" new "links" | head -1)"; LC="$(ls "$T"/root/tasks/$LT-*/TASK.md)"
lrefs() { "$HQ" board --json | python3 -c 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin)["tasks"] if t["id"]=="'"$LT"'"][0]["refs"], ensure_ascii=False))'; }
"$HQ" bind "$LT" --session sess-links >/dev/null
GHP=https://github.com/o/r/pull
stop sess-links "$(printf 'ok\n```hq-update\nref: PR #9 commits %s/9/commits\nref: PR #9 files %s/9/files\n```' $GHP $GHP)" >/dev/null
[ "$(lrefs)" = "[\"PR #9 files $GHP/9\"]" ] && ok "hq-update: two views of one PR become one ref at the PR's URL, the newer title kept" || fail "views not merged: $(lrefs)"
before="$(lrefs)"; stop sess-links "$(printf 'ok\n```hq-update\nref: PR #9 commits %s/9/commits\nref: PR #9 files %s/9/files\n```' $GHP $GHP)" >/dev/null
[ "$(lrefs)" = "$before" ] && ok "a resent block changes no ref" || fail "resent block changed refs: $(lrefs)"
stop sess-links "$(printf 'ok\n```hq-update\nref: PR #9 (merged) %s/9\n```' $GHP)" >/dev/null
stop sess-links "$(printf 'ok\n```hq-update\nref: PR #9 checks %s/9/checks\n```' $GHP)" >/dev/null
[ "$(lrefs)" = "[\"PR #9 (merged) $GHP/9\"]" ] && ok "a title on the PR's own URL beats a view's title" || fail "title choice: $(lrefs)"
stop sess-links "$(printf 'ok\n```hq-update\nref: PR #9 verification comment %s/9#issuecomment-1\n```' $GHP)" >/dev/null
[ "$(lrefs)" = "[\"PR #9 (merged) $GHP/9\", \"PR #9 verification comment $GHP/9#issuecomment-1\"]" ] && ok "a link to one comment stays its own entry" || fail "comment merged: $(lrefs)"
"$HQ" ref add "$LT" "comment https://jira.example.com/browse/QA-1?focusedCommentId=7#comment-7" && [ "$(lrefs)" = "[\"PR #9 (merged) $GHP/9\", \"PR #9 verification comment $GHP/9#issuecomment-1\", \"comment https://jira.example.com/browse/QA-1?focusedCommentId=7#comment-7\"]" ] && ok "hq ref add keeps a lone link exactly as written" || fail "ref add rewrote a lone link: $(lrefs)"
python3 - "$LC" "$GHP" <<'PY'
import re, sys
p, g = sys.argv[1], sys.argv[2]; s = open(p, encoding="utf-8").read()
refs = f'["build https://ci.example.com/job/x/42/", "QA-2", "log https://ci.example.com/job/x/42/consoleFull", "PR #9 {g}/9"]'
s = re.sub(r"^refs: .*$", lambda m: "refs: " + refs, s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY
out="$("$HQ" ref remove "$LT" "https://ci.example.com/job/x/42/testReport/")"
[ "$out" = '{"removed": [{"i": 0, "ref": "build https://ci.example.com/job/x/42/"}, {"i": 2, "ref": "log https://ci.example.com/job/x/42/consoleFull"}]}' ] && [ "$(lrefs)" = "[\"QA-2\", \"PR #9 $GHP/9\"]" ] && ok "ref remove by any view of a build removes every entry for it" || fail "remove canonical: $out / $(lrefs)"
"$HQ" ref restore "$LT" "$out" && [ "$(lrefs)" = "[\"build https://ci.example.com/job/x/42/\", \"QA-2\", \"log https://ci.example.com/job/x/42/consoleFull\", \"PR #9 $GHP/9\"]" ] && ok "ref restore puts the variants back as they were" || fail "restore canonical: $(lrefs)"
"$HQ" ref restore "$LT" "$out" && [ "$(lrefs)" = "[\"build https://ci.example.com/job/x/42/\", \"QA-2\", \"log https://ci.example.com/job/x/42/consoleFull\", \"PR #9 $GHP/9\"]" ] && ok "and restoring twice adds nothing" || fail "second restore: $(lrefs)"
"$HQ" unbind --session sess-links >/dev/null

# Today's order: hq focus order puts the named tasks first, in that order; the rest keep theirs.
"$HQ" focus add T-001 T-002 "$PID" >/dev/null
"$HQ" focus order "$PID" T-001 >/dev/null
"$HQ" focus --json | python3 -c 'import json,sys; ids=json.load(sys.stdin)["ids"]; assert ids[:3]==["'"$PID"'","T-001","T-002"], ids' && ok "Focus can be reordered"
"$HQ" focus order T-001 T-001 >/dev/null; "$HQ" focus --json | python3 -c 'import json,sys; ids=json.load(sys.stdin)["ids"]; assert len(ids)==len(set(ids)), ids' && ok "focus order drops repeated ids" || fail "focus order kept a repeated id"

# Standing grants: "yes, and from now on just do it".
"$HQ" new "Grants" >/dev/null; GT="$(ls -d "$T"/root/tasks/T-*-grants | xargs basename | cut -d- -f1-2)"
GC="$(ls "$T"/root/tasks/$GT-*/TASK.md)"
"$HQ" bind "$GT" --session sess-g >/dev/null
c="$(hook '{"session_id":"sess-g","hook_event_name":"SessionStart"}')"
echo "$c" | grep -q "Standing grants" && fail "grants injected with none on the card" || ok "no grants, no grants text"
grep -q '\[grant: ' <<<"$c" && ok "protocol teaches the [grant: …] suggestion" || fail "protocol lacks grant suggestion"
[ -z "$(hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}')" ] && ok "unchanged grants add nothing to a prompt" || fail "prompt injected something"
MSG='Ran it.\n\n```hq-asks\n- Rerun #31388 with the same parameters? [grant: rerun a verification with the same parameters]\n```'
hook "{\"session_id\":\"sess-g\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
"$HQ" asks "$GT" --json | python3 -c 'import json,sys; a=json.load(sys.stdin)[0]; assert a["text"]=="Rerun #31388 with the same parameters?" and a["grant"]=="rerun a verification with the same parameters", a' && ok "an ask keeps its grant suggestion apart from the question" || fail "grant suggestion"
"$HQ" ask resolve "$GT.1" drop --grant "x" --via board 2>/dev/null && fail "grant with a no accepted" || ok "a grant goes only with yes"
CLAUDE_CODE_SESSION_ID=sess-g "$HQ" ask resolve "$GT.1" do --grant "rerun a verification with the same parameters" 2>/dev/null \
  && fail "a session granted itself permission" || ok "a session can't answer its own ask with a grant"
"$HQ" ask resolve "$GT.1" do --via board --grant "rerun a verification with the same parameters" | grep -q '"existed": false' \
  && ok "resolve with a grant says it is new (for the board's Undo)" || fail "resolve grant output"
grep -q '^## Grants$' "$GC" && grep -q "^- rerun a verification with the same parameters <!--g:.* $GT.1-->$" "$GC" && ok "yes, always writes the grant to the card with its source ask" || fail "grant not on card: $(cat "$GC")"
"$HQ" board --json | python3 -c "import json,sys; t=[x for x in json.load(sys.stdin)['tasks'] if x['id']=='$GT'][0]; assert t['grants'][0]['text']=='rerun a verification with the same parameters' and t['grants'][0]['from']=='$GT.1' and not t['todos'], t" && ok "board json lists grants (and they are not todos)" || fail "board json grants"
c="$(hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c" | grep -q "→ yes — go ahead as you suggested — and from now on, without asking: rerun a verification" && ok "the answer tells the session about the grant" || fail "answer lacks grant: $c"
echo "$c" | grep -q "+ granted" && fail "a grant made by an answer is stated twice: $c" || ok "a grant made by an answer is stated once, with it"
[ -z "$(hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}')" ] && ok "then nothing more while grants stay the same" || fail "grants repeated"
"$HQ" grant add "$GT" "Rerun a verification with  the same parameters" | grep -q '"existed": true' && ok "the same wording is not added twice" || fail "duplicate grant"
CLAUDE_CODE_SESSION_ID=sess-g "$HQ" grant add "$GT" "anything at all" 2>/dev/null && fail "a session added a grant" || ok "hq grant add refuses inside a Claude Code session"
"$HQ" grant add "$GT" "delete a test env once its failure is triaged and written down" >/dev/null
hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "+ granted — a permission from now on, not a request to act now: delete a test env" \
  && ok "a grant added elsewhere is injected once as a change" || fail "grant change"
"$HQ" grant list "$GT" | grep -q "^ 2. delete a test env" && ok "hq grant list numbers grants" || fail "grant list"
hook '{"session_id":"sess-g","hook_event_name":"SessionStart","source":"compact"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "Standing grants on" in c and "- rerun a verification" in c and "- delete a test env" in c, c' && ok "SessionStart (compact too) lists every grant" || fail "SessionStart grants"
"$HQ" grant revoke "$GT" 1 --text "something else" 2>/dev/null && fail "revoke by a stale number" || ok "revoke refuses when #n no longer has that wording"
"$HQ" grant revoke "$GT" 1 --via board | grep -q '"from": "'"$GT"'.1"' && ok "revoke returns the grant (for an undo)" || fail "revoke output"
grep -q "grant revoked (board): rerun a verification" "$GC" && ok "revoking is logged on the card" || fail "revoke not logged"
c="$(hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c" | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert c.splitlines()[1:]==["- revoked — ask again before doing this: rerun a verification with the same parameters"], c' && ok "a revoke is injected once, alone" || fail "revoke change: $c"
"$HQ" grant add "$GT" "temp grant" >/dev/null; hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null
"$HQ" grant revoke "$GT" "temp grant" >/dev/null
hook '{"session_id":"sess-g","hook_event_name":"SessionStart","source":"resume"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "since you last saw them — ask again before doing these:\n- temp grant" in c and "- delete a test env" in c, c' \
  && ok "a resumed session hears what was revoked while it was away" || fail "revoke lost across resume"
CLAUDE_CODE_SESSION_ID=sess-g "$HQ" grant revoke "$GT" "delete a test env once its failure is triaged and written down" >/dev/null \
  && ok "a session may still revoke (it only takes permission away)" || fail "session revoke"
grep -qi '^## Grants' "$GC" && fail "empty grants section left behind" || ok "the last revoke removes the section"
"$HQ" grant add "$GT" "- [ ] rerun the smoke test" | grep -q '"text": "rerun the smoke test"' && ! grep -q -- "- \[ \] rerun the smoke test" "$GC" \
  && ok "a checkbox typed into a grant is dropped (it'd be a todo)" || fail "checkbox grant: $(cat "$GC")"
"$HQ" grant revoke "$GT" "rerun the smoke test" >/dev/null
"$HQ" grant add "$GT" "fix review findings on the same PR" --at 2026-01-01T00:00:00+08:00 --source "$GT.9" >/dev/null
# The board's bridge (BoardWindow.swift) sends positionals first, then options; the wording as --text=.
"$HQ" grant add "$GT" --via=board "--text=-n rerun with -same flags" --source="$GT.8" | grep -q '"text": "-n rerun with -same flags"' \
  && ok "board form: add with --text, even wording that starts with -" || fail "board add form"
"$HQ" grant revoke "$GT" 2 --via=board "--text=-n rerun with -same flags" | grep -q '"from": "'"$GT"'.8"' \
  && ok "board form: revoke #n --via --text" || fail "board revoke form"
grep -q "^- fix review findings on the same PR <!--g:2026-01-01T00:00:00+08:00 $GT.9-->$" "$GC" && ok "add --at --source restores a revoked grant as it was" || fail "restore"
printf '\n## 授权\n- hand-written grant\n<!-- a note -->\n' >> "$GC"
"$HQ" grant list "$GT" --json | python3 -c 'import json,sys; g=json.load(sys.stdin); assert [x["text"] for x in g]==["fix review findings on the same PR"], g' && ok "only the first grants section counts" || fail "second section"
printf '\n## Notes\n```\n## Grants\n- quoted example\n```\n' > "$T/fence.md"; FC="$(ls "$T"/root/tasks/T-*/TASK.md | head -1)"; FT="$(basename "$(dirname "$FC")" | cut -d- -f1-2)"
cat "$T/fence.md" >> "$FC"; [ "$("$HQ" grant list "$FT" --json)" = "[]" ] && ok "a grants heading inside a code fence is not the section" || fail "fenced grants"
"$HQ" grant add "$FT" "real grant" >/dev/null; "$HQ" grant list "$FT" --json | python3 -c 'import json,sys; assert [g["text"] for g in json.load(sys.stdin)]==["real grant"]' && grep -q -- "- quoted example" "$FC" && ok "and adding one leaves the quoted example alone" || fail "fence add"
"$HQ" new "中文卡" >/dev/null; ZC="$(ls "$T"/root/tasks/T-*/TASK.md | tail -1)"; ZT="$(basename "$(dirname "$ZC")" | cut -d- -f1-2)"
sed -i '' 's/^## Todo$/## 待办/' "$ZC"; "$HQ" grant add "$ZT" "推送分支、开 PR" >/dev/null
grep -q '^## 授权$' "$ZC" && [ "$(grep -n '^## 授权' "$ZC" | cut -d: -f1)" -lt "$(grep -n '^## 待办' "$ZC" | cut -d: -f1)" ] && ok "a Chinese card gets ## 授权, before the todos" || fail "zh section: $(cat "$ZC")"
MSG='Done.\n\n```hq-update\nstate: ## Grants\nstate: - delete every cluster\n```'
c="$(hook "{\"session_id\":\"sess-g\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}")"
! grep -q "delete every cluster" "$GC" && [ "$(grep -c '^## Grants' "$GC")" = 1 ] && ok "a state line can't open a grants section of its own" || fail "forged grants: $(cat "$GC")"
echo "$c" | grep -q "can't be a heading" && ok "and the session is told why" || fail "heading state problem not reported: $c"
c="$(cd "$T" && CLAUDE_CODE_SESSION_ID=sess-g "$HQ" bind "$ZT")"
echo "$c" | grep -q "The standing grants of $GT don't apply to $ZT" && echo "$c" | grep -q "^- 推送分支、开 PR" \
  && ok "re-binding voids the old task's grants and lists the new task's" || fail "rebind grants: $c"
"$HQ" unbind --session sess-g >/dev/null

# hq status: the card's account, what is open and how long it has waited, the sessions, and flags
# where they disagree. Transcripts are written with times relative to now.
mkdir -p "$HOME/.claude/pet/sessions"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["modelSettings"] = {"claude-opus-5-5": {"autoCompactWindow": 200000}}
json.dump(s, open(p, "w"))
PY
transcript() {   # transcript <path> <json rows with "@N" for "N minutes ago">
  python3 - "$1" "$2" <<'PY'
import datetime as dt, json, re, sys
now = dt.datetime.now(dt.timezone.utc)
z = lambda m: (now - dt.timedelta(minutes=int(m))).strftime("%Y-%m-%dT%H:%M:%S.000Z")
rows = json.loads(re.sub(r'"@(\d+)"', lambda m: json.dumps(z(m.group(1))), sys.argv[2]))
open(sys.argv[1], "a").write("".join(json.dumps(r) + "\n" for r in rows))
PY
}
backdate() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
P="$HOME/.claude/projects/-tmp-repo"
# S1: its one session ended after running a build the card never heard of; the card says it waits for that build.
S1="$("$HQ" new "Status probe" --no-focus | head -1)"; S1C="$(ls "$T"/root/tasks/$S1-*/TASK.md)"
SS1=5ca7e5a1-1111-2222-3333-444455556666
transcript "$P/$SS1.jsonl" '[
 {"type":"user","message":{"content":"start the build"},"timestamp":"@130"},
 {"type":"assistant","message":{"id":"a1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":99990,"output_tokens":5},"content":[{"type":"text","text":"Starting."},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"make build"}}]},"timestamp":"@125"},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"ok"}]},"timestamp":"@120"},
 {"type":"assistant","message":{"id":"a2","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":99990,"output_tokens":5},"content":[{"type":"text","text":"Build #12345 started.\n\n```hq-update\ntouch\n```"}]},"timestamp":"@119"},
 {"type":"system","subtype":"turn_duration","durationMs":1000,"timestamp":"@119"}]'
"$HQ" bind "$S1" --session "$SS1" >/dev/null
"$HQ" set "$S1" "next=wait for build #12345 to finish, then send the report" >/dev/null
"$HQ" addtodo "$S1" "@me review the report" >/dev/null; "$HQ" addtodo "$S1" "@claude post the numbers" >/dev/null
"$HQ" addtodo "$S1" "@Ping check the env" >/dev/null; "$HQ" ask add "$S1" "Ship v2?" >/dev/null
"$HQ" log "$S1" "kicked off the build"; "$HQ" todo "$S1" 1 done >/dev/null; "$HQ" addtodo "$S1" "@me review the report again" >/dev/null
backdate "$S1C" 180
"$HQ" status "$S1" --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["tasks"][0]; k=[f["kind"] for f in t["flags"]]
assert k==["card-behind","idle-waiting"], t["flags"]
assert "build #12345 to finish" in t["flags"][1]["says"] and "no live session" in t["flags"][1]["text"], t["flags"]
td=t["todos"]; assert (td["me"]["count"],td["claude"]["count"],td["others"]["count"])==(1,1,1) and td["others"]["items"][0]["owner"]=="Ping", td
assert td["me"]["items"][0]["text"]=="review the report again" and td["me"]["items"][0]["since"], td
assert t["asks"]["count"]==1 and t["asks"]["items"][0]["since"], t["asks"]
assert t["log"][-1]["text"]=="kicked off the build", t["log"]   # todo ticks are left out
s=t["sessions"][0]; assert s["state"]=="ended" and not s["live"] and s["idleFor"]>=119*60, s
assert s["context"]=={"tokens":100000,"budget":200000,"percent":50}, s["context"]
assert s["messages"][-1]=={"role":"assistant","ts":s["messages"][-1]["ts"],"text":"Build #12345 started."}, s["messages"]
' && ok "status: card, open todos by owner with their waits, asks, log, the session and its context" || fail "status JSON"
"$HQ" status "$S1" | grep -q "⚠ card behind: session 5ca7e5a1 worked until" && ok "status: flags a card its session worked past" || fail "status card-behind"
"$HQ" status "$S1" | grep -q "^  @me todos (1):" && ok "status prints a text summary" || fail "status text"
# An API error as the last reply (no tokens, model "<synthetic>") leaves the budget as it was.
transcript "$P/$SS1.jsonl" '[{"type":"assistant","message":{"id":"a3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"API Error: overloaded"}]},"timestamp":"@118"}]'
"$HQ" status "$S1" --json | python3 -c 'import json,sys; c=json.load(sys.stdin)["tasks"][0]["sessions"][0]["context"]; assert c=={"tokens":100000,"budget":200000,"percent":50}, c' && ok "status: an API-error reply does not change the context budget" || fail "status context after API error"
# The card written after that work: not behind any more.
"$HQ" touch "$S1" >/dev/null
"$HQ" status "$S1" --json | python3 -c 'import json,sys; k=[f["kind"] for f in json.load(sys.stdin)["tasks"][0]["flags"]]; assert k==["idle-waiting"], k' && ok "status: a card written after its session's work is not behind" || fail "status card-behind cleared"

# S2: a live, idle session watching the build in the background — that is waiting, not stuck.
S2="$("$HQ" new "Status watch" --no-focus | head -1)"
SS2=5ca7e5a2-1111-2222-3333-444455556666
transcript "$P/$SS2.jsonl" '[
 {"type":"user","message":{"content":"watch it"},"timestamp":"@122"},
 {"type":"assistant","message":{"id":"c1","content":[{"type":"tool_use","id":"w1","name":"Bash","input":{"command":"watch-build 12345","run_in_background":true}}]},"timestamp":"@121"},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w1","content":"Command running in background with ID: bgw1"}]},"toolUseResult":{"backgroundTaskId":"bgw1"},"timestamp":"@120"},
 {"type":"assistant","message":{"id":"c2","content":[{"type":"text","text":"Watching."}]},"timestamp":"@120"}]'
echo "{\"pid\": $$, \"state\": \"idle\", \"sessionId\": \"$SS2\", \"transcript\": \"$P/$SS2.jsonl\"}" > "$HOME/.claude/pet/sessions/$SS2.json"
"$HQ" bind "$S2" --session "$SS2" >/dev/null
"$HQ" set "$S2" "next=when the watcher fires, read the build result" >/dev/null
"$HQ" status "$S2" --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["tasks"][0]; s=t["sessions"][0]
assert t["flags"]==[] and s["live"] and s["state"]=="idle" and len(s["background"])==1, t' && ok "status: an idle session with a watcher running in the background is not flagged" || fail "status background watcher"
transcript "$P/$SS2.jsonl" '[{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<tool-use-id>w1</tool-use-id>\n<status>completed</status>\n</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}},"timestamp":"@100"}]'
"$HQ" status "$S2" --json | python3 -c '
import json,sys; f=json.load(sys.stdin)["tasks"][0]["flags"]
assert [x["kind"] for x in f]==["idle-waiting"] and "idle with nothing in the background" in f[0]["text"], f' && ok "status: once the watcher is done and the session sits idle, the card waiting on it is flagged" || fail "status idle-waiting live"
# The watcher's completion notice arriving is not the session calling tools after the card.
backdate "$(ls "$T"/root/tasks/$S2-*/TASK.md)" 115
"$HQ" status "$S2" --json | python3 -c 'import json,sys; k=[f["kind"] for f in json.load(sys.stdin)["tasks"][0]["flags"]]; assert k==["idle-waiting"], k' && ok "status: a background job finishing does not put the card behind" || fail "status card-behind on background completion"
"$HQ" set "$S2" "next=wait on Ping for the numbers" >/dev/null
"$HQ" status "$S2" --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["tasks"][0]["flags"]==[]' && ok "status: waiting on a person is not flagged" || fail "status waiting on a person"

# S3: done, with a session still running on it. S4: open, untouched for weeks, and over budget.
S3="$("$HQ" new "Status done" --no-focus | head -1)"
SS3=5ca7e5a3-1111-2222-3333-444455556666
transcript "$P/$SS3.jsonl" '[{"type":"assistant","message":{"id":"d1","content":[{"type":"text","text":"Done."}]},"timestamp":"@5"}]'
echo "{\"pid\": $$, \"state\": \"idle\", \"sessionId\": \"$SS3\", \"transcript\": \"$P/$SS3.jsonl\"}" > "$HOME/.claude/pet/sessions/$SS3.json"
"$HQ" bind "$S3" --session "$SS3" >/dev/null; "$HQ" set "$S3" status=done >/dev/null
S4="$("$HQ" new "Status stale" --no-focus | head -1)"; S4C="$(ls "$T"/root/tasks/$S4-*/TASK.md)"
python3 - "$S4C" <<'PY'
import json, re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"^updated: .*$", "updated: 2020-01-01", s, flags=re.M)
s = re.sub(r"^refs: .*$", "refs: " + json.dumps([f"run {i} https://ci.example/{i}" for i in range(31)]), s, flags=re.M)
open(p, "w").write(s)
PY
"$HQ" status "$S3" "$S4" --json | python3 -c '
import json,sys; a,b=json.load(sys.stdin)["tasks"]
assert [f["kind"] for f in a["flags"]]==["done-live"] and a["flags"][0]["sessions"]==["'"$SS3"'"], a["flags"]
assert [f["kind"] for f in b["flags"]]==["stale","over-budget"] and b["flags"][1]["refs"]==31, b["flags"]
assert "卡片超预算" in b["flags"][1]["text_zh"], b["flags"]' && ok "status: a done task with a live session, a stale card, a card over budget" || fail "status done-live / stale / over-budget"
"$HQ" status --json | python3 -c '
import json,sys; ids=[t["id"] for t in json.load(sys.stdin)["tasks"]]
assert "'"$S3"'" in ids and "'"$S4"'" in ids, ids' && ok "status with no task: every open task, and a done one only while a session runs on it" || fail "status default selection"
"$HQ" status --flagged --json | python3 -c 'import json,sys; ids=[t["id"] for t in json.load(sys.stdin)["tasks"]]; assert all(i!="'"$S2"'" for i in ids) and "'"$S4"'" in ids, ids' && ok "status --flagged keeps only the flagged tasks" || fail "status --flagged"
"$HQ" focus add "$S2" >/dev/null
"$HQ" status --focus --json | python3 -c 'import json,sys; ids=[t["id"] for t in json.load(sys.stdin)["tasks"]]; assert "'"$S2"'" in ids and "'"$S4"'" not in ids, ids' && ok "status --focus covers the Focus list" || fail "status --focus"
# S5: a session held at a permission prompt is mid-turn, so not behind; then it moves to S6.
S5="$("$HQ" new "Status prompt" --no-focus | head -1)"; S5C="$(ls "$T"/root/tasks/$S5-*/TASK.md)"
SS5=5ca7e5a5-1111-2222-3333-444455556666
transcript "$P/$SS5.jsonl" '[{"type":"assistant","message":{"id":"e1","content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"rm -rf build"}}]},"timestamp":"@30"}]'
echo "{\"pid\": $$, \"state\": \"waiting\", \"sessionId\": \"$SS5\", \"transcript\": \"$P/$SS5.jsonl\"}" > "$HOME/.claude/pet/sessions/$SS5.json"
"$HQ" bind "$S5" --session "$SS5" >/dev/null; backdate "$S5C" 60
"$HQ" status "$S5" --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["flags"]==[] and t["sessions"][0]["state"]=="waiting-on-you", t' && ok "status: a session held at a prompt is not a card behind" || fail "status card-behind while waiting on a prompt"
echo "{\"pid\": $$, \"state\": \"idle\", \"sessionId\": \"$SS5\", \"transcript\": \"$P/$SS5.jsonl\"}" > "$HOME/.claude/pet/sessions/$SS5.json"
"$HQ" status "$S5" --json | python3 -c 'import json,sys; k=[f["kind"] for f in json.load(sys.stdin)["tasks"][0]["flags"]]; assert k==["card-behind"], k' && ok "status: the same session, idle, is" || fail "status card-behind once idle"
S6="$("$HQ" new "Status elsewhere" --no-focus | head -1)"
"$HQ" bind "$S6" --session "$SS5" >/dev/null; backdate "$S5C" 60
"$HQ" status "$S5" "$S6" --json | python3 -c '
import json,sys; a,b=json.load(sys.stdin)["tasks"]
assert a["flags"]==[] and a["sessions"]==[], a
assert [s["sessionId"] for s in b["sessions"]]==["'"$SS5"'"], b' && ok "status: a session since bound to another task counts there, not on its old card" || fail "status moved session"
rm -rf "$HOME/.claude/pet"

# hq jumps: the pet's jump log, last N days, by state x source.
mkdir -p "$HOME/.claude/pet"
NOW="$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
cat > "$HOME/.claude/pet/jumps.jsonl" <<EOF
{"at":"$NOW","session":"a","source":"board-card","state":"permission","peekedAgo":30}
{"at":"$NOW","session":"b","source":"pet-list","state":"replied"}
{"at":"$NOW","session":"b","source":"board-peek","state":"replied","peekedAgo":5000}
{"at":"2020-01-01T00:00:00Z","session":"old","source":"hotkey","state":"question"}
{"at":"$NOW","session":"odd","source":["x"],"state":7}
[1, 2]
not json
EOF
"$HQ" jumps --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["total"]==4 and r["grid"]["7"]=={"[\x27x\x27]":1} and r["grid"]["replied"]=={"pet-list":1,"board-peek":1} and r["peekedFirst"]=={"permission":1} and r["states"]==["permission","replied","7"], r' && ok "hq jumps counts the last week by state x source" || fail "hq jumps"
"$HQ" jumps | grep -q "^permission " && ok "hq jumps prints a table" || fail "hq jumps table"
rm "$HOME/.claude/pet/jumps.jsonl"; "$HQ" jumps | grep -q "no jumps" && ok "hq jumps without a log says so" || fail "hq jumps empty"

"$SRC/uninstall.sh" >/dev/null
grep -q 'hq/bin/hq hook' "$HOME/.claude/settings.json" && fail "uninstall left hooks" || ok "uninstall removes hooks, keeps others"
grep -q other-tool "$HOME/.claude/settings.json" && [ -d "$T/root/tasks/T-001-benchmark-vs-neo4j" ] && ok "uninstall keeps other hooks and data"
echo "$pass passed"
