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
# bin/hq is a thin entry; the code is in hqlib/ next to it, installed compiled.
L="$HOME/.claude/hq/hqlib"
# (compiled where this python keeps bytecode: macOS's own python3 keeps it under ~/Library/Caches)
[ -f "$L/hooks.py" ] && [ ! -L "$L" ] && [ ! -e "$L.new" ] && [ ! -e "$L.old" ] && python3 -c \
  'import importlib.util as u, os, sys; sys.exit(not os.path.exists(u.cache_from_source(sys.argv[1])))' "$L/hooks.py" \
  && ok "install copies hqlib next to bin/hq, compiled" || fail "install hqlib"
python3 - "$SRC/hqlib" <<'PY' && ok "no name defined twice in a module of hqlib, nor a function or class in two" || fail "duplicate definitions"
import ast, collections, glob, os, sys
where, bad = collections.defaultdict(list), []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.py"))):
    m, here = os.path.basename(f)[:-3], collections.Counter()
    for s in ast.parse(open(f, encoding="utf-8").read()).body:
        if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            here[s.name] += 1
            where[s.name].append(m)
        elif isinstance(s, (ast.Assign, ast.AnnAssign)):
            here.update(t.id for t in (s.targets if isinstance(s, ast.Assign) else [s.target]) if isinstance(t, ast.Name))
    bad += [f"{m}.{n}: defined {c} times" for n, c in here.items() if c > 1]
bad += [f"{n}: in {', '.join(ms)}" for n, ms in where.items() if len(ms) > 1]
assert not bad, "\n".join(bad)
PY
[ -f "$HOME/.claude/commands/task.md" ] && [ -f "$HOME/.claude/commands/hq-onboard.md" ] && [ -f "$T/root/CLAUDE.md" ] && [ -f "$T/root/hq.json" ] && ok "commands and root scaffolded"
echo n | "$SRC/install.sh" >/dev/null 2>&1 && fail "install without --yes on a pipe should refuse" || ok "install refuses without confirmation"
H2="$T/home2"; mkdir -p "$H2/.claude"; echo '{}' > "$H2/.claude/settings.json"
HOME="$H2" "$SRC/install.sh" --root "$T/root2" --yes --no-hooks --no-commands >/dev/null
grep -q hq "$H2/.claude/settings.json" && fail "--no-hooks touched settings" || ok "--no-hooks leaves settings.json alone"
[ ! -e "$H2/.claude/commands/task.md" ] && ok "--no-commands skips slash commands"
H3="$T/home3"; mkdir -p "$H3/.claude" "$H3/dotfiles"; echo '{"model":"m"}' > "$H3/dotfiles/settings.json"
ln -s ../dotfiles/settings.json "$H3/.claude/settings.json"
HOME="$H3" "$SRC/install.sh" --root "$T/root3" --yes --no-commands >/dev/null
[ -L "$H3/.claude/settings.json" ] && grep -q 'hq/bin/hq hook' "$H3/dotfiles/settings.json" \
  && ok "a symlinked settings.json stays a link; the hooks go into the file it points at" || fail "install through a symlink"
HOME="$H3" "$SRC/uninstall.sh" >/dev/null
[ -L "$H3/.claude/settings.json" ] && ! grep -q 'hq/bin/hq hook' "$H3/dotfiles/settings.json" && grep -q '"model"' "$H3/dotfiles/settings.json" \
  && ok "uninstall works through the link too" || fail "uninstall through a symlink"

out="$("$HQ" new "Benchmark vs Neo4j" --category benchmark --workdir "$T")"
TID="$(echo "$out" | head -1)"; [ "$TID" = "T-001" ] && ok "new task gets T-001"
"$HQ" new "Second" >/dev/null && [ -d "$T/root/tasks/T-002-second" ] && ok "ids increment"
# Categories are retired: a card gets one only when asked, and the list grows only then.
grep -q "^category: benchmark" "$T"/root/tasks/T-001-*/TASK.md && ok "--category still sets one" || fail "--category"
! grep -q "^category:" "$T"/root/tasks/T-002-second/TASK.md && ok "a new card has no category by default" || fail "default category"
grep -q '^title: "Second"' "$T"/root/tasks/T-002-second/TASK.md && grep -q "^status: active" "$T"/root/tasks/T-002-second/TASK.md && ok "the rest of the frontmatter is intact" || fail "frontmatter after dropping category"
"$HQ" board --json | python3 -c 'import json,sys; assert "categories" not in json.load(sys.stdin)' && ok "board --json has no categories" || fail "board json categories"

[ -z "$(hook '{"session_id":"s-unbound","hook_event_name":"SessionStart"}')" ] && ok "unbound session: hook is silent"

"$HQ" bind T-001 --session sess-1 | grep -q "bound to HQ task T-001" && ok "bind prints protocol"
grep -q '"sess-1"' "$T"/root/tasks/T-001-*/TASK.md && ok "bind records session on card"
mkdir -p "$T/repo-a"; (cd "$T/repo-a" && CLAUDE_CODE_SESSION_ID=sess-in "$HQ" bind T-002 >/dev/null)
grep -q "repo-a" "$T"/root/tasks/T-002-*/TASK.md && ok "bind from inside a session records its workdir"
(cd "$HOME" && CLAUDE_CODE_SESSION_ID=sess-home "$HQ" bind T-002 >/dev/null)
grep -q "\"$HOME\"" "$T"/root/tasks/T-002-*/TASK.md && fail "home dir recorded as workdir" || ok "home dir is never a workdir"
"$HQ" unbind --session sess-in >/dev/null; "$HQ" unbind --session sess-home >/dev/null
hook '{"session_id":"sess-1","hook_event_name":"SessionStart"}' | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert "hq-asks" in c' && ok "SessionStart injects protocol"
# A hook runs on every turn of every session: it loads no more of hq than it needs.
loaded() { echo "$1" | python3 -X importtime "$HQ" hook 2>&1 >/dev/null | sed -n 's/^import time: *[0-9]* *| *[0-9]* *| *//p' \
  | tr -d ' ' | grep -E '^(hqlib.*|argparse|subprocess|tempfile)$' | sort | tr '\n' ' '; }
got="$(loaded '{"session_id":"s-unbound","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
[ "$got" = "hqlib hqlib.core hqlib.hooks hqlib.sessions " ] && ok "an unbound session's hook loads only core and sessions" || fail "unbound hook loads: $got"
got="$(loaded '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
[ -n "$got" ] && [ -z "$(echo "$got" | tr ' ' '\n' | grep -v '^$' | grep -vxE 'hqlib(\.(core|sessions|hooks|cards|refs|history|projects|asks|protocol|update))?')" ] \
  && ok "a bound session's hook loads no command line, subprocess or unrelated module" || fail "bound hook loads: $got"

MSG='Done.\n\n```hq-asks\n- Approve plan v2?\n- Ask Chengjie for the dataset\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
[ "$("$HQ" asks T-001 | wc -l | tr -d ' ')" = 2 ] && ok "Stop hook records asks from hq-asks block"
"$HQ" asks T-001 --json | python3 -c 'import json,sys; a=json.load(sys.stdin)[0]; assert a["context"].startswith("Done.") and "hq-asks" not in a["context"], a' && ok "asks keep the reply that raised them"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["asks"][0]["context"].startswith("Done."), t["asks"]' && ok "board --json: an open ask comes with the reply that raised it" || fail "board json open ask context"

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

MSG2='ok\n```hq-resolved\n- T-001.2 archive: waiting on Chengjie\n```'
hook "{\"session_id\":\"sess-1\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG2\"}" >/dev/null
"$HQ" asks T-001 --all | grep -q "T-001.2.*\[archive: waiting on Chengjie\]" && ok "hq-resolved block resolves ask"
"$HQ" ask reopen T-001.2 && "$HQ" asks T-001 | grep -q "T-001.2" && ok "ask reopen undoes a resolution"
"$HQ" ask resolve T-001.2 archive --note "waiting on Chengjie"

printf '\n- [ ] @me review the plan\n- [ ] @claude draft the pilot\n' >> "$T"/root/tasks/T-001-*/TASK.md
"$HQ" todo T-001 1 done --via board
grep -q -- "- \[x\] @me review the plan" "$T"/root/tasks/T-001-*/TASK.md && ok "todo toggled"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; assert t["todos"][1]["owner"]=="claude"; assert len(t["asks"])==4' && ok "board --json exposes todos and asks"
"$HQ" board --json | python3 -c 'import json,sys; a=json.load(sys.stdin)["tasks"][0]["asks"]; assert all(x["state"]!="open" and "context" not in x for x in a), a' && "$HQ" asks T-001 --all --json | python3 -c 'import json,sys; a=json.load(sys.stdin); assert a[0]["context"].startswith("Done."), a' && ok "board --json leaves out answered asks' replies; hq asks --all still has them" || fail "board json answered ask context"
"$HQ" board --json | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][1]; assert t["refs"]==[] and isinstance(t["workdirs"], list), t' && ok "list fields with template comments parse as lists"

"$HQ" addtodo T-001 "@me ping Wenbing" && grep -A2 "draft the pilot" "$T"/root/tasks/T-001-*/TASK.md | grep -q "@me ping Wenbing" && ok "addtodo appends after last todo"
"$HQ" bind T-002 --session sess-2 >/dev/null
hook '{"session_id":"sess-2","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "bound this session to an HQ task from the board" && ok "board-side bind announced on next prompt"
hook '{"session_id":"sess-2","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "from the board" && fail "announced twice" || ok "announcement only once"
# status takes the board's column names too
st2() { grep "^status:" "$T"/root/tasks/T-002-*/TASK.md; }
was=$(st2)
"$HQ" set T-002 status=needs-you >/dev/null && [ "$(st2)" = "status: waiting-on-me" ] \
  && "$HQ" set T-002 status=Ready >/dev/null && [ "$(st2)" = "status: active" ] \
  && "$HQ" set T-002 status=BLOCKED >/dev/null && [ "$(st2)" = "status: blocked" ] \
  && "$HQ" set T-002 status=ready >/dev/null && ok "set status=needs-you / ready are waiting-on-me / active, any case" || fail "status aliases: $(st2)"
rc=0; "$HQ" set T-002 status=running 2>/dev/null || rc=$?; [ "$rc" = 1 ] && [ "$(st2)" = "status: active" ] && ok "Running is no status" || fail "status=running took"
"$HQ" set T-002 "status=${was#status: }" >/dev/null
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
# hq import: the plan /hq-onboard writes — duties and goals with PROJECT.md, task cards, sessions
IP="$T/import"; mkdir -p "$IP/repo" "$HOME/.claude/projects/-x-imp" "$HOME/.claude/pet/sessions"
touch "$HOME/.claude/projects/-x-imp/11112222-aaaa-bbbb-cccc-000000000001.jsonl" "$HOME/.claude/projects/-x-imp/33334444-aaaa-bbbb-cccc-000000000002.jsonl"
echo "{\"pid\": $$, \"sessionId\": \"11112222-aaaa-bbbb-cccc-000000000001\", \"cwd\": \"$IP/repo\"}" > "$HOME/.claude/pet/sessions/11112222-aaaa-bbbb-cccc-000000000001.json"
cat > "$IP/plan.json" <<EOF
{"projects": [
  {"name": "imp-goal", "kind": "goal", "title": "Rebaseline", "parent": "imp-duty", "due": "2030-01-31", "goal": "New baseline numbers"},
  {"name": "imp-duty", "kind": "duty", "title": "Perf", "goal": "Benchmarks and regressions", "brief": "Run perf on the lab box.", "paths": ["$IP/repo"]}],
 "tasks": [
  {"title": "Imp rebaseline LDBC", "project": "imp-goal", "status": "waiting-on-me", "next": "Review the diff",
   "state": ["Numbers collected"], "todos": ["@me review the diff"], "refs": ["PR #3 https://github.com/o/r/pull/3"],
   "sessions": ["11112222"], "confidence": "medium", "workdirs": ["$IP/repo"]},
  {"title": "Imp old fix", "project": "imp-duty", "status": "done", "sessions": ["33334444-aaaa-bbbb-cccc-000000000002"]}]}
EOF
n_before="$(ls "$T/root/tasks" | wc -l)"
"$HQ" import "$IP/plan.json" --dry-run | grep -q "imp-duty .*duty" && [ "$(ls "$T/root/tasks" | wc -l)" = "$n_before" ] \
  && ! "$HQ" project list | grep -q "^imp-" && ok "import --dry-run previews and writes nothing" || fail "import dry run"
python3 - "$IP/plan.json" "$IP/bad.json" <<'PY2'
import json, sys
p = json.load(open(sys.argv[1]))
p["projects"][0]["kind"] = "epic"
p["tasks"][1]["project"] = "nope"
p["tasks"][1]["sessions"] = ["99999999"]
json.dump(p, open(sys.argv[2], "w"))
PY2
rc=0; out="$("$HQ" import "$IP/bad.json")" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "kind is goal" && echo "$out" | grep -q "no project 'nope'" && echo "$out" | grep -q "99999999.*not a session" \
  && [ "$(ls "$T/root/tasks" | wc -l)" = "$n_before" ] && ! "$HQ" project list | grep -q "^imp-" && ok "import refuses a bad plan whole, naming every problem" || fail "import bad plan: $out"
"$HQ" import "$IP/plan.json" >/dev/null \
  && "$HQ" project list | grep -q "^imp-duty .*duty · active" && "$HQ" project list | grep -q "^imp-goal .*goal · active · due 2030-01-31" \
  && grep -q "^parent: imp-duty" "$T/root/projects/imp-goal/PROJECT.md" && grep -q "Run perf on the lab box." "$T/root/projects/imp-duty/PROJECT.md" \
  && grep -q "^## Healthy when" "$T/root/projects/imp-duty/PROJECT.md" && ok "import makes duties and goals with PROJECT.md (goal under its duty)" || fail "import projects"
C1="$(ls -d "$T"/root/tasks/*imp-rebaseline-ldbc)/TASK.md"; C2="$(ls -d "$T"/root/tasks/*imp-old-fix)/TASK.md"
grep -q "^status: waiting-on-me" "$C1" && grep -q '^next: "Review the diff"' "$C1" && grep -q "^Numbers collected" "$C1" \
  && grep -q -- "- \[ \] @me review the diff" "$C1" && grep -q "pull/3" "$C1" && grep -q "confidence medium" "$C1" \
  && grep -q "^status: done" "$C2" && ok "import writes each card's status, next, state, todos, links and an onboarding log line" || fail "import cards"
[ "$("$HQ" whoami --session 11112222-aaaa-bbbb-cccc-000000000001)" = "$(sed -n 's/^id: //p' "$C1")" ] && grep -q '^sessions: \["33334444"\]' "$C2" \
  && ok "import binds live sessions and records ended ones on the card" || fail "import sessions"
rc=0; out="$("$HQ" import "$IP/plan.json")" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "already exists" && echo "$out" | grep -q "33334444 is already on" && ok "importing the same plan again is refused" || fail "import rerun: $out"
cat > "$IP/review.json" <<EOF
{"projects": [{"name": "imp-d2", "kind": "duty", "done_when": ["CI green", "no P1 open"], "paths": ["$IP/repo/sub"]}],
 "tasks": [{"title": "Same"}, {"title": "same"}, {"title": "Odd", "next": ["a", "b"]}, {"title": "Guessed", "workdirs": ["$IP/repo/sub"]}]}
EOF
mkdir -p "$IP/repo/sub"
rc=0; out="$("$HQ" import "$IP/review.json" --dry-run)" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "another task in the plan" && echo "$out" | grep -q "\`next\` is a string" \
  && echo "$out" | grep -A1 "^  imp-d2" | grep -q "Guessed" && ok "import: duplicate titles in the plan and non-string values refused; a task's project guessed from its workdir shows in the preview" || fail "import review checks: $out"
python3 - "$IP/review.json" <<'PY2'
import json, sys
p = json.load(open(sys.argv[1])); p["tasks"] = [p["tasks"][0], p["tasks"][3]]
json.dump(p, open(sys.argv[1], "w"))
PY2
"$HQ" import "$IP/review.json" >/dev/null && grep -q "^- CI green" "$T/root/projects/imp-d2/PROJECT.md" && grep -q "^- no P1 open" "$T/root/projects/imp-d2/PROJECT.md" \
  && grep -q "^project: imp-d2" "$(ls -d "$T"/root/tasks/*-guessed)/TASK.md" && ok "import: done_when as a list becomes criteria; the guessed project is the one written" || fail "import done_when list / guessed project"
cp "$T/root/templates/TASK.md" "$IP/tpl.bak"; sed -i.x 's/^## Status$/## Where it stands/; s/^## 当前状态$/## 现状/' "$T/root/templates/TASK.md"
rc=0; out="$("$HQ" import - --dry-run <<< '{"tasks": [{"title": "Stateful", "state": ["half done"]}]}')" || rc=$?
cp "$IP/tpl.bak" "$T/root/templates/TASK.md"; rm -f "$T/root/templates/TASK.md.x"
[ "$rc" = 1 ] && echo "$out" | grep -q "task template" && ok "import: state lines refused up front when the task template has no Status section" || fail "import template check: $out"
rc=0; out="$("$HQ" import - --dry-run <<< '{"tasks": [{"title": "Ownerless", "todos": ["@me send the mail", "weekly tgkb update", "@Bob check"]}]}')" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "'weekly tgkb update' has no owner" && ! echo "$out" | grep -q "send the mail\|'@Bob check'" \
  && ok "import: a todo with no @owner is refused (it would show in nobody's list)" || fail "import todo owner: $out"
mkdir -p "$T/root/projects/Stale"; rc=0; out="$("$HQ" import - --dry-run <<< '{"projects": [{"name": "stale", "kind": "duty"}]}')" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "left from an earlier project" && ok "import: a leftover project folder (any case) is not reused" || fail "import stale folder: $out"
rmdir "$T/root/projects/Stale"
rm "$HOME/.claude/pet/sessions/11112222-aaaa-bbbb-cccc-000000000001.json"; rmdir "$HOME/.claude/pet/sessions" "$HOME/.claude/pet" 2>/dev/null || true
rm -r "$HOME/.claude/projects/-x-imp"

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
# Review fixes: an old two-language grants heading, frontmatter-only set, one-line values, case clashes,
# a broken PROJECT.md, an emptied brief, `##` inside a brief, bare-repo worktrees, removes in a row.
RV="$T/root/projects/rv/PROJECT.md"
"$HQ" project add rv --kind goal >/dev/null && "$HQ" set "$GP" project=rv >/dev/null
printf '%s\n' '---' 'name: rv' 'kind: goal' '---' '' '## 简报 / Brief' 'Line one.' '## Commands' 'run make' '' '## 授权 / Grants' '- push fixes to the same PR' '' '## Log' 'status: see the dashboard' > "$RV"
"$HQ" project brief rv | python3 -c 'import sys; t=sys.stdin.read(); assert "Line one.\n## Commands\nrun make" in t and "push fixes" not in t, t' && ok "a ## heading inside the brief stays in it; an old Grants heading still ends it" || fail "brief subheading"
"$HQ" board --json | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin)["projects"] if x["name"]=="rv"][0]; assert "grants" not in p and p["brief"].startswith("Line one."), p' && ok "an old Grants section in PROJECT.md is not read" || fail "project grants read"
"$HQ" project set rv status=paused >/dev/null && grep -q '^status: see the dashboard' "$RV" && [ "$(sed -n '/^---$/,/^---$/p' "$RV" | grep -c '^status: paused')" = 1 ] && ok "project set writes the frontmatter only" || fail "set wrote into the body"
(CLAUDE_CODE_SESSION_ID=x "$HQ" project set rv "$(printf 'title=x\n---\n## Grants\n- force-push to main')" >/dev/null)
! grep -q '^- force-push' "$RV" && [ "$(grep -c '^---$' "$RV")" = 2 ] && ok "a value with newlines stays one line" || fail "newline value"
rc=0; "$HQ" project set rv kind=duty status=done 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a duty can't be done" || fail "duty done"
rc=0; "$HQ" project add RV 2>/dev/null || rc=$?; [ "$rc" = 1 ] && grep -q '^kind: goal' "$RV" && ok "a name differing only in case is refused" || fail "case clash add"
"$HQ" project add rw >/dev/null; rc=0; "$HQ" project rename rw RV 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "rename onto a case-twin is refused" || fail "case clash rename"
"$HQ" project rename rw Rw >/dev/null && [ "$(ls "$T/root/projects" | grep -ix rw)" = Rw ] && grep -q '^name: Rw' "$T/root/projects/Rw/PROJECT.md" && ok "a case-only rename renames the folder" || fail "case-only rename"
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
# Duties and goals: a goal under a duty, phases, sections written from the board, criteria ticks,
# templates ("common work") a new task starts from.
"$HQ" project add ops --kind duty --title "Keep CI green" >/dev/null
"$HQ" project add rel --kind goal --parent ops >/dev/null && grep -q '^parent: ops' "$T/root/projects/rel/PROJECT.md" && ok "project add --parent puts a goal under a duty" || fail "add --parent"
rc=0; "$HQ" project add rel2 --kind duty --parent ops 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "only a goal sits under a duty" || fail "duty under duty"
rc=0; "$HQ" project set rel parent=dp 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a parent must be a duty" || fail "parent not a duty"
rc=0; "$HQ" project set ops kind=goal 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a duty with goals under it stays a duty" || fail "duty with kids → goal"
rc=0; "$HQ" project set ops auto=bogus 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "project set checks auto sources" || fail "auto bogus"
"$HQ" project set ops auto=qahub-ci,jira-filter >/dev/null && "$HQ" project set rel "phases=Design,Build,Ship" >/dev/null
"$HQ" project show rel --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["parent"]=="ops" and p["phases"]==["Design","Build","Ship"], p' \
  && "$HQ" project show ops --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["auto"]==["qahub-ci","jira-filter"], p' && ok "project show: parent, phases, auto" || fail "parent/phases/auto json"
"$HQ" project show rel | grep -q '^under: ops   phases: Design, Build, Ship' && ok "project show prints under and phases" || fail "show under/phases"
OPS="$T/root/projects/ops/PROJECT.md"
"$HQ" project section ops goal "Every nightly run is green or has an owner." >/dev/null
printf 'No perf runs\nNo customer tickets\n' | "$HQ" project section ops out >/dev/null
printf -- '- Nightly green 5 days in a row\n- No failure older than a day\n' | "$HQ" project section ops done_when >/dev/null
"$HQ" project show ops --json | python3 -c '
import json,sys; p=json.load(sys.stdin)
assert p["goal"]=="Every nightly run is green or has an owner." and p["out"]=="No perf runs\nNo customer tickets", p
assert [c["text"] for c in p["criteria"]]==["Nightly green 5 days in a row","No failure older than a day"] and not any(c["done"] for c in p["criteria"]), p' \
  && grep -q '^## Healthy when' "$OPS" && grep -q '^## Out of scope' "$OPS" && ok "project section writes goal, out and a duty's Healthy when" || fail "project section"
"$HQ" project section ops goal "Nightly runs stay green." >/dev/null && [ "$(grep -c '^## Goal' "$OPS")" = 1 ] && "$HQ" project show ops --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["goal"]=="Nightly runs stay green." and p["out"].startswith("No perf"), p' && ok "project section replaces a section in place" || fail "section replace"
awk '/^## /{print}' "$OPS" | python3 -c 'import sys; h=[l.strip() for l in sys.stdin]; assert h.index("## Goal")<h.index("## Out of scope")<h.index("## Healthy when")<h.index("## Brief"), h' && ok "new sections go in their order, before the brief" || fail "section order"
"$HQ" project check ops 2 >/dev/null && grep -q '^- \[x\] No failure older than a day' "$OPS" && grep -q 'ticked: No failure older than a day' "$OPS" && ok "project check ticks a criterion and logs it" || fail "project check"
"$HQ" project check ops 2 open >/dev/null && grep -q '^- \[ \] No failure older than a day' "$OPS" && ok "project check N open unticks it" || fail "project uncheck"
rc=0; "$HQ" project check ops 9 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "project check refuses a criterion that isn't there" || fail "check #9"
ZH="$T/root/projects/zhp/PROJECT.md"; "$HQ" project add zhp --kind goal >/dev/null
printf -- '---\nname: zhp\nkind: goal\n---\n\n## 目标\n发布 v2。\n不管：性能测试\n\n## 简报\n用 worktree。\n' > "$ZH"
"$HQ" project show zhp --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["goal"]=="发布 v2。" and p["out"]=="性能测试", p' && ok "a 不管： line of the goal reads as out of scope" || fail "out line"
"$HQ" project section zhp done_when "- 团队都在用" >/dev/null && grep -q '^## 完成标准' "$ZH" && ok "a section is made in the file's language" || fail "zh heading"
! grep -q '^不管' "$ZH" && grep -q '^## 不管' "$ZH" && "$HQ" project show zhp --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["goal"]=="发布 v2。" and p["out"]=="性能测试", p' && ok "a write moves the goal's 不管： lines into their own section" || fail "out migration"
printf -- '<!-- - 提示 -->\n- 团队都在用\n- 文档写好\n' | "$HQ" project section zhp done_when >/dev/null
"$HQ" project check zhp 1 >/dev/null && grep -q '^- \[x\] 团队都在用' "$ZH" && grep -q '^<!-- - 提示 -->' "$ZH" && ok "project check skips bullets inside comments" || fail "check counted a commented bullet"
grep -q '^## 决策记录' "$ZH" && "$HQ" project show zhp --json | python3 -c 'import json,sys; p=json.load(sys.stdin); assert [c["text"] for c in p["criteria"]]==["团队都在用","文档写好"], p["criteria"]' && ok "a log line on a PROJECT.md without a Log heading gets one, not a criterion" || fail "log without heading"
printf -- '---\nname: zhp\nkind: goal\n---\n\n## Goal\nShip v2.\n<https://example.com/v2>\n\n## Brief\nUse worktrees.\n## Templates\nOur own notes.\n\n## Scope\nAlso the docs.\n' > "$ZH"
"$HQ" project show zhp --json | python3 -c '
import json,sys; p=json.load(sys.stdin)
assert p["goal"]=="Ship v2.\n<https://example.com/v2>\n\nAlso the docs." and "## Templates\nOur own notes." in p["brief"] and not p["templates"], p' && ok "a link line stays; a ## Templates inside the brief is the brief's" || fail "brief cut by Templates"
"$HQ" project section zhp goal "Ship v2 and its docs." >/dev/null && [ "$(grep -c '^## \(Goal\|Scope\)' "$ZH")" = 1 ] && grep -q '^Our own notes.' "$ZH" && ok "writing the goal folds a second Scope heading into it" || fail "duplicate goal spans"
"$HQ" project section ops templates "$(printf '### triage\ntitle: Triage nightly {date}\ngoal: Every red job has an owner.\n- [ ] @claude collect the failures\n- [ ] @me assign owners\n\n### bump\ntitle: Bump the CI image')" >/dev/null
"$HQ" project show ops --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["templates"]
assert [x["name"] for x in t]==["triage","bump"] and t[0]["todos"]==["@claude collect the failures","@me assign owners"] and t[0]["goal"]=="Every red job has an owner.", t' && ok "templates read as name, title, goal, todos" || fail "templates json"
TT="$("$HQ" new --project ops --template Triage --no-focus | head -1)"; TC="$(ls "$T"/root/tasks/$TT-*/TASK.md)"
grep -q "^title: \"Triage nightly $(date +%F)\"" "$TC" && grep -q '^Every red job has an owner.' "$TC" && grep -q '^- \[ \] @me assign owners' "$TC" && grep -q '^project: ops' "$TC" && ok "hq new --template: title (date filled), goal, todos" || fail "new --template"
rc=0; "$HQ" new --project ops --template nope --no-focus 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "an unknown template is refused" || fail "unknown template"
rc=0; "$HQ" new --no-focus 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a task needs a title" || fail "new without title"
NG="$("$HQ" new "Cut the branch" --project rel --phase Build --goal "Branch cut and announced." --no-focus | head -1)"; NC="$(ls "$T"/root/tasks/$NG-*/TASK.md)"
grep -q '^phase: Build' "$NC" && grep -q '^Branch cut and announced.' "$NC" && "$HQ" board --json | python3 -c 'import json,sys; t=[x for x in json.load(sys.stdin)["tasks"] if x["id"]=="'"$NG"'"][0]; assert t["phase"]=="Build", t' && ok "hq new --phase --goal" || fail "new --phase --goal"
rc=0; "$HQ" project set ops kind= 2>/dev/null || rc=$?; [ "$rc" = 1 ] && ok "a duty with goals under it keeps its kind" || fail "kind= with goals under it"
"$HQ" project rename ops ops2 >/dev/null && grep -q '^parent: ops2' "$T/root/projects/rel/PROJECT.md" && ok "renaming a duty moves its goals along" || fail "reparent rename"
"$HQ" project remove ops2 --to "" >/dev/null && "$HQ" project show rel --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["parent"]=="", "parent kept"' && ok "removing a duty leaves its goals under nothing" || fail "reparent remove"
for x in "$TT" "$NG"; do "$HQ" set "$x" status=abandoned >/dev/null; done
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
hook '{"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"x"}' | grep -q '"decision"' && fail "guard looped" || ok "guard does not loop"

# hq-update: card bookkeeping written in the reply, applied by the Stop hook (no tool calls)
stop() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"Stop","last_assistant_message":sys.argv[2]}))' "$1" "$2" | "$HQ" hook; }
C1="$(ls "$T"/root/tasks/T-001-*/TASK.md)"
hook '{"session_id":"sess-1","hook_event_name":"SessionStart"}' | grep -q 'hq-update' && ok "protocol teaches the hq-update block"
out="$(stop sess-1 "$(printf 'Fixed it.\n\n```hq-update\nstatus: blocked\nnext: wait for the token\nstate: build is green\nstate: waiting on infra for the token\ntodo: @me send the token request\ntodo: @claude rerun the suite\nlog: picked plan v2 because it is cheaper\nref: PR #9 https://example.com/pr/9\nworkdir: %s\n```' "$T/repo-a")")"
! echo "$out" | grep -q '"decision"' && ok "a clean hq-update block does not block the turn" || fail "clean block blocked: $out"
echo "$out" | python3 -c 'import json,sys; m=json.load(sys.stdin)["systemMessage"]; assert m=="HQ T-001: status waiting-on-me → blocked, next, state, +2 todo, +1 log, +1 ref, +1 workdir", m' \
  && ok "the user is told in one line what the block wrote" || fail "echo of a clean block: $out"
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
python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"```hq-update\nstatus: nope\n```"}))' | "$HQ" hook | grep -q '"decision"' && fail "bad block looped" || ok "a bad block is not sent back twice"
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["sess-1"]["turn_start"] = time.time() - 600; json.dump(s, open(p, "w"))
PY
touch -t 200001010000 "$C1"
out="$(stop sess-1 "$(printf 'nothing new\n```hq-update\ntouch\n```')")"
! echo "$out" | grep -q '"decision"' && ok "a touch-only block satisfies the write-back guard" || fail "touch block: $out"

# A session that finishes its own task says so on its entry, for the board's "Finishing a task" setting.
fin() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("sess-1",{}).get("finished")))' "$HOME/.claude/hq/state/sessions.json"; }
[ "$(fin)" = null ] && ok "an open task leaves no finished mark" || fail "finished mark too early: $(fin)"
stop sess-1 "$(printf 'ok\n```hq-update\nstatus: nope\n```')" >/dev/null; stop sess-1 "$(printf 'ok\n```hq-update\nstatus: done\ndone: no such todo\n```')" >/dev/null
[ "$(fin)" = null ] && ok "a block that was not applied finishes nothing" || fail "finished by a rejected block: $(fin)"
stop sess-1 "$(printf 'All merged.\n```hq-update\nstatus: done\n```')" >/dev/null
fin | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["task"]=="T-001" and d["status"]=="done" and d["at"], d' && ok "status done in a session's own block marks the session as having finished its task" || fail "no finished mark: $(fin)"
first="$(fin)"; sleep 1
stop sess-1 "$(printf 'still done\n```hq-update\nstatus: done\nlog: tidy\n```')" >/dev/null
[ "$(fin)" = "$first" ] && ok "a task already done is not finished again" || fail "re-finished: $(fin)"
mkdir -p "$HOME/.claude/pet/sessions"; echo "{\"pid\": $$, \"sessionId\": \"sess-1\"}" > "$HOME/.claude/pet/sessions/sess-1.json"
"$HQ" sessions --json | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["sessionId"]=="sess-1"][0]; assert s["finished"]["status"]=="done" and s["task"]=="T-001", s' && ok "hq sessions --json carries the finished mark" || fail "sessions --json finished"
# Its last turn's reply, saved at Stop for the board's session row (the transcript is not here).
lr() { "$HQ" sessions --json | python3 -c 'import json,sys; print(json.dumps([x for x in json.load(sys.stdin) if x["sessionId"]=="sess-1"][0]["lastReply"]))'; }
lr | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["text"]=="still done" and r["ts"], r' && ok "hq sessions --json carries the reply its last turn ended on, without HQ blocks" || fail "lastReply: $(lr)"
stop sess-1 "$(printf '```hq-update\ntouch\n```')" >/dev/null
lr | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["text"]=="still done", r' && ok "a reply holding only HQ blocks keeps the one before it" || fail "lastReply bookkeeping: $(lr)"
echo "{\"pid\": $$, \"sessionId\": \"sess-1\", \"state\": \"busy\"}" > "$HOME/.claude/pet/sessions/sess-1.json"
lr | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["text"]=="still done" and r["prev"] is True, r' && ok "while a turn runs, the reply is the last turn's, marked prev" || fail "lastReply busy: $(lr)"
# A turn ended with Esc never reached the Stop hook: a newer reply in the transcript wins over the saved one.
esc_turn() { python3 - "$T/tr.jsonl" "$1" <<'PY'
import json, sys
row = lambda o: json.dumps(o)
y = sys.argv[2]
with open(sys.argv[1], "w") as f:
    f.write(row({"type": "user", "message": {"role": "user", "content": "go"}, "timestamp": f"{y}-01-01T00:00:00Z"}) + "\n")
    f.write(row({"type": "assistant", "message": {"model": "claude", "content": [{"type": "text", "text": "cut short"}]}, "timestamp": f"{y}-01-01T00:00:05Z"}) + "\n")
    f.write(row({"type": "user", "message": {"role": "user", "content": "next"}, "timestamp": f"{y}-01-01T00:00:09Z"}) + "\n")
PY
echo "{\"pid\": $$, \"sessionId\": \"sess-1\", \"state\": \"busy\", \"transcript\": \"$T/tr.jsonl\"}" > "$HOME/.claude/pet/sessions/sess-1.json"; }
esc_turn 2099; lr | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["text"]=="cut short" and r["prev"] is True, r' && ok "mid-turn, a reply newer than the saved one (an Esc-ended turn) wins" || fail "stale saved reply: $(lr)"
esc_turn 2001; lr | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["text"]=="still done", r' && ok "an older one in the transcript doesn't" || fail "older transcript reply won: $(lr)"
rm "$T/tr.jsonl"
rm "$HOME/.claude/pet/sessions/sess-1.json"; rmdir "$HOME/.claude/pet/sessions" "$HOME/.claude/pet" 2>/dev/null

# Peek shows the slash commands you ran (/compact before the line saying it compacted, as it ran),
# and a session's last reply skips Claude Code's stand-ins and, mid-turn, the turn going on.
python3 - "$HQ" <<'PY' && ok "slash commands in Peek; last_reply picks the finished turn's reply" || fail "commands / last_reply"
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
from hqlib import peek as hq
def u(text, ts, **kw): return {"type": "user", "message": {"role": "user", "content": text}, "timestamp": ts, **kw}
def a(text, ts, model="claude"): return {"type": "assistant", "message": {"model": model, "content": [{"type": "text", "text": text}]}, "timestamp": ts}
T = lambda s: f"2026-01-01T00:00:{s:02d}Z"
cmd = "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"
entries = [u("hi", T(1)), a("Hello.\n```hq-update\ntouch\n```", T(2)),
           {"type": "system", "subtype": "compact_boundary", "compactMetadata": {"trigger": "manual", "preTokens": 9, "postTokens": 1}, "timestamp": T(9)},
           u("summary", T(8), isCompactSummary=True), u(cmd, T(5)),
           u("<local-command-stdout>Compacted</local-command-stdout>", T(9)),
           u("<command-name>/task</command-name><command-args>T-108</command-args>", T(10)),
           u("skill body", T(10), isMeta=True), a("No response requested.", T(11), model="<synthetic>")]
items = hq.peek_timeline(entries)
kinds = [(i["kind"], i.get("text") or i.get("event")) for i in items]
assert kinds == [("msg", "hi"), ("msg", "Hello.\n```hq-update\ntouch\n```"), ("msg", "/compact"), ("event", "compact"), ("msg", "/task T-108"), ("msg", "No response requested.")], kinds
assert items[2]["command"] and items[4]["command"]
r = hq.last_reply(entries, False)
assert r["text"] == "Hello." and r["prev"] is False, r
busy = [u("do it", T(1)), a("Done: all of it.", T(2)), u("next", T(3)), a("Looking at the code…", T(4)),
        {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "also this", "origin": {"kind": "human"}}, "timestamp": T(5)}]
r = hq.last_reply(busy, True)
assert r["text"] == "Done: all of it." and r["prev"] is True, r
assert hq.last_reply(busy, False)["text"] == "Looking at the code…"
PY
stop sess-1 "$(printf 'reopened\n```hq-update\nstatus: blocked\n```')" >/dev/null
stop sess-1 "$(printf 'gave up\n```hq-update\nstatus: abandoned\n```')" >/dev/null
fin | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="abandoned", d' && ok "reopened and abandoned: a new finished mark" || fail "abandoned mark: $(fin)"
hook '{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"one more thing"}' >/dev/null
[ "$(fin)" = null ] && ok "a prompt after finishing takes the mark away (still being talked to)" || fail "mark kept after a prompt: $(fin)"
stop sess-1 "$(printf 'back\n```hq-update\nstatus: active\n```')" >/dev/null
stop sess-1 "$(printf 'ok\n```hq-update\nstatus: done\nnonsense line\n```')" >/dev/null
[ "$(fin)" = null ] && grep -q "^status: active" "$C1" && ok "a status change in a block with a bad line neither applies nor marks" || fail "mixed block: $(fin)"
python3 -c 'import json; print(json.dumps({"session_id":"sess-1","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"fixed\n```hq-update\nstatus: done\n```"}))' | "$HQ" hook >/dev/null
fin | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="done", d' && ok "the corrected block sent while another Stop hook held the turn still marks" || fail "stop_hook_active mark: $(fin)"
stop sess-1 "$(printf 'back\n```hq-update\nstatus: blocked\n```')" >/dev/null
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["sess-1"].pop("finished", None); json.dump(s, open(p, "w"))
PY

# A reply that closes its task with a question still open (the last "delete the old worktrees?")
# holds the close: closing would stop the session, and the answer would reach no one.
for a in $("$HQ" asks T-001 --json | python3 -c 'import json,sys; print(" ".join(a["id"] for a in json.load(sys.stdin) if a["state"]=="open"))'); do "$HQ" ask resolve "$a" drop >/dev/null; done
field() { python3 -c 'import re,sys; m=re.search(r"^"+sys.argv[2]+r":[ \t]*(.*)$", open(sys.argv[1]).read().split("\n---")[0], re.M); print(m.group(1) if m else "-")' "$C1" "$1"; }
openask() { "$HQ" asks T-001 --json | python3 -c 'import json,sys; print(" ".join(a["id"] for a in json.load(sys.stdin) if a["state"]=="open"))'; }
heldof() { python3 -c 'import json,sys; print(json.dumps((json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get("held")))' "$HOME/.claude/hq/state/sessions.json" "$1"; }
prompt() { hook "{\"session_id\":\"$1\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"go on\"}" >/dev/null; }
clearfin() { python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
for e in s.values():
    e.pop("finished", None); e.pop("held", None)
json.dump(s, open(p, "w"))
PY
}
stop sess-1 "$(printf 'All done.\n```hq-update\nstatus: done\nlog: wrapped up\n```\n\n```hq-asks\n- delete the old worktrees?\n```')" >/dev/null
Q="$(openask)"
[ -n "$Q" ] && [ "$(field status)" = waiting-on-me ] && [ "$(field closing)" = done ] && [ "$(fin)" = null ] && grep -q "wrapped up" "$C1" \
  && heldof sess-1 | python3 -c 'import json,sys; h=json.load(sys.stdin); assert h["task"]=="T-001" and h["status"]=="done" and h["at"], h' \
  && ok "status done with a question asked in the same reply: held — waiting on you, closing: done, a held mark, no finished mark" || fail "held close: $(field status) / $(field closing) / $(fin) / $(heldof sess-1)"
prompt sess-1; stop sess-1 "$(printf 'Waiting.\n```hq-update\nlog: still waiting\n```')" >/dev/null
[ "$(field status)" = waiting-on-me ] && [ "$(field closing)" = done ] && ok "a turn that answers nothing leaves the close held" || fail "held close released early: $(field status)"
# A Yes on the board while the session is on another turn: that turn's end must not close it.
prompt sess-1; "$HQ" ask resolve "$Q" do --via board >/dev/null
stop sess-1 "$(printf 'Other thing done.\n```hq-update\nlog: other thing\n```')" >/dev/null
[ "$(field status)" != done ] && [ "$(field closing)" = done ] && [ "$(fin)" = null ] \
  && ok "a Yes given during another turn (not yet delivered): that turn's end leaves the close held" || fail "released before delivery: $(field status) / $(fin)"
stop sess-2 "$(printf 'Unrelated.\n```hq-update\nlog: second session\n```')" >/dev/null
[ "$(field closing)" = done ] && ok "another session's turn never releases the close" || fail "released by another session: $(field status)"
"$HQ" ask delivered "$Q" --session sess-1 >/dev/null; sleep 1; prompt sess-1
stop sess-1 "$(printf 'Deleted them.\n```hq-update\nlog: deleted the worktrees\n```')" >/dev/null
[ "$(field status)" = done ] && [ "$(field closing)" = - ] && [ "$(heldof sess-1)" = null ] && fin | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="done"' \
  && grep -q "closed as the session said" "$C1" && ok "the turn that began with the Yes delivered closes the task and marks the session finished" || fail "release: $(field status) / $(field closing) / $(fin)"
# On a task that was already done, a reply saying done again with a question doesn't reopen it.
prompt sess-1; stop sess-1 "$(printf 'Still done.\n```hq-update\nstatus: done\n```\n```hq-asks\n- also prune the branches?\n```')" >/dev/null
[ "$(field status)" = done ] && [ "$(field closing)" = - ] && [ "$(heldof sess-1)" = null ] && ok "a closed task is never reopened to hold a close" || fail "reopened: $(field status) / $(field closing)"
"$HQ" ask resolve "$(openask)" drop >/dev/null; clearfin
# A No with the holding session gone closes it at once; a Yes still waiting for it does not.
stop sess-1 "$(printf 'back\n```hq-update\nstatus: active\n```')" >/dev/null
stop sess-1 "$(printf 'Gave up.\n```hq-update\nstatus: abandoned\n```\n```hq-asks\n- remove the cluster too?\n- and the bucket?\n```')" >/dev/null
set -- $(openask); "$HQ" ask resolve "$1" do --via board >/dev/null; "$HQ" ask resolve "$2" drop --via board >/dev/null
[ "$(field status)" != abandoned ] && [ "$(field closing)" = abandoned ] && ok "a No while a Yes is still to be acted on leaves the close held" || fail "closed over a Yes: $(field status)"
"$HQ" set T-001 status=active >/dev/null; clearfin
stop sess-1 "$(printf 'Gave up.\n```hq-update\nstatus: abandoned\n```\n```hq-asks\n- remove the cluster as well?\n```')" >/dev/null
"$HQ" ask resolve "$(openask)" drop --via board >/dev/null
[ "$(field status)" = abandoned ] && [ "$(field closing)" = - ] && [ "$(heldof sess-1)" = null ] && ok "a No with the holding session gone: the held close happens at once" || fail "drop release: $(field status) / $(field closing)"
stop sess-1 "$(printf 'back\n```hq-update\nstatus: active\n```')" >/dev/null
stop sess-1 "$(printf 'Done.\n```hq-update\nstatus: done\n```\n```hq-asks\n- send the summary?\n```')" >/dev/null
"$HQ" set T-001 status=blocked >/dev/null
[ "$(field status)" = blocked ] && [ "$(field closing)" = - ] && ok "a status set outright replaces a held close" || fail "set kept closing: $(field closing)"
"$HQ" ask resolve "$(openask)" drop >/dev/null; prompt sess-1; stop sess-1 "$(printf 'ok\n```hq-update\nlog: after the set\n```')" >/dev/null
[ "$(field status)" = blocked ] && [ "$(heldof sess-1)" = null ] && [ "$(fin)" = null ] && ok "and answering afterwards no longer closes it" || fail "closed after set: $(field status)"
out="$(stop sess-1 "$(printf 'Done.\n```hq-update\nstatus: done\nstatus: finished\n```\n```hq-asks\n- one more?\n```')")"
echo "$out" | grep -q "status must be one of" && [ "$(field status)" != done ] && ok "a bad status line is still reported while a close would be held" || fail "bad line hidden: $out"
"$HQ" ask resolve "$(openask)" drop >/dev/null; clearfin

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

# Closed todos carry when they were closed (their latest tick), so the board lists the latest first.
CT=$("$HQ" new "Close order" | sed -n 's#.*/\(T-[0-9]*\)-.*#\1#p')
"$HQ" addtodo "$CT" "first" >/dev/null; "$HQ" addtodo "$CT" "second" >/dev/null; "$HQ" addtodo "$CT" "third" >/dev/null
"$HQ" todo "$CT" 2 done >/dev/null; sleep 1.1; "$HQ" todo "$CT" 1 drop >/dev/null; sleep 1.1
"$HQ" todo "$CT" 3 done >/dev/null; "$HQ" todo "$CT" 3 open >/dev/null
"$HQ" board --json | python3 -c 'import json,sys; t=[x for x in json.load(sys.stdin)["tasks"] if x["id"]=="'"$CT"'"][0]
c={x["text"]: x.get("closed") for x in t["todos"]}
assert c["first"] and c["second"] and c["first"] > c["second"], c
assert c["third"] is None, c' && ok "board --json: a closed todo has its closing time; a reopened one none" || fail "todo closed times"
# Two todos with one text: reopening one takes back only its own close.
"$HQ" addtodo "$CT" "dup" >/dev/null; "$HQ" addtodo "$CT" "dup" >/dev/null
"$HQ" todo "$CT" 4 done --text dup >/dev/null; sleep 1.1; "$HQ" todo "$CT" 5 done --text dup >/dev/null; "$HQ" todo "$CT" 5 open --text dup >/dev/null
"$HQ" board --json | python3 -c 'import json,sys; t=[x for x in json.load(sys.stdin)["tasks"] if x["id"]=="'"$CT"'"][0]
d=[x for x in t["todos"] if x["text"]=="dup"]
assert d[0]["state"]=="done" and d[0]["closed"] and "+" in d[0]["closed"] or "-" in d[0]["closed"][19:], d
assert d[1]["state"]=="open" and d[1].get("closed") is None, d' && ok "todos sharing a text keep their own closing times, with an offset" || fail "dup todo closed times"
# A turn held open only by a background command that looks like a wait (the pet labels it
# "shell") runs for 20 minutes at most; one held by an agent runs as long as the agent does.
mkdir -p "$HOME/.claude/pet/sessions"
old=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
new=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
held() { echo "{\"pid\": $$, \"sessionId\": \"$1\", \"state\": \"busy\", \"phase\": \"awaiting-agent\", \"backgroundAgents\": $2, \"updatedAt\": \"$3\"}" > "$HOME/.claude/pet/sessions/$1.json"; }
held w-old '["shell"]' "$old"; held w-new '["shell"]' "$new"; held a-old '["shell", "auditor"]' "$old"
"$HQ" sessions --json | python3 -c 'import json,sys; s={x["sessionId"]: x for x in json.load(sys.stdin)}
assert s["w-old"]["state"]=="idle" and s["w-old"]["phase"]=="", s["w-old"]
assert s["w-new"]["state"]=="busy" and s["w-new"]["phase"]=="awaiting-agent", s["w-new"]
assert s["a-old"]["state"]=="busy", s["a-old"]' \
  && ok "a wait-only hold runs 20 minutes; an agent's runs until it reports" || fail "wait-only hold limit"
# Past the limit its reply is the turn's own, not the one before it.
python3 - "$T/held.jsonl" <<'PY'
import json, sys
rows = [("user", "go", "00"), ("assistant", "before", "01"), ("user", "again", "02"), ("assistant", "the turn's reply", "03")]
with open(sys.argv[1], "w") as f:
    for k, t, s in rows:
        c = t if k == "user" else [{"type": "text", "text": t}]
        f.write(json.dumps({"type": k, "message": {"role": k, "model": "claude", "content": c}, "timestamp": f"2026-01-01T00:00:{s}Z"}) + "\n")
PY
echo "{\"pid\": $$, \"sessionId\": \"w-old\", \"state\": \"busy\", \"phase\": \"awaiting-agent\", \"backgroundAgents\": [\"shell\"], \"updatedAt\": \"$old\", \"transcript\": \"$T/held.jsonl\"}" > "$HOME/.claude/pet/sessions/w-old.json"
"$HQ" sessions --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["sessionId"]=="w-old"][0]["lastReply"]
assert r["text"]=="the turn\x27s reply" and not r["prev"], r' && ok "past the limit, its last reply is its own turn's" || fail "held reply"
rm "$T/held.jsonl"
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

# Events between the messages: a compaction (its summary is not a message), and a Stop hook that
# sent the reply back (the reply after it holds only the corrected block).
ESID=feedface-4444-2222-3333-444455557777
printf '%s\n' \
  '{"type":"user","message":{"content":"go"},"timestamp":"2026-01-01T00:00:00Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2026-01-01T00:00:01Z"}' \
  '{"type":"attachment","attachment":{"type":"hook_blocking_error","hookName":"Stop","blockingError":{"blockingError":"HQ: block NOT applied\nfix it","command":"hq hook"}},"timestamp":"2026-01-01T00:00:02Z"}' \
  '{"type":"user","isMeta":true,"message":{"content":"Stop hook feedback:\nHQ: block NOT applied"},"timestamp":"2026-01-01T00:00:02Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"fixed block"}]},"timestamp":"2026-01-01T00:00:03Z"}' \
  '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":200000,"postTokens":15000},"timestamp":"2026-01-01T00:00:05Z"}' \
  '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued"},"timestamp":"2026-01-01T00:00:05Z"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"carrying on"}]},"timestamp":"2026-01-01T00:00:06Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$ESID.jsonl"
"$HQ" peek "$ESID" --json --meta | python3 -c '
import json,sys; d=json.load(sys.stdin)
got=[(i["kind"], i.get("event") or i.get("text")) for i in d["items"]]
assert got==[("msg","go"),("msg","done"),("event","hook"),("msg","fixed block"),("event","compact"),("msg","carrying on")], got
h,c=d["items"][2],d["items"][4]
assert h["hook"]=="Stop" and h["text"].startswith("HQ: block NOT applied"), h
assert c["trigger"]=="auto" and c["pre"]==200000 and c["post"]==15000, c
assert [m["text"] for m in d["messages"]]==["go","done","fixed block","carrying on"], d["messages"]
' && ok "peek --meta: a compaction and a hook's send-back are events between the messages" || fail "peek --meta compact / hook events"

# Claude Code's queue, from its queue-operation lines, matched by text: an entry leaves when a
# remove or a user entry (prompt, queued_command, meta) holds its text — not by replaying dequeues
# as a FIFO, which one stale entry (here: an empty enqueue, a notification queued twice) would
# throw off. One still there after a turn ended and another prompt began is stale.
QSID=feedface-5555-2222-3333-444455556666
printf '%s\n' \
  '{"type":"user","message":{"content":"go"},"timestamp":"2026-01-01T00:00:00Z"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:01Z"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:01Z","content":"<task-notification><task-id>x</task-id></task-notification>"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:01Z","content":"<task-notification><task-id>x</task-id></task-notification>"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:02Z","content":"!aws sso login"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:03Z","content":"first"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:04Z","content":"second"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:05Z","content":"third"}' \
  '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:06Z","content":[{"type":"text","text":"fourth"}]}' \
  '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-01-01T00:00:07Z"}' \
  '{"type":"queue-operation","operation":"remove","timestamp":"2026-01-01T00:00:08Z","content":"third"}' \
  '{"type":"attachment","attachment":{"type":"queued_command","prompt":"second"},"timestamp":"2026-01-01T00:00:09Z"}' \
  > "$HOME/.claude/projects/-tmp-repo/$QSID.jsonl"
queued() { "$HQ" peek "$QSID" --json --meta | python3 -c 'import json,sys; print(json.dumps([x["text"] for x in json.load(sys.stdin)["queued"]]))'; }
[ "$(queued)" = '["!aws sso login", "first", "fourth"]' ] \
  && ok "peek --meta: queued lists what waits in Claude Code's queue, oldest first, matched by text" || fail "peek --meta queued: $(queued)"
printf '%s\n' \
  '{"type":"system","subtype":"turn_duration","durationMs":9000,"timestamp":"2026-01-01T00:00:10Z"}' \
  '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-01-01T00:00:11Z"}' \
  '{"type":"user","message":{"content":"first"},"timestamp":"2026-01-01T00:00:11Z"}' \
  >> "$HOME/.claude/projects/-tmp-repo/$QSID.jsonl"
[ "$(queued)" = '["!aws sso login", "fourth"]' ] && ok "...a message leaves when it comes in as the next prompt" || fail "queued after prompt: $(queued)"
printf '%s\n' \
  '{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>ran a command</local-command-caveat>"},"timestamp":"2026-01-01T00:00:12Z"}' \
  >> "$HOME/.claude/projects/-tmp-repo/$QSID.jsonl"
[ "$(queued)" = '[]' ] && ok "...and what a turn's end and another prompt left behind is stale" || fail "queued stale: $(queued)"

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
  '{"type":"attachment","attachment":{"type":"skill_listing","content":"- late: Turned up later","names":["late"],"isInitial":false}}' \
  '{"type":"attachment","attachment":{"type":"skill_listing","content":"- review: Review the diff, now with tests","names":["review"],"isInitial":false}}' \
  > "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl"
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["found"] and d["skills"]==[{"name":"review","desc":"Review the diff, now with tests"},{"name":"hud:setup","desc":"Configure: the HUD"},{"name":"hud","desc":"The bare plugin"},{"name":"late","desc":"Turned up later"}], d
' && ok "peek --commands: the newest full listing plus later additions and changes, plugin names with colons" || fail "peek --commands listing"
"$HQ" peek "$KSID" --commands | head -1 | grep -qx "/review  Review the diff, now with tests" && ok "peek --commands prints /name  description lines" || fail "peek --commands text"
# Skills marked disable-model-invocation are left out of the listing but can still be typed: read
# from ~/.claude, the project's .claude (and the folders above it) and enabled plugins.
KP="$T/kproj/sub"; mkdir -p "$KP/.claude/commands" "$T/kproj/.claude/skills/up" "$HOME/.claude/skills/grill-me" "$HOME/.claude/skills/shown" "$HOME/.claude/skills/review" "$HOME/.claude/skills/nouser" "$HOME/.claude/commands" "$T/kplug/skills/ship" "$T/kplug/commands" "$T/koff/skills/off"
printf -- '---\nname: grill-me\ndescription: "A relentless interview"\ndisable-model-invocation: true\n---\nbody\n' > "$HOME/.claude/skills/grill-me/SKILL.md"
printf -- '---\ndescription: Callable, so already listed\n---\n' > "$HOME/.claude/skills/shown/SKILL.md"
printf -- '---\ndescription: Same name as a listed one\ndisable-model-invocation: true\n---\n' > "$HOME/.claude/skills/review/SKILL.md"
printf -- '---\ndescription: Hidden from you too\ndisable-model-invocation: true\nuser-invocable: false\n---\n' > "$HOME/.claude/skills/nouser/SKILL.md"
printf -- '---\ndescription: A user command\ndisable-model-invocation: true\n---\n' > "$HOME/.claude/commands/deploy.md"
printf -- '---\ndescription: From the project\ndisable-model-invocation: true\n---\n' > "$KP/.claude/commands/proj.md"
printf -- '---\ndescription: From the folder above\ndisable-model-invocation: true\n---\n' > "$T/kproj/.claude/skills/up/SKILL.md"
printf -- '---\ndescription: Ship it\ndisable-model-invocation: true\n---\n' > "$T/kplug/skills/ship/SKILL.md"
printf -- '---\ndescription: Plugin command\ndisable-model-invocation: true\n---\n' > "$T/kplug/commands/tidy.md"
printf -- '---\ndescription: Plugin is off\ndisable-model-invocation: true\n---\n' > "$T/koff/skills/off/SKILL.md"
cp "$HOME/.claude/settings.json" "$T/ksettings.bak" 2>/dev/null || echo '{}' > "$T/ksettings.bak"
python3 - "$HOME" "$T" <<'PY'
import json, os, sys
home, t = sys.argv[1:]
p = os.path.join(home, ".claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d["enabledPlugins"] = {"kp@m": True, "koff@m": False}
json.dump(d, open(p, "w"))
os.makedirs(os.path.join(home, ".claude/plugins"), exist_ok=True)
json.dump({"plugins": {"kp@m": [{"installPath": t + "/kplug"}], "koff@m": [{"installPath": t + "/koff"}]}},
          open(os.path.join(home, ".claude/plugins/installed_plugins.json"), "w"))
PY
sed -i '' "1s|^|{\"type\":\"user\",\"cwd\":\"$KP\",\"message\":{\"content\":\"hi\"}}\n|" "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl" 2>/dev/null \
  || sed -i "1s|^|{\"type\":\"user\",\"cwd\":\"$KP\",\"message\":{\"content\":\"hi\"}}\n|" "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl"
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin); names=[x["name"] for x in d["skills"]]
assert names[:4]==["review","hud:setup","hud","late"], names
assert names[4:]==["grill-me","deploy","proj","up","kp:ship","kp:tidy"], names
assert d["skills"][4]=={"name":"grill-me","desc":"A relentless interview"} and d["skills"][0]["desc"]=="Review the diff, now with tests", d
' && ok "peek --commands: adds skills and commands hidden from Claude (user, project and folders above, enabled plugins), once each" || fail "peek --commands hidden skills"
# The way Claude Code reads them: yes/on/1 count, no does not, a `>` description spans its
# indented lines, a BOM is fine; the project's settings can turn a plugin off, and a plugin
# installed for one project counts only there.
mkdir -p "$HOME/.claude/skills/yes" "$HOME/.claude/skills/no" "$HOME/.claude/skills/bom" "$T/kpp/skills/pp" "$T/kpx/skills/px" "$T/kpre/skills/kpre:dup"
printf -- '---\ndisable-model-invocation: Yes\ndescription: >\n  Folded over\n  two lines\nother: x\n---\n' > "$HOME/.claude/skills/yes/SKILL.md"
printf -- '---\ndescription: Not hidden\ndisable-model-invocation: no\n---\n' > "$HOME/.claude/skills/no/SKILL.md"
printf -- '\xef\xbb\xbf---\ndescription: Has a BOM\ndisable-model-invocation: on\n---\n' > "$HOME/.claude/skills/bom/SKILL.md"
printf -- '---\ndescription: For this project\ndisable-model-invocation: 1\n---\n' > "$T/kpp/skills/pp/SKILL.md"
printf -- '---\ndescription: For another project\ndisable-model-invocation: true\n---\n' > "$T/kpx/skills/px/SKILL.md"
printf -- '---\nname: kpre:dup\ndescription: Already prefixed\ndisable-model-invocation: true\n---\n' > "$T/kpre/skills/kpre:dup/SKILL.md"
echo '{"enabledPlugins":{"kp@m":false}}' > "$KP/.claude/settings.local.json"
echo '{"enabledPlugins":{"kpp@m":true,"kpx@m":true,"kpre@m":true}}' > "$T/kproj/.claude/settings.json"
python3 - "$HOME" "$T" <<'PY'
import json, os, sys
home, t = sys.argv[1:]
p = os.path.join(home, ".claude/plugins/installed_plugins.json")
d = json.load(open(p))
d["plugins"]["kpp@m"] = [{"scope": "project", "projectPath": t + "/kproj", "installPath": t + "/kpp"}]
d["plugins"]["kpx@m"] = [{"scope": "project", "projectPath": t + "/elsewhere", "installPath": t + "/kpx"}]
d["plugins"]["kpre@m"] = [{"scope": "user", "installPath": t + "/kpre"}]
json.dump(d, open(p, "w"))
PY
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin); s={x["name"]:x["desc"] for x in d["skills"]}
assert s.get("yes")=="Folded over two lines" and s.get("bom")=="Has a BOM" and "no" not in s, s
assert "kp:ship" not in s and s.get("kpp:pp")=="For this project" and "kpx:px" not in s, s
assert s.get("kpre:dup")=="Already prefixed" and "kpre:kpre:dup" not in s, s
' && ok "peek --commands: yes/on/1 flags, folded descriptions, a BOM; project settings and project installs" || fail "peek --commands hidden skill details"
# A broken settings file or a folder it can't read leaves the rest of the list standing.
echo '[1,2]' > "$HOME/.claude/plugins/installed_plugins.json"; echo '"x"' > "$T/kproj/.claude/settings.json"
chmod 000 "$HOME/.claude/commands"
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin); names=[x["name"] for x in d["skills"]]
assert names[:4]==["review","hud:setup","hud","late"] and "grill-me" in names and not any(":" in n and n.split(":")[0] in ("kp","kpp","kpre") for n in names), names
' && ok "peek --commands: malformed settings and an unreadable folder don't break the list" || fail "peek --commands malformed settings"
chmod 755 "$HOME/.claude/commands"
# Folders above your home are not a project's: a session started under it reads none of them.
mkdir -p "$T/.claude/commands" "$HOME/work"
printf -- '---\ndescription: Above home\ndisable-model-invocation: true\n---\n' > "$T/.claude/commands/above.md"
sed -i '' "1s|\"cwd\":\"[^\"]*\"|\"cwd\":\"$HOME/work\"|" "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl" 2>/dev/null \
  || sed -i "1s|\"cwd\":\"[^\"]*\"|\"cwd\":\"$HOME/work\"|" "$HOME/.claude/projects/-tmp-repo/$KSID.jsonl"
"$HQ" peek "$KSID" --commands --json | python3 -c '
import json,sys; d=json.load(sys.stdin); names=[x["name"] for x in d["skills"]]
assert "grill-me" in names and "above" not in names and "proj" not in names, names
' && ok "peek --commands: stops at your home, never reads the folders above it" || fail "peek --commands above home"
rm -rf "$T/.claude" "$HOME/work"
rm -rf "$HOME/.claude/skills" "$HOME/.claude/commands/deploy.md" "$HOME/.claude/plugins/installed_plugins.json"; mv "$T/ksettings.bak" "$HOME/.claude/settings.json"
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
for no in ("finished thing", "dropped thing", "send the dataset", "<!--t:"):
    assert no not in c, no
assert "Open @me todos on '"$CT"' (1)" in c and "- review the PR" in lines, c
assert c.index("Open @me todos") < c.index("Open @claude todos"), c
assert "done: <text>" in c and "drop: <text>" in c' && ok "SessionStart lists the open @me and @claude todos, text exactly as on the card" || fail "SessionStart todo list: $c"
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

# The user's todos: a new @me todo that repeats an open one is refused with the open one's text,
# `change:` rewrites one in place (same spot, owner and creation time), `todo!:` adds one anyway.
MT="$("$HQ" new "me todos" | head -1)"; MC="$(ls "$T"/root/tasks/$MT-*/TASK.md)"
printf '\n## 待办\n- [ ] @me review 并合并 #127、#129 <!--t:2026-11-22T08:00:00+08:00-->\n- [ ] @me 合并后从 main 运行 scripts/install.sh\n- [ ] @me review 并合并 PR #110\n' >> "$MC"
"$HQ" bind "$MT" --session sess-me >/dev/null
# What the turn was sent back with, if anything (the echo to the user aside).
upd() { stop sess-me "$(printf 'ok\n```hq-update\n%s\n```' "$1")" | python3 -c '
import json, sys
t = sys.stdin.read().strip(); d = json.loads(t) if t else {}; d.pop("systemMessage", None)
print(json.dumps(d, ensure_ascii=False) if d else "")'; }
o="$(upd 'todo: @me review 并合并 #126、#127、#129')"
echo "$o" | grep -q 'repeats the open todo \\"review 并合并 #127、#129\\"' && echo "$o" | grep -q "change: review 并合并 #127、#129 => " && echo "$o" | grep -q 'todo!: @me' \
  && ! grep -q "#126" "$MC" && ok "an @me todo about a PR an open one merges is refused, naming the open one" || fail "PR repeat not refused: $o"
o="$(upd 'todo: @me 三个 PR 合并后从 main 跑 scripts/install.sh，再跑 hq/install.sh --yes')"
echo "$o" | grep -q "installing from main" && ! grep -q "三个 PR" "$MC" && ok "a second install-from-main todo is refused" || fail "install repeat not refused: $o"
o="$(upd 'todo: @me review 并合并 PR #111')"
[ -z "$o" ] && grep -q -- "- \[ \] @me review 并合并 PR #111" "$MC" && ok "another PR with the same words is a todo of its own" || fail "#111 refused: $o"
o="$(upd "$(printf 'todo: @me review 并合并 PR #111\ntodo: @claude review 并合并 #127 的 review 修复')")"
[ -z "$o" ] && [ "$(grep -c "review 并合并 PR #111" "$MC")" = 1 ] && grep -q "@claude review 并合并 #127 的" "$MC" && ok "the same text again is skipped, and @claude todos are not checked" || fail "exact repeat / claude: $o"
o="$(upd 'change: review 并合并 #127、#129 => review 并合并 #126、#127、#129')"
python3 - "$MC" "$o" <<'PY' && ok "change: rewrites the todo in place, keeping its owner and creation time" || fail "change: $o"
import sys, re
s = open(sys.argv[1], encoding="utf-8").read(); assert not sys.argv[2], sys.argv[2]
todos = re.findall(r"^- \[.\] .*$", s, re.M)
assert todos[0] == "- [ ] @me review 并合并 #126、#127、#129 <!--t:2026-11-22T08:00:00+08:00-->", todos
assert "#127、#129 " not in s.replace("#126、#127、#129", ""), s
PY
grep -q "→ changed (session): @me review 并合并 #127、#129 ⇒ @me review 并合并 #126、#127、#129" "$(dirname "$MC")/HISTORY.md" && ok "the change is in HISTORY.md" || fail "no change tick in HISTORY.md"
o="$(upd 'change: review 并合并 #127、#129 => review 并合并 #126、#127、#129')"
[ -z "$o" ] && [ "$(grep -c "#126、#127、#129" "$MC")" = 1 ] && ok "the same change again does nothing" || fail "repeated change: $o"
o="$(upd 'change: review 并合并 #126、#127、#129 to something')"
echo "$o" | grep -q "write it as \`change: <text of an open todo> => <its new text>\`" && ok "a change without => says how to write it" || fail "bad change: $o"
o="$(upd "$(printf 'done: 合并后从 main 运行 scripts/install.sh\ntodo: @me 从 main 安装（scripts/install.sh 和 hq/install.sh --yes）')")"
[ -z "$o" ] && grep -q -- "- \[x\] @me 合并后从 main" "$MC" && grep -q -- "- \[ \] @me 从 main 安装" "$MC" && ok "closing the old one in the same block lets the new one in" || fail "done + todo: $o"
o="$(upd 'change: 合并后从 main 运行 scripts/install.sh => 再装一次')"
echo "$o" | grep -q "already closed" && ok "a closed todo can't be changed" || fail "changed a closed todo: $o"
o="$(upd "$(printf 'change: review 并合并 PR #110 => review 并合并 PR #110、#112\ndone: review 并合并 PR #110')")"
echo "$o" | grep -q "also changed in this block\|already ticked, dropped or changed" && ok "a todo can't be changed and ticked in one block" || fail "change + done: $o"
o="$(upd 'todo!: @me review 并合并 #129，在手机上点一遍')"
[ -z "$o" ] && grep -q "@me review 并合并 #129，在手机上点一遍" "$MC" && ok "todo!: adds a todo that looks like a repeat" || fail "todo!: $o"
"$HQ" addtodo "$MT" "@me review 并合并 PR #110 again" && grep -q "PR #110 again" "$MC" && ok "hq addtodo is not checked for repeats" || fail "addtodo refused"
"$HQ" addtodo "$MT" "@me map a => b in the table" >/dev/null
o="$(upd 'change: map a => b in the table => map a => c in the table')"
[ -z "$o" ] && grep -q -- "- \[ \] @me map a => c in the table" "$MC" && ok "change: finds the split whose old text is an open todo, arrows in the text and all" || fail "arrow in text: $o"
"$HQ" addtodo "$MT" "@me Deploy the fix" >/dev/null
upd 'change: Deploy the fix => deploy the fix' >/dev/null; o="$(upd 'change: Deploy the fix => deploy the fix')"
[ -z "$o" ] && [ "$(grep -c "Deploy the fix ⇒ @me deploy the fix" "$(dirname "$MC")/HISTORY.md")" = 1 ] && ok "a case-only change sent twice is written once" || fail "case change repeated: $o"
upd 'change: @me deploy the fix => @claude deploy the fix' >/dev/null; o="$(upd 'change: @me deploy the fix => @claude deploy the fix')"
[ -z "$o" ] && grep -q -- "- \[ \] @claude deploy the fix" "$MC" && ok "an owner change sent again does nothing" || fail "owner change repeated: $o"
upd 'done: @claude deploy the fix' >/dev/null; o="$(upd 'change: @me deploy the fix => @claude deploy the fix')"
[ -z "$o" ] && ok "a change whose new todo has closed since does nothing" || fail "change after close: $o"
o="$(upd 'change: map a => c in the table => <its new text>')"
echo "$o" | grep -q "placeholder" && ! grep -q "<its new text>" "$MC" && ok "a change to the template's placeholder is refused" || fail "placeholder change: $o"
o="$(upd 'change: map a => c in the table => review 并合并 PR #111')"
echo "$o" | grep -q 'is the open todo \\"review 并合并 PR #111\\" already' && ok "a change into another open todo's text is refused" || fail "change into twin: $o"
o="$(upd 'todo！: @me 全角感叹号也认')"
[ -z "$o" ] && grep -q "全角感叹号也认" "$MC" && ok "todo！: with a full-width mark works" || fail "full-width todo!: $o"
python3 - "$HQ" "$MC" <<'PY' && ok "a changed todo is not a report note" || fail "changed tick in the report"
import os, sys, json, datetime as dt
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
from hqlib import reports as hq
a = hq.task_activity(hq.parse_card(sys.argv[2]), dt.datetime(2000, 1, 1), dt.datetime(2100, 1, 1))
s = json.dumps(a, ensure_ascii=False)
assert "deploy the fix" in s and "→ changed" not in s, s[:600]
PY
"$HQ" unbind --session sess-me >/dev/null

# Refs are keyed by the thing a link points to: a PR's /files or /commits is the PR, a Jira board
# page the issue, a Jenkins console or test report the build. A link to one comment, and any other
# #fragment, stays its own. hq and board.js agree.
python3 - "$HQ" <<'PY' && ok "canonical keys for GitHub, Jira, Jenkins, Confluence and other URLs" || fail "canonical keys"
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
from hqlib import refs as hq
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
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
from hqlib import refs as hq
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
LH="$(dirname "$LC")/HISTORY.md"
[ "$(lrefs)" = "[\"PR #9 (merged) $GHP/9\"]" ] && grep -qx -- "- PR #9 verification comment $GHP/9#issuecomment-1" "$LH" \
  && ok "a link to one comment is a process link: its own entry, in HISTORY.md" || fail "comment: $(lrefs) / $(cat "$LH" 2>/dev/null)"
"$HQ" ref add "$LT" "comment https://jira.example.com/browse/QA-1?focusedCommentId=7#comment-7" && [ "$(lrefs)" = "[\"PR #9 (merged) $GHP/9\"]" ] \
  && grep -qx -- "- comment https://jira.example.com/browse/QA-1?focusedCommentId=7#comment-7" "$LH" && ok "hq ref add keeps a lone link exactly as written (a Jira comment goes to history)" || fail "ref add rewrote a lone link: $(lrefs) / $(cat "$LH")"
python3 - "$LC" "$GHP" <<'PY'
import re, sys
p, g = sys.argv[1], sys.argv[2]; s = open(p, encoding="utf-8").read()
refs = f'["pr {g}/7/", "QA-2", "files {g}/7/files", "PR #9 {g}/9"]'
s = re.sub(r"^refs: .*$", lambda m: "refs: " + refs, s, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY
out="$("$HQ" ref remove "$LT" "$GHP/7/commits")"
[ "$out" = "{\"removed\": [{\"i\": 0, \"ref\": \"pr $GHP/7/\"}, {\"i\": 2, \"ref\": \"files $GHP/7/files\"}]}" ] && [ "$(lrefs)" = "[\"QA-2\", \"PR #9 $GHP/9\"]" ] && ok "ref remove by any view of a PR removes every entry for it" || fail "remove canonical: $out / $(lrefs)"
"$HQ" ref restore "$LT" "$out" && [ "$(lrefs)" = "[\"pr $GHP/7/\", \"QA-2\", \"files $GHP/7/files\", \"PR #9 $GHP/9\"]" ] && ok "ref restore puts the variants back as they were" || fail "restore canonical: $(lrefs)"
"$HQ" ref restore "$LT" "$out" && [ "$(lrefs)" = "[\"pr $GHP/7/\", \"QA-2\", \"files $GHP/7/files\", \"PR #9 $GHP/9\"]" ] && ok "and restoring twice adds nothing" || fail "second restore: $(lrefs)"
"$HQ" unbind --session sess-links >/dev/null

# Today's order: hq focus order puts the named tasks first, in that order; the rest keep theirs.
"$HQ" focus add T-001 T-002 "$PID" >/dev/null
"$HQ" focus order "$PID" T-001 >/dev/null
"$HQ" focus --json | python3 -c 'import json,sys; ids=json.load(sys.stdin)["ids"]; assert ids[:3]==["'"$PID"'","T-001","T-002"], ids' && ok "Focus can be reordered"
"$HQ" focus order T-001 T-001 >/dev/null; "$HQ" focus --json | python3 -c 'import json,sys; ids=json.load(sys.stdin)["ids"]; assert len(ids)==len(set(ids)), ids' && ok "focus order drops repeated ids" || fail "focus order kept a repeated id"

# Standing grants are retired. What they left behind still works: an ask a session ends with
# [grant: …] / [授权：…], an old card's ## 授权 section, a session entry that kept grants.
GT="$("$HQ" new "Leftovers" | head -1)"
GC="$(ls "$T"/root/tasks/$GT-*/TASK.md)"
"$HQ" bind "$GT" --session sess-g >/dev/null
c="$(hook '{"session_id":"sess-g","hook_event_name":"SessionStart"}')"
grep -qi 'grant' <<<"$c" && fail "SessionStart still mentions grants: $c" || ok "the protocol no longer teaches [grant: …]"
MSG='Ran it.\n\n```hq-asks\n- Rerun #31388 with the same parameters? [grant: rerun a verification with the same parameters]\n- 删掉测试集群？[授权：删测试集群]\n```'
hook "{\"session_id\":\"sess-g\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
"$HQ" asks "$GT" --json | python3 -c 'import json,sys; a=json.load(sys.stdin); assert [x["text"] for x in a]==["Rerun #31388 with the same parameters?", "删掉测试集群？"] and not any("grant" in x for x in a), a' \
  && ok "an old [grant: …] / [授权：…] suffix is dropped from the ask" || fail "grant suffix kept"
"$HQ" grant list "$GT" >/dev/null 2>&1 && fail "hq grant still runs" || ok "hq grant is gone"
"$HQ" ask resolve "$GT.1" do --grant "x" --via board >/dev/null 2>&1 && fail "ask resolve took --grant" || ok "ask resolve has no --grant"
python3 - "$GC" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("\n## Todo\n", "\n## 授权\n- push review fixes to the same PR <!--g:2026-11-23T11:26:04+08:00 T-078.2-->\n\n## Todo\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
"$HQ" addtodo "$GT" "@claude after the old section" >/dev/null; "$HQ" log "$GT" "a note" >/dev/null
"$HQ" board --json | python3 -c "import json,sys; t=[x for x in json.load(sys.stdin)['tasks'] if x['id']=='$GT'][0]; assert 'grants' not in t and [x['text'] for x in t['todos']]==['after the old section'], t" \
  && grep -q "^- push review fixes to the same PR <!--g:" "$GC" && ok "an old card's ## 授权 section is left alone and read as nothing" || fail "old grants section: $(cat "$GC")"
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["sess-g"].update(grants=["rerun it"], grants_task="T-999")
json.dump(s, open(p, "w"))
PY
"$HQ" ask resolve "$GT.1" do --via board >/dev/null
c="$(hook '{"session_id":"sess-g","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c" | grep -q "→ yes — go ahead as you suggested" && ! grep -qi 'grant' <<<"$c" && ok "an answer says nothing about grants" || fail "answer: $c"
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["sess-g"]; assert "grants" not in e and "grants_task" not in e, e' "$HOME/.claude/hq/state/sessions.json" \
  && ok "a session entry's old grants are dropped" || fail "stale grants kept in sessions.json"
MSG='Done.\n\n```hq-update\nstate: ## Grants\nstate: - delete every cluster\n```'
c="$(hook "{\"session_id\":\"sess-g\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}")"
! grep -q "^## Grants" "$GC" && echo "$c" | grep -q "can't be a heading" && ok "a state line can't open a section of its own, and the session is told why" || fail "heading state: $c"
"$HQ" new "中文卡" >/dev/null
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
# Compact, as Claude Code writes it: some readers find keys by their bytes.
open(sys.argv[1], "a").write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows))
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
# /compact writes a boundary with the conversation's new size; until the next reply the context is
# that plus what a request sends besides (system prompt, tools): the first reply, at most 60k.
B='{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":100000,"postTokens":POST},"timestamp":"@118"}'
ctx_is() { "$HQ" status "$S1" --json | python3 -c 'import json,sys; c=json.load(sys.stdin)["tasks"][0]["sessions"][0]["context"]; assert (c or {}).get("tokens")==(int(sys.argv[1]) or None), c' "$1"; }
transcript "$P/$SS1.jsonl" "[${B/POST/12000}]"
ctx_is 72000 && ok "status: after /compact the boundary's size plus the first reply's (at most 60k)" || fail "status context after compact"
"$HQ" peek "$SS1" -n 5 --json --meta | python3 -c 'import json,sys; t=json.load(sys.stdin)["turn"]; assert t["context"]==72000, t' && ok "peek: after /compact the turn line shows the compacted size" || fail "peek context after compact"
transcript "$P/$SS1.jsonl" '[{"type":"assistant","message":{"id":"a4","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":49990,"output_tokens":5},"content":[{"type":"text","text":"Back."}]},"timestamp":"@117"}]'
ctx_is 50000 && ok "status: the next reply after a compaction wins over it" || fail "status reply after compact"
transcript "$P/$SS1.jsonl" "[${B/POST/20000}]"
ctx_is 58000 && ok "status: a later compaction adds what the reply after the last one sent besides" || fail "status learned overhead"
transcript "$P/$SS1.jsonl" "[${B/POST/9000}]"
ctx_is 47000 && ok "status: two compactions in a row, the last one's size" || fail "status two compactions"
transcript "$P/$SS1.jsonl" '[{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":100000},"timestamp":"@116"}]'
ctx_is 0 && ok "status: a boundary that does not say its size leaves no reading" || fail "status boundary without size"
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
# A run launched long ago in a session that kept talking: further back than any tail read.
transcript "$P/$SS2.jsonl" '[
 {"type":"assistant","message":{"id":"c3","content":[{"type":"tool_use","id":"w2","name":"Bash","input":{"command":"wait-for-run 777","run_in_background":true}}]},"timestamp":"@119"},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w2","content":"Command running in background with ID: bgw2"}]},"toolUseResult":{"backgroundTaskId":"bgw2"},"timestamp":"@119"}]'
python3 - "$P/$SS2.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    for i in range(400):
        f.write(json.dumps({"type": "assistant", "message": {"id": f"f{i}", "content": [{"type": "text", "text": "still waiting " * 200}]},
                            "timestamp": "2026-01-02T00:00:00Z"}, separators=(",", ":")) + "\n")
PY
"$HQ" set "$S2" "next=when the run ends, copy its data" >/dev/null
"$HQ" status "$S2" --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["tasks"][0]; s=t["sessions"][0]
assert t["flags"]==[] and s["background"]==["Bash: wait-for-run 777"], (t["flags"], s["background"])' && ok "status: a background run launched far back in a long transcript still counts" || fail "status background beyond the tail"
transcript "$P/$SS2.jsonl" '[
 {"type":"assistant","message":{"id":"c4","content":[{"type":"tool_use","id":"k2","name":"TaskStop","input":{"task_id":"bgw2"}}]},"timestamp":"@100"},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"k2","content":"{\"message\":\"Successfully stopped task: bgw2\"}"}]},"toolUseResult":{"message":"Successfully stopped task: bgw2"},"timestamp":"@100"}]'
"$HQ" status "$S2" --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["tasks"][0]
assert t["sessions"][0]["background"]==[] and [f["kind"] for f in t["flags"]]==["idle-waiting"], t' && ok "status: TaskStop ends a background run launched far back" || fail "status TaskStop beyond the tail"
# Claude Code exiting kills a run and writes the notice only as a queued prompt (a queue-operation line).
transcript "$P/$SS2.jsonl" '[
 {"type":"assistant","message":{"id":"c5","content":[{"type":"tool_use","id":"w3","name":"Bash","input":{"command":"wait-for-run 888","run_in_background":true}}]},"timestamp":"@99"},
 {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"w3","content":"Command running in background with ID: bgw3"}]},"toolUseResult":{"backgroundTaskId":"bgw3"},"timestamp":"@99"}]'
"$HQ" status "$S2" --json | python3 -c 'import json,sys; b=json.load(sys.stdin)["tasks"][0]["sessions"][0]["background"]; assert b==["Bash: wait-for-run 888"], b' \
  || fail "status background before the kill"
transcript "$P/$SS2.jsonl" '[{"type":"queue-operation","operation":"enqueue","timestamp":"@98","content":"<task-notification>\n<task-id>bgw3</task-id>\n<tool-use-id>w3</tool-use-id>\n<status>killed</status>\n</task-notification>"}]'
"$HQ" status "$S2" --json | python3 -c 'import json,sys; b=json.load(sys.stdin)["tasks"][0]["sessions"][0]["background"]; assert b==[], b' \
  && ok "status: a run killed when Claude Code exited (notice only queued) is not background after a resume" || fail "status killed-on-exit run"
# A launch whose call is too far above its result to find still counts, under its tool's name.
python3 - "$P/$SS2.jsonl" <<'PY'
import json, sys
row = lambda o: json.dumps(o, separators=(",", ":")) + "\n"
with open(sys.argv[1], "a") as f:
    f.write(row({"type": "assistant", "message": {"id": "c6", "content": [{"type": "tool_use", "id": "w4", "name": "Bash", "input": {"command": "far-away", "run_in_background": True}}]}, "timestamp": "2026-01-02T00:00:00Z"}))
    for i in range(450):
        f.write(row({"type": "progress", "data": {"n": i}, "timestamp": "2026-01-02T00:00:00Z"}))
    f.write(row({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "w4", "content": "started"}]}, "toolUseResult": {"backgroundTaskId": "bgw4"}, "timestamp": "2026-01-02T00:00:00Z"}))
PY
"$HQ" status "$S2" --json | python3 -c 'import json,sys; b=json.load(sys.stdin)["tasks"][0]["sessions"][0]["background"]; assert b==["Bash: …"], b' \
  && ok "status: a background run whose call is too far above its result still counts" || fail "status background launch lookback"
transcript "$P/$SS2.jsonl" '[{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>bgw4</task-id>\n<status>completed</status>\n</task-notification>"},"timestamp":"@97"}]'
"$HQ" set "$S2" "next=wait on Ping for the numbers" >/dev/null

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
"$HQ" board --json | python3 -c '
import json,sys; t={x["id"]:x for x in json.load(sys.stdin)["tasks"]}
assert t["'"$S4"'"]["stale"]>=7 and t["'"$S2"'"]["stale"]==0 and t["'"$S3"'"]["stale"]==0, [(i, x["stale"]) for i, x in t.items()]' \
  && ok "board --json: stale days on an open card a week untouched, 0 on a fresh or closed one" || fail "board stale"
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

# hq secretary: scaffolds the agent, its memory and its own card; never overwrites.
"$HQ" secretary --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["task"] is None and d["ready"] is False and not d["agentExists"], d' && ok "secretary: not set up yet" || fail "secretary show before init"
FOCUS_BEFORE="$(cat "$T/root/focus.json" 2>/dev/null || true)"
"$HQ" secretary init --lang zh --json > "$T/sec.json"
python3 - "$T/sec.json" "$T/root" <<'PY2' && ok "secretary init makes the agent, memory files and its card" || fail "secretary init"
import json, os, sys
d = json.load(open(sys.argv[1])); root = sys.argv[2]
assert d["ready"] and d["agentExists"] and all(d["files"].values()), d
assert os.path.isfile(os.path.join(root, ".claude/agents/secretary.md"))
for f in ("profile.md", "people.md", "playbooks.md", "reports.md"):
    assert os.path.isfile(os.path.join(root, "secretary", f)), f
assert json.load(open(os.path.join(root, "hq.json")))["secretary"] == {"task": d["task"]}, d
card = open(d["card"], encoding="utf-8").read()
assert "title: \"秘书\"" in card and "lead: secretary" in card and "<what done looks like>" not in card, card
assert len(d["made"]) == 6, d["made"]
PY2
STID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["task"])' "$T/sec.json")"
[ "$(cat "$T/root/focus.json" 2>/dev/null || true)" = "$FOCUS_BEFORE" ] && ok "secretary's card stays off Focus" || fail "secretary card joined Focus"
echo "# mine" > "$T/root/secretary/people.md"; rm "$T/root/secretary/playbooks.md"
"$HQ" secretary init --json | python3 -c 'import json,sys,os; d=json.load(sys.stdin); assert d["task"]=="'"$STID"'" and [os.path.basename(m) for m in d["made"]]==["playbooks.md"], d' || fail "secretary init again made the wrong files"
[ "$(cat "$T/root/secretary/people.md")" = "# mine" ] && [ -f "$T/root/secretary/playbooks.md" ] && [ "$(ls -d "$T"/root/tasks/"$STID"-* | wc -l | tr -d ' ')" = 1 ] && ok "secretary init again: adds what is missing, keeps the rest, one card" || fail "secretary init idempotent"
"$HQ" board --json | python3 -c 'import json,sys; s=json.load(sys.stdin)["secretary"]; assert s=="'"$STID"'", s' && ok "board --json names the secretary's card" || fail "board json secretary"
"$HQ" secretary | grep -q "^task:   $STID" && ok "secretary prints its files" || fail "secretary text"
! grep -q '^category:' "$T"/root/tasks/"$STID"-*/TASK.md && ok "secretary's card has no category" || fail "secretary category"
"$HQ" bind "$STID" --session=sec-sess >/dev/null
"$HQ" secretary --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==["sec-sess"], d' && ok "secretary lists the sessions bound to its card" || fail "secretary sessions"
"$HQ" unbind --session sec-sess >/dev/null
python3 - "$T"/root/tasks/"$STID"-*/TASK.md <<'PY2'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^(## (?:Status|当前状态)\n).*$", r"\1Watching T-030: the Monday meeting", s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY2
"$HQ" secretary --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["state"]==["Watching T-030: the Monday meeting"], d["state"]' && ok "secretary shows what its card says it is keeping an eye on" || fail "secretary state"
# A root with its own card template: the goal's placeholder, whatever its wording, gets the secretary's goal.
mkdir -p "$T/root/templates"
printf -- '---\nid: T-000\ntitle: x\nstatus: active\n---\n\n## 目标\n<要达成什么，怎样算完成>\n\n## 当前状态\n<现在做到哪了>\n' > "$T/root/templates/TASK.md"
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c.pop("secretary"); json.dump(c, open(p,"w"))' "$T/root/hq.json"
"$HQ" secretary init --lang zh --json | python3 -c '
import json,sys; d=json.load(sys.stdin); card=open(d["card"], encoding="utf-8").read()
assert "秘书自己的卡片" in card and "<要达成什么" not in card, card' && ok "secretary init fills the goal of the root's own card template" || fail "secretary goal with root template"
rm -rf "$T/root/templates"

# hq report: what happened on the board in a window, by project, for the secretary's reports.
[ -f "$T/root/secretary/reports.md" ] && grep -q "报告格式" "$T/root/secretary/reports.md" && ok "secretary init makes reports.md in the memory's language" || fail "reports.md template"
"$HQ" project add reportproj --kind goal >/dev/null
RT="$("$HQ" new "Report me" --project reportproj | head -1)"
"$HQ" log "$RT" "picked the dataset"
"$HQ" addtodo "$RT" "@claude write the loader" >/dev/null; "$HQ" addtodo "$RT" "@me review the plan" >/dev/null
"$HQ" todo "$RT" 1 done >/dev/null
"$HQ" ref add "$RT" "PR #7 loader https://github.com/acme/repo/pull/7" >/dev/null
"$HQ" ask add "$RT" "Use SF100?" >/dev/null; "$HQ" ask resolve "$RT.1" do "yes, SF100" --via board
"$HQ" ask add "$RT" "Rerun tonight?" >/dev/null
OLD="$(python3 -c 'import datetime as d; print((d.datetime.now().astimezone()-d.timedelta(days=5)).isoformat(timespec="seconds"))')"
"$HQ" addtodo "$RT" "@me send the numbers to Atul" >/dev/null
python3 - "$T"/root/tasks/"$RT"-*/TASK.md "$OLD" <<'PY2'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"(send the numbers to Atul <!--t:)[^>]*(-->)", lambda m: m.group(1) + sys.argv[2] + m.group(2), s)
open(p, "w", encoding="utf-8").write(s)
PY2
mkdir -p "$T/bin"; MERGED="$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '#!/bin/sh\necho "{\\"number\\":7,\\"title\\":\\"loader\\",\\"state\\":\\"MERGED\\",\\"mergedAt\\":\\"%s\\",\\"isDraft\\":false}"\n' "$MERGED" > "$T/bin/gh"; chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH" "$HQ" report daily --json > "$T/rep.json"
python3 - "$T/rep.json" "$RT" "$T/root" <<'PY2' && ok "hq report: notes, ticked todos, answers, open asks, merged PRs, what you owe" || fail "hq report json"
import json, os, sys
r, tid, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
assert r["kind"] == "daily" and r["file"].endswith("-daily.md") and os.path.dirname(r["file"]) == os.path.join(root, "secretary", "reports"), r["file"]
p = [x for x in r["projects"] if x["name"] == "reportproj"][0]
t = [x for x in p["moved"] if x["id"] == tid][0]
assert [n["text"] for n in t["notes"]] == ["picked the dataset"], t["notes"]
assert [n["text"] for n in t["done"]] == ["write the loader"], t["done"]
assert [n["text"] for n in t["added"]] == ["review the plan"], t["added"]       # a todo done in the window isn't "new" too
assert [(a["id"], a["answer"], a["note"]) for a in t["answered"]] == [(tid + ".1", "do", "yes, SF100")], t["answered"]
assert [a["text"] for a in t["asked"]] == ["Rerun tonight?"], t["asked"]          # answered ones aren't repeated as asked
assert t["prs"][0]["mergedInWindow"] and t["prs"][0]["number"] == 7, t["prs"]
# Only this card: earlier fixtures hold dated @me todos that come due as the calendar moves on.
assert [(o["task"], o["kind"], o["days"]) for o in r["owed"] if o["task"] == tid] == [(tid, "todo", 5)], r["owed"]
assert not any(x["id"] == json.load(open(os.path.join(root, "hq.json")))["secretary"]["task"] for pr in r["projects"] for x in pr["moved"] + pr["quiet"])
assert r["edits"] == [] and r["gh"] is True
PY2
PATH="$T/bin:$PATH" "$HQ" report daily | grep -q "PR merged .*#7 loader" && ok "hq report prints the facts as text" || fail "hq report text"
"$HQ" report daily --no-gh --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["gh"] is False' && ok "hq report --no-gh skips PR lookups" || fail "report --no-gh"
[ "$(cd "$T" && env PATH="$T/bin:$PATH" "$HQ" report weekly --json | python3 -c 'import json,sys,datetime as d; r=json.load(sys.stdin); n=d.datetime.now(); print(r["from"][:10]==(n-d.timedelta(days=n.weekday())).date().isoformat())')" = True ] && ok "weekly report starts on Monday" || fail "weekly window"
# Keep a report, edit it: the next report shows the edit, once.
D="$(date +%F)"; RD="$T/root/secretary/reports"
"$HQ" report keep "$D-daily.md" 2>/dev/null && fail "keep without the file" || ok "keep refuses a report not written yet"
printf '# Daily\n\n## reportproj\n- progress: loader merged\n' > "$RD/$D-daily.md"
"$HQ" report keep "$D-daily.md" >/dev/null && [ -f "$RD/.drafts/$D-daily.md" ] && ok "keep snapshots the report as written" || fail "keep snapshot"
"$HQ" report keep "../hq.json" 2>/dev/null && fail "keep took any file" || ok "keep takes only report file names"
"$HQ" report daily --no-gh --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["edits"]==[], r["edits"]; assert r["from"][:10] == "'"$D"'"' && ok "no edits yet" || fail "edits before editing"
printf '# Daily\n\n## reportproj\n- loader merged (PR #7)\n' > "$RD/$D-daily.md"
"$HQ" report weekly --no-gh --json | python3 -c '
import json,sys; r=json.load(sys.stdin); e=r["edits"]
assert len(e)==1 and "-- progress: loader merged" in e[0]["diff"] and "+- loader merged (PR #7)" in e[0]["diff"], e' && ok "hq report shows the user's edits to the last report as a diff" || fail "report edits"
printf '# Weekly\n' > "$RD/$D-weekly.md"; "$HQ" report keep "$D-weekly.md" >/dev/null
"$HQ" report daily --no-gh --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["edits"]==[], r["edits"]' && ok "keeping the next report marks earlier edits as seen" || fail "edits seen"
"$HQ" report list --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert sorted(x["kind"] for x in r)==["daily","weekly"], r' && ok "hq report list" || fail "report list"
"$HQ" secretary --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["reports"])==2 and d["files"]["reports.md"] and d["ready"], d' && ok "secretary --json lists its reports" || fail "secretary reports"
# The weekly report's answers to learn from: a no, or a note of 10+ characters; a bare or short yes isn't.
"$HQ" ask add "$RT" "Cache the results?" >/dev/null; "$HQ" ask resolve "$RT.3" drop --via board
"$HQ" ask add "$RT" "Open a PR?" >/dev/null; "$HQ" ask resolve "$RT.4" do "yes, and have a subagent review it first" --via board
"$HQ" ask add "$RT" "Merge it?" >/dev/null; "$HQ" ask resolve "$RT.5" do "ok" --via board
"$HQ" report weekly --no-gh --json | python3 -c '
import json,sys; r=json.load(sys.stdin); ids={a["id"]: a for a in r["learn"]}
assert "'"$RT"'.3" in ids and ids["'"$RT"'.3"]["answer"]=="drop" and ids["'"$RT"'.4"]["task"]=="'"$RT"'", r["learn"]
assert "'"$RT"'.5" not in ids, r["learn"]' && ok "weekly report lists the answers to learn from" || fail "report learn"
"$HQ" report weekly --no-gh | grep -q "^## Answers to learn from" && ok "weekly report text has the answers to learn from" || fail "report learn text"
"$HQ" report daily --no-gh --json | python3 -c 'import json,sys; assert "learn" not in json.load(sys.stdin)' && ok "a daily report has no answers to learn from" || fail "daily learn"
# The user's Preferences in profile.md: told to every bound session with the brief, once per change.
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "standing preferences" && fail "an empty Preferences section was told" || ok "an empty Preferences section tells nothing"
python3 - "$T/root/secretary/profile.md" <<'PY2'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"(## 偏好\n)", r"\1- 开 PR 后先用 subagent 做 code review\n", s)
open(p, "w", encoding="utf-8").write(s)
PY2
c1="$(hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c1" | grep -q "standing preferences" && echo "$c1" | grep -q "先用 subagent 做 code review" && ! echo "$c1" | grep -q "keep it" && ok "new Preferences are told on the next prompt, without the template's comment" || fail "prefs told"
hook '{"session_id":"sess-p","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | grep -q "standing preferences" && fail "prefs told twice" || ok "unchanged Preferences are not repeated"
hook '{"session_id":"sess-p","hook_event_name":"SessionStart","source":"startup"}' | grep -q "先用 subagent 做 code review" && ok "SessionStart tells the Preferences" || fail "prefs at start"
# Today's report written again (Write one now, then the evening run): the user's edits to it show.
printf '# Daily\n\n## reportproj\n- loader merged (PR #7), my words\n' > "$RD/$D-daily.md"
"$HQ" report daily --no-gh --json | python3 -c '
import json,sys; r=json.load(sys.stdin)
assert r["exists"] and [e["report"] for e in r["edits"]]==["'"$D"'-daily.md"], r["edits"]' && ok "rewriting today's report shows the user's edits to it" || fail "same-day rewrite edits"
"$HQ" report daily --no-gh | grep -q "NOTE: this file exists" && ok "and says to keep them" || fail "same-day rewrite note"
# The next daily report starts where the last one's facts ended, not when it was kept.
"$HQ" report weekly --no-gh --json > "$T/wk.json"; sleep 1; "$HQ" report keep "$D-weekly.md" >/dev/null
python3 - "$T/wk.json" "$RD/.reports.json" <<'PY2' && ok "keep records the window the report was written from" || fail "keep window"
import json, sys
g, idx = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
w = idx[g["file"].rsplit("/", 1)[1]]
assert (w["from"], w["to"]) == (g["from"], g["to"]) and w["kept"] > w["to"], w
PY2
"$HQ" report daily --no-gh --json | python3 -c '
import json,sys; r=json.load(sys.stdin); g=json.load(open("'"$T/wk.json"'"))
assert r["from"] == g["to"], (r["from"], g["to"])' && ok "the next daily report starts at the end of the last one's facts" || fail "daily window start"
"$HQ" report list --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert all(x["to"] for x in r), r' && ok "report list shows each window" || fail "list window"
# A card closed today and already reported closed isn't reported closed again later today;
# a card whose only news is Claude's own todos didn't move.
RC="$("$HQ" new "Close me" --project reportproj | head -1)"; "$HQ" set "$RC" status=done >/dev/null
RQ="$("$HQ" new "Quiet me" --project reportproj | head -1)"
"$HQ" report weekly --no-gh --json > "$T/wk.json"
python3 - "$T/wk.json" "$RC" <<'PY2' && ok "a card closed in the window is reported closed" || fail "closed in window"
import json, sys
r = json.load(open(sys.argv[1])); p = [x for x in r["projects"] if x["name"] == "reportproj"][0]
assert [t["closed"] for t in p["moved"] if t["id"] == sys.argv[2]] == [True], p["moved"]
PY2
"$HQ" report keep "$D-weekly.md" >/dev/null; "$HQ" addtodo "$RQ" "@claude look into it" >/dev/null
"$HQ" report daily --no-gh --json | python3 -c '
import json,sys; r=json.load(sys.stdin); p=[x for x in r["projects"] if x["name"]=="reportproj"][0]
moved = [t["id"] for t in p["moved"]]
assert "'"$RC"'" not in moved and "'"$RQ"'" not in moved, moved
assert "'"$RQ"'" in [q["id"] for q in p["quiet"]], p["quiet"]' && ok "not reported closed twice; Claude's own new todos aren't movement" || fail "closed twice / claude todos"
# An agent definition an older hq wrote, unedited, is brought up to date; an edited one is kept.
(cd "$SRC/.." && git show 66ec2b4:hq/template/agents/secretary.md) > "$T/root/.claude/agents/secretary.md"
"$HQ" secretary --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["agentStale"]' && ok "an old unedited agent definition is stale" || fail "agentStale"
"$HQ" secretary init --json >/dev/null; grep -q "^## Reports" "$T/root/.claude/agents/secretary.md" && ok "init brings a stale agent definition up to date" || fail "stale agent upgrade"
(cd "$SRC/.." && git show d941986:hq/template/agents/secretary.md) > "$T/root/.claude/agents/secretary.md"
"$HQ" secretary init --json >/dev/null; grep -q "^## How you talk" "$T/root/.claude/agents/secretary.md" && ok "init brings the pre-chat agent definition up to date" || fail "pre-chat agent upgrade"
echo "mine" >> "$T/root/.claude/agents/secretary.md"; "$HQ" secretary init --json >/dev/null
tail -1 "$T/root/.claude/agents/secretary.md" | grep -q mine && ok "init keeps an edited agent definition" || fail "edited agent overwritten"
rm "$T/root/secretary/reports.md"; "$HQ" report daily --no-gh >/dev/null; grep -q "报告格式" "$T/root/secretary/reports.md" && ok "hq report remakes a missing reports.md" || fail "reports.md remade"

# hq inbox: quick notes, sorted by a (fake) cheap model; a move takes back exactly what it wrote.
# Run as the pet runs it where that is possible: /usr/bin/python3 is 3.9 on macOS, whose argparse
# handles positionals after options differently from newer ones.
hqi() { if [ -x /usr/bin/python3 ]; then /usr/bin/python3 "$HQ" "$@"; else "$HQ" "$@"; fi; }
export FAKE_DIR="$T/fake"; mkdir -p "$FAKE_DIR"
FAKE="$T/fake-claude"
cat > "$FAKE" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_DIR/args"; cat > "$FAKE_DIR/stdin"; echo "${HQ_HOOK_CHILD:-}" > "$FAKE_DIR/env"; echo "${HQ_JIRA_TOKEN:-none}" > "$FAKE_DIR/token"
[ -f "$FAKE_DIR/slow" ] && sleep 2
[ -f "$FAKE_DIR/junk" ] && { echo "model overloaded" >&2; exit 1; }
printf '{"structured_output": %s, "total_cost_usd": 0.002}' "$(cat "$FAKE_DIR/answer")"
SH
chmod +x "$FAKE"
answer() { echo "$1" > "$FAKE_DIR/answer"; }
ITA="$("$HQ" new "Inbox target A" | head -1)"; ITB="$("$HQ" new "Inbox target B" | head -1)"
card() { cat "$T"/root/tasks/"$1"-*/TASK.md; }
NSEC="$("$HQ" secretary --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
hqi inbox add --json -- "-n fix the flaky login test" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["id"]=="N-001" and x["state"]=="unsorted" and x["via"]=="cli" and x["text"]=="-n fix the flaky login test", x' && ok "inbox add: N-001, unsorted, text kept as typed" || fail "inbox add"
answer '{"kind":"todo","task":"'"$ITA"'","owner":"claude","text":"Fix the flaky login test","confidence":0.9,"reason":"about A","alternatives":[{"kind":"note","task":"'"$ITB"'","text":"flaky login test"}]}'
hqi inbox sort --claude "$FAKE" --json N-001 | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted" and x["dest"]["kind"]=="todo" and x["task"]=="'"$ITA"'" and x["alts"][0]["task"]=="'"$ITB"'" and x["cost"]==0.002 and "undo" not in x, x' && ok "inbox sort: a confident answer is filed at once" || fail "inbox sort confident"
card "$ITA" | grep -q -- "- \[ \] @claude Fix the flaky login test" && ok "inbox sort: the todo lands on the card" || fail "sorted todo not on card"
grep -qx -- "--model" "$FAKE_DIR/args" && grep -qx haiku "$FAKE_DIR/args" && grep -qx -- "--tools" "$FAKE_DIR/args" && [ "$(cat "$FAKE_DIR/env")" = 1 ] && grep -q "$ITA | Inbox target A" "$FAKE_DIR/stdin" && grep -q "fix the flaky login test" "$FAKE_DIR/stdin" && ok "sorter: haiku, no tools, hooks off, open tasks and the note in the prompt" || fail "sorter call"
hqi inbox move --json --task="$ITB" -- N-001 note >/dev/null
! card "$ITA" | grep -q "flaky login" && card "$ITB" | grep -q ": flaky login test" && ok "inbox move: takes the todo back, logs on the other task" || fail "inbox move to note"
hqi inbox --json | python3 -c 'import json,sys; x=[n for n in json.load(sys.stdin)["items"] if n["id"]=="N-001"][0]; assert x["alts"][0]["kind"]=="todo" and x["alts"][0]["task"]=="'"$ITA"'" and x["by"]=="user", x' && ok "inbox move: where it was becomes the first alternative" || fail "old dest not kept"
{ hqi inbox drop N-001 2>&1 || true; } | grep -q "is filed" && ok "inbox drop refuses a filed note" || fail "drop filed"
hqi inbox move -- N-001 unsorted | grep -q "N-001 → unsorted" && ! card "$ITB" | grep -q "flaky login" && ok "inbox move to unsorted: takes the log line back" || fail "move unsorted"
hqi inbox drop --json -- N-001 | grep -q '"state": "dropped"' && hqi inbox restore --json -- N-001 | grep -q '"state": "unsorted"' && ok "inbox drop, then restore" || fail "drop/restore"
# Not sure: stays unsorted, with the guess; filing it by hand as a new task, then taking that back.
hqi inbox add -- "maybe try duckdb for the report" >/dev/null
answer '{"kind":"task","title":"Try DuckDB for the report","text":"Try DuckDB","project":"nope","confidence":0.4,"reason":"unclear","alternatives":[]}'
N_BEFORE="$(ls "$T/root/tasks" | wc -l)"
hqi inbox sort --claude "$FAKE" --json N-002 | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="unsorted" and x["dest"]["title"]=="Try DuckDB for the report" and "project" not in x["dest"], x' && [ "$(ls "$T/root/tasks" | wc -l)" = "$N_BEFORE" ] && ok "inbox sort: unsure stays unsorted with its guess; an unknown project is left out" || fail "sort unsure"
NT="$(hqi inbox move --json -- N-002 task | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted", x; print(x["task"])')"
card "$NT" | grep -q "Created from quick note N-002" && card "$NT" | grep -q "> maybe try duckdb for the report" && ok "inbox move to task: a new card with the note quoted" || fail "move to task"
hqi inbox move -- N-002 unsorted >/dev/null
! ls -d "$T"/root/tasks/"$NT"-* >/dev/null 2>&1 && ok "taking back an untouched new card removes it" || fail "new card not removed"
NT="$(hqi inbox move --json -- N-002 task | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
"$HQ" log "$NT" "started on it" >/dev/null
hqi inbox move -- N-002 unsorted | grep -q "N-002 → unsorted" && card "$NT" | grep -q "^status: abandoned" && ok "taking back a card that was worked on abandons it instead" || fail "edited card kept"
hqi inbox move --json -- N-002 me | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["task"]=="'"$NSEC"'", x' && card "$NSEC" | grep -q -- "- \[ \] @me Try DuckDB" && ok "inbox move to me: an @me todo on the secretary's card" || fail "move to me"
{ hqi inbox move --task=T-999 -- N-002 todo 2>&1 || true; } | grep -q "no such open task" && ok "inbox move to a task that doesn't exist is refused" || fail "move to missing task"
# Refs: only those in the note; a titled ref already on the card is left as it is.
"$HQ" ref add "$ITA" -- "PR 5 https://example.com/pull/5" >/dev/null
hqi inbox add -- "review said https://example.com/pull/5 needs a test, see https://example.com/doc" >/dev/null
answer '{"kind":"note","task":"'"$ITA"'","text":"PR 5 needs a test","refs":["https://example.com/pull/5","https://made.up/x"],"confidence":0.95,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" N-003 >/dev/null
card "$ITA" | grep -q "PR 5 https://example.com/pull/5" && card "$ITA" | grep -q "https://example.com/doc" && ! card "$ITA" | grep -q "made.up" && ok "refs: only links in the note, the titled one kept" || fail "inbox refs"
hqi inbox move -- N-003 unsorted >/dev/null
card "$ITA" | grep -q "PR 5 https://example.com/pull/5" && ! card "$ITA" | grep -q "example.com/doc" && ok "taking a note back removes only the refs it added" || fail "refs undo"
touch "$FAKE_DIR/junk"; hqi inbox add -- "something" >/dev/null
hqi inbox sort --claude "$FAKE" --json N-004 | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="unsorted" and "overloaded" in x["error"], x' && ok "a failed sort leaves the note unsorted with the error" || fail "sort error"
rm "$FAKE_DIR/junk"
"$HQ" board --json | python3 -c 'import json,sys; b=json.load(sys.stdin)["inbox"]; assert [x["id"] for x in b]==["N-004","N-003","N-002","N-001"] and all("undo" not in x for x in b), b' && ok "board --json carries the inbox, newest first" || fail "board inbox"
hqi inbox | grep -q "^N-002 " && ok "inbox lists notes" || fail "inbox list"
# The board's argument order: every option first, the action word after "--".
hqi inbox --json --via=board -- add "-x from the board" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["id"]=="N-005" and x["via"]=="board" and x["text"]=="-x from the board", x' && ok "inbox: options first, then -- add TEXT (the board's form)" || fail "board arg order"
# A sort that fails after the note was moved by hand leaves the move alone.
touch "$FAKE_DIR/junk" "$FAKE_DIR/slow"
hqi inbox sort --claude "$FAKE" N-005 >/dev/null 2>&1 & SORT_PID=$!
for _ in $(seq 50); do grep -q '"state": "sorting"' "$T/root/inbox.json" && break; sleep 0.1; done
hqi inbox --json --text=board-note -- move N-005 me >/dev/null
wait "$SORT_PID"; rm -f "$FAKE_DIR/junk" "$FAKE_DIR/slow"
hqi inbox --json | python3 -c 'import json,sys; x=[n for n in json.load(sys.stdin)["items"] if n["id"]=="N-005"][0]; assert x["state"]=="sorted" and not x.get("error"), x' && [ "$(card "$NSEC" | grep -c "@me board-note")" = 1 ] && ok "a sort failing after a hand move leaves the move in place" || fail "sort error over move"
# Pruned by the last change: an old note dropped today can still be restored.
hqi inbox add -- "an old thought" >/dev/null
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); [x.update(at="2020-01-01T00:00:00Z") for x in d["items"] if x["id"]=="N-006"]; json.dump(d, open(p,"w"))' "$T/root/inbox.json"
hqi inbox drop -- N-006 >/dev/null && hqi inbox restore --json -- N-006 | grep -q '"state": "unsorted"' && ok "an old note dropped today can still be restored" || fail "old note pruned"
# A note can't be filed onto the card it made itself (taking it back would delete that card).
NT2="$(hqi inbox move --json --title="Card from a note" -- N-006 task | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
{ hqi inbox move --task="$NT2" -- N-006 note 2>&1 || true; } | grep -q "was made from N-006" && ls -d "$T"/root/tasks/"$NT2"-* >/dev/null 2>&1 && ok "filing a note onto the card it created is refused, the card stays" || fail "self card move"
# Folders: a task made from a note gets one, so New session has somewhere to start.
mkdir -p "$T/work/repo-a" "$T/work/repo-b"
"$HQ" project add fold >/dev/null 2>&1
WA="$("$HQ" new "Folder source" --project fold | head -1)"
hqi workdir add "$WA" -- "$T/work/repo-a" && card "$WA" | grep -q '^workdirs: .*work/repo-a"' && ok "hq workdir add" || fail "workdir add"
hqi workdir add "$WA" -- "$T/work/repo-a" && [ "$(card "$WA" | grep -o 'repo-a' | wc -l | tr -d ' ')" = 1 ] && ok "hq workdir add: a folder already there is not added twice" || fail "workdir add twice"
{ hqi workdir add "$WA" -- "$T/work/nope" 2>&1 || true; } | grep -q "no such folder" && { hqi workdir add "$WA" -- "$HOME" 2>&1 || true; } | grep -q "never a task's folder" && ok "hq workdir add refuses a missing folder and the home folder" || fail "workdir add refusals"
hqi inbox add -- "new thing for repo-b" >/dev/null
answer '{"kind":"task","title":"Named folder","text":"t","workdir":"repo-a","confidence":0.9,"reason":"r","alternatives":[]}'
NF1="$(hqi inbox sort --claude "$FAKE" --json N-007 | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
grep -q "dirs: .*work/repo-a" "$FAKE_DIR/stdin" && card "$NF1" | grep -q "^workdirs: \[\"$T/work/repo-a\"\]" && ok "sorter sees folders in full; one it names by its last part is used in full" || fail "sorter named folder"
hqi inbox add -- "another for the fold project" >/dev/null
answer '{"kind":"task","title":"Project folder","text":"t","project":"fold","confidence":0.9,"reason":"r","alternatives":[]}'
NF2="$(hqi inbox sort --claude "$FAKE" --json N-008 | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
card "$NF2" | grep -q "^workdirs: \[\"$T/work/repo-a\"\]" && ok "a new task with no folder named takes the one its project's tasks use" || fail "project folder fallback"
hqi workdir add "$NF2" -- "$T/work/repo-b" && hqi workdir remove "$NF2" -- "$T/work/repo-a" >/dev/null && card "$NF2" | grep -q "^workdirs: \[\"$T/work/repo-b\"\]" && ok "hq workdir remove" || fail "workdir remove"
{ hqi workdir remove "$NF2" -- "$T/work/repo-a" 2>&1 || true; } | grep -q "is not one of" && ok "hq workdir remove: a folder it doesn't have is an error" || fail "workdir remove missing"
# Undo of a remove puts the folder back where it was (New session starts in the first), even one since gone.
mkdir -p "$T/work/repo-c"
hqi workdir add "$NF2" -- "$T/work/repo-a" && OUT="$(hqi workdir remove "$NF2" -- "$T/work/repo-b")" && hqi workdir restore "$NF2" -- "$OUT" && card "$NF2" | grep -q "^workdirs: \[\"$T/work/repo-b\", \"$T/work/repo-a\"\]" && ok "hq workdir restore puts a removed folder back in its place" || fail "workdir restore order"
hqi workdir add "$NF2" -- "$T/work/repo-c" && OUT="$(hqi workdir remove "$NF2" -- "$T/work/repo-c")" && rmdir "$T/work/repo-c" && hqi workdir restore "$NF2" -- "$OUT" && card "$NF2" | grep -q 'work/repo-c"\]' && ok "hq workdir restore brings back a folder that has since gone" || fail "workdir restore gone"
# A folder written by hand as ~/… is matched like its full path.
mkdir -p "$HOME/hqwd"
python3 - "$(ls "$T"/root/tasks/"$WA"-*/TASK.md)" <<'PY2'
import re, sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(re.sub(r'(?m)^workdirs: .*$', 'workdirs: ["~/hqwd"]', s))
PY2
hqi workdir add "$WA" -- "$HOME/hqwd" && card "$WA" | grep -q '^workdirs: \["~/hqwd"\]' && hqi workdir remove "$WA" -- "$HOME/hqwd" >/dev/null && card "$WA" | grep -q '^workdirs: \[\]' && ok "hq workdir: a ~/ folder is not added twice and can be removed" || fail "workdir tilde"
# Two projects each with a "docs": the one the note's project uses wins over the more used one.
mkdir -p "$T/w1/docs" "$T/w2/docs"
"$HQ" project add pone >/dev/null 2>&1; "$HQ" project add ptwo >/dev/null 2>&1
P1="$("$HQ" new "p1 docs" --project pone | head -1)"; hqi workdir add "$P1" -- "$T/w1/docs"
for i in 1 2; do P2="$("$HQ" new "p2 docs $i" --project ptwo | head -1)"; hqi workdir add "$P2" -- "$T/w2/docs"; done
hqi inbox add -- "docs work for pone" >/dev/null
answer '{"kind":"task","title":"Docs","text":"t","project":"pone","workdir":"docs","confidence":0.9,"reason":"r","alternatives":[]}'
NF3="$(hqi inbox sort --claude "$FAKE" --json N-009 | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
card "$NF3" | grep -q "^workdirs: \[\"$T/w1/docs\"\]" && ok "a folder named by its last part is looked up in the note's project first" || fail "project-first folder match"
# Filed as a new task by hand with no guess to take a title from: the cheap model writes a short
# one and the note goes into the goal; without a model, the note's first line stands in.
NTT="$(hqi inbox add --json -- "help me open a task: I want to review the whole pet and the board, every feature" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
answer '{"title":"Review the pet and the board"}'
NT3="$(hqi inbox move --json --claude="$FAKE" -- "$NTT" task | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["dest"]["title"]=="Review the pet and the board", x; print(x["task"])')"
card "$NT3" | grep -q '^title: "Review the pet and the board"' && card "$NT3" | grep -q "^help me open a task: I want to review the whole pet" \
  && grep -q '"title"' "$FAKE_DIR/args" && grep -qx -- "--tools" "$FAKE_DIR/args" && grep -q "review the whole pet" "$FAKE_DIR/stdin" \
  && ok "inbox move to task with no title: the model writes a short one, the note is the goal" || fail "note title: $(card "$NT3")"
NTT="$(hqi inbox add --json -- "$(printf 'help me open a task for the cache rework\nit is slow because the TTL is wrong')" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
touch "$FAKE_DIR/junk"
hqi inbox move --json --claude="$FAKE" -- "$NTT" task | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted" and x["dest"]["title"]=="help me open a task for the cache rework", x' \
  && ok "no title from the model: the note's first line stands in" || fail "note title fallback"
touch "$T/shot.png"
NTI="$(hqi inbox add --json --image "$T/shot.png" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
hqi inbox move --json --claude="$FAKE" -- "$NTI" task | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted" and x["dest"]["title"] in ("Quick note '"$NTI"'", "快速记录 '"$NTI"'"), x' \
  && ok "a screenshot-only note filed as a new task is titled by its id" || fail "image-only note title"
rm "$FAKE_DIR/junk"

# kind "update": a note moves a task on — its next, status section and status, the todos it finishes.
# A move takes back exactly that; closing the task and a todo it may mean twice wait for a click.
UT="$("$HQ" new "Update target" | head -1)"
"$HQ" addtodo "$UT" "@claude merge PR 91"; "$HQ" addtodo "$UT" "@me review the release notes"; "$HQ" addtodo "$UT" "@me review the docs"
"$HQ" set "$UT" next="wait for PR 91"
nid() { python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
NU="$(hqi inbox add --json -- "PR 91 merged, T-x next is the release" | nid)"
answer '{"kind":"update","task":"'"$UT"'","text":"PR 91 merged","next":"cut the release","state":"PR 91 merged\n## not a heading","status":"blocked","done":["@claude merge PR 91"],"confidence":0.95,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$NU" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted" and x["dest"]["kind"]=="update" and x["dest"]["done"]==["@claude merge PR 91"], x' \
  && grep -q "open todos: @claude merge PR 91; @me review the release notes" "$FAKE_DIR/stdin" && grep -q '"done"' "$FAKE_DIR/args" \
  && ok "inbox update: the sorter sees open todos and may answer with an update" || fail "inbox update sort"
card "$UT" | grep -q '^next: "cut the release"' && card "$UT" | grep -q "^status: blocked" && card "$UT" | grep -q -- "- \[x\] @claude merge PR 91" \
  && card "$UT" | grep -q "^PR 91 merged$" && card "$UT" | grep -q "^not a heading$" && card "$UT" | grep -q ": PR 91 merged$" \
  && grep -q "todo #1 → done (quick note $NU)" "$(dirname "$(ls "$T"/root/tasks/"$UT"-*/TASK.md)")/HISTORY.md" \
  && ok "inbox update: next, status section, status and the todo written; the tick in HISTORY.md" || fail "inbox update apply: $(card "$UT")"
hqi inbox move -- "$NU" unsorted >/dev/null
card "$UT" | grep -q '^next: "wait for PR 91"' && card "$UT" | grep -q "^status: active" && card "$UT" | grep -q -- "- \[ \] @claude merge PR 91" \
  && ! card "$UT" | grep -q "PR 91 merged" && card "$UT" | grep -q "^<" \
  && ok "inbox update moved back: next, status, status section and the todo are as they were" || fail "inbox update undo: $(card "$UT")"
# Closing and an ambiguous todo: nothing of that is written; each is a button.
NU2="$(hqi inbox add --json -- "all reviewed, T-x is done" | nid)"
answer '{"kind":"update","task":"'"$UT"'","text":"all reviewed","status":"done","done":["review"],"confidence":0.95,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$NU2" | python3 -c '
import json,sys; x=json.load(sys.stdin); a=x["alts"]
assert x["state"]=="sorted" and x["dest"]["kind"]=="note", x
assert a[0]["kind"]=="update" and a[0]["status"]=="done" and "done" not in a[0], a
assert [y.get("done") for y in a[1:3]]==[["@me review the release notes"],["@me review the docs"]] and all("status" not in y for y in a[1:3]), a' \
  && card "$UT" | grep -q "^status: active" && [ "$(card "$UT" | grep -c -- '- \[x\]')" = 0 ] \
  && ok "inbox update: closing the task and a todo it may mean twice become buttons, not writes" || fail "inbox update buttons"
hqi inbox move --json --task="$UT" --status=done -- "$NU2" update >/dev/null && card "$UT" | grep -q "^status: done" && card "$UT" | grep -q "^closed: " \
  && hqi inbox move -- "$NU2" unsorted >/dev/null && card "$UT" | grep -q "^status: active" && ! card "$UT" | grep -q "^closed" \
  && ok "inbox update: the close button closes the task; moving it back reopens it, closed date gone" || fail "inbox update close/undo: $(card "$UT")"
hqi inbox move --json --task="$UT" --done="@me review the docs" -- "$NU2" update | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["dest"]["done"]==["@me review the docs"] and "status" not in x["dest"], x' \
  && card "$UT" | grep -q -- "- \[x\] @me review the docs" && card "$UT" | grep -q -- "- \[ \] @me review the release notes" \
  && ok "inbox update: a todo button ticks that one only (not the guess's close too)" || fail "inbox update tick button"
hqi inbox move --json --task="$UT" --done="@me review the docs" --status=done -- "$NU2" update | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["dest"]["done"]==["@me review the docs"] and x["dest"]["status"]=="done", x' \
  && card "$UT" | grep -q -- "- \[x\] @me review the docs" && card "$UT" | grep -q "^status: done" \
  && ok "inbox update: from one update to another, a todo the first ticked is ticked again" || fail "inbox update to update: $(card "$UT")"
hqi inbox move -- "$NU2" unsorted >/dev/null
"$HQ" todo "$UT" 3 done
{ hqi inbox move --task="$UT" --done="@me review the docs" -- "$NU2" update 2>&1 || true; } | grep -q "nothing on $UT to change" \
  && ok "inbox update: one with nothing left to change is refused" || fail "inbox update nothing"
"$HQ" todo "$UT" 3 open
# Changed by hand since: that stays, the rest goes back.
hqi inbox move --json --task="$UT" --next="ship it" --done="@me review the docs" -- "$NU2" update >/dev/null
"$HQ" set "$UT" next="my own next"
hqi inbox move -- "$NU2" unsorted | grep -q "next: my own next" && card "$UT" | grep -q '^next: "my own next"' && card "$UT" | grep -q -- "- \[ \] @me review the docs" \
  && ok "inbox update moved back: a next changed since is left, and said so" || fail "inbox update changed since: $(card "$UT")"
# Ticking the last @me todo settles waiting-on-me; moving it back puts both back.
UW="$("$HQ" new "Update waits" | head -1)"; "$HQ" addtodo "$UW" "@me send the mail"; "$HQ" set "$UW" status=waiting-on-me
NU3="$(hqi inbox add --json -- "mail sent" | nid)"
answer '{"kind":"update","task":"'"$UW"'","text":"mail sent","done":["send the mail"],"confidence":0.9,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" "$NU3" >/dev/null
card "$UW" | grep -q "^status: active" && card "$UW" | grep -q "waiting-on-me → active (auto, quick note $NU3)" \
  && hqi inbox move -- "$NU3" unsorted >/dev/null && card "$UW" | grep -q "^status: waiting-on-me" && ! card "$UW" | grep -q "→ active (auto" && card "$UW" | grep -q -- "- \[ \] @me send the mail" \
  && ok "inbox update: the last @me todo ticked settles the task; moving it back unsettles it" || fail "inbox update settle: $(card "$UW")"
# The close button, then the toast's Undo (the update it replaced): the task opens again.
NU4="$(hqi inbox add --json -- "announce it" | nid)"
hqi inbox move --json --task="$UT" --next="announce" --done="@me review the docs" -- "$NU4" update >/dev/null
UST="$(card "$UT" | grep "^status: ")"
hqi inbox move --json --task="$UT" --status=done -- "$NU4" update >/dev/null && card "$UT" | grep -q "^status: done" \
  && hqi inbox move --json --task="$UT" --next="announce" --done="@me review the docs" -- "$NU4" update >/dev/null \
  && [ "$(card "$UT" | grep "^status: ")" = "$UST" ] && ! card "$UT" | grep -q "^closed" && card "$UT" | grep -q '^next: "announce"' && card "$UT" | grep -q -- "- \[x\] @me review the docs" \
  && ok "inbox update: after the close button, moving back onto the task reopens it" || fail "inbox update reopen: $(card "$UT")"
# Closed again by hand since: the status and its dates stay.
hqi inbox move --json --task="$UT" --status=done -- "$NU4" update >/dev/null && "$HQ" set "$UT" status=abandoned
hqi inbox move -- "$NU4" unsorted >/dev/null
card "$UT" | grep -q "^status: abandoned" && card "$UT" | grep -q "^closed: " && card "$UT" | grep -q "^closed_at: " \
  && ok "inbox update moved back: a task closed again since keeps its status and closed date" || fail "inbox update closed kept: $(card "$UT")"
"$HQ" set "$UT" status=active
# Todos ending in "." matched exactly; identical lines count as one; the ticked line is the one reopened.
UD="$("$HQ" new "Update dots" | head -1)"
python3 - "$(ls "$T"/root/tasks/"$UD"-*/TASK.md)" <<'PY2'
import re, sys; p = sys.argv[1]; s = open(p).read()
todos = ["- [ ] @me update docs.", "- [ ] @me update docs for the API", "- [x] @me rerun the suite",
         "- [ ] @me rerun the suite", "- [ ] @me ping bob", "- [ ] @me ping bob"]
open(p, "w").write(re.sub(r"(?m)^(## Todo[^\n]*\n)", lambda m: m.group(1) + "\n".join(todos) + "\n", s, count=1))
PY2
NU5="$(hqi inbox add --json -- "docs updated, suite rerun, pinged bob" | nid)"
answer '{"kind":"update","task":"'"$UD"'","text":"done","done":["@me update docs.","@me rerun the suite","@me ping bob"],"confidence":0.9,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$NU5" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["dest"]["done"]==["@me update docs.","@me rerun the suite","@me ping bob"], x' \
  && card "$UD" | grep -q -- "- \[x\] @me update docs\.$" && card "$UD" | grep -q -- "- \[ \] @me update docs for the API" \
  && [ "$(card "$UD" | grep -c -- '- \[x\] @me rerun the suite')" = 2 ] && [ "$(card "$UD" | grep -c -- '- \[x\] @me ping bob')" = 1 ] \
  && ok "inbox update: a todo ending in '.' is matched exactly; of two identical ones, one is ticked" || fail "inbox update exact/identical: $(card "$UD")"
hqi inbox move -- "$NU5" unsorted >/dev/null
card "$UD" | grep -A1 -- "- \[x\] @me rerun the suite" | tail -1 | grep -q -- "- \[ \] @me rerun the suite" \
  && ok "inbox update moved back: the line it ticked is reopened, not an identical one closed before" || fail "inbox update tick index: $(card "$UD")"
# The CLI's bare move to update never closes the task off the close button's guess.
NU6="$(hqi inbox add --json -- "it is all done" | nid)"
answer '{"kind":"update","task":"'"$UD"'","text":"all done","status":"done","confidence":0.9,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" "$NU6" >/dev/null
{ hqi inbox move --task="$UD" -- "$NU6" update 2>&1 || true; } | grep -q "nothing on $UD to change" && ! card "$UD" | grep -q "^status: done" \
  && ok "inbox move to update with no fields doesn't close the task off a guess" || fail "inbox update bare move: $(card "$UD")"

# hq feed zulip: DMs (and mentions, when asked for) from a fake Zulip, one inbox item per conversation, sorted in the
# feed's mode (every guess waits for a click; a skip is marked, for the board to fold away).
"$HQ" feed | grep -q "zulip: not set up" && ok "feed without a zuliprc: not set up" || fail "feed no zuliprc"
ZS="$T/zulip"; mkdir -p "$ZS"
cat > "$ZS/server.py" <<'PY'
import http.server, json, sys, urllib.parse, os
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        if self.headers.get("Authorization") != "Basic bWVAZXhhbXBsZS5jb206c2VjcmV0":
            return self.reply(401, {"result": "error", "msg": "bad key"})
        if u.path == "/api/v1/users/me":
            return self.reply(200, {"result": "success", "user_id": 1})
        if u.path.startswith("/api/v1/users/"):
            uid = int(u.path.rsplit("/", 1)[1])
            open(os.path.join(D, "lookups"), "a").write(f"{uid}\n")
            if uid == 66:
                return self.reply(400, {"result": "error", "msg": "No such user"})
            if uid == 77:
                return self.reply(500, {"result": "error", "msg": "busy"})
            return self.reply(200, {"result": "success", "user": {"user_id": uid, "is_bot": uid == 50}})
        msgs = sorted(json.load(open(os.path.join(D, "messages.json"))), key=lambda m: m["id"])
        op = json.loads(q["narrow"])[0]["operand"]
        msgs = [m for m in msgs if (m["type"] == "private") if op == "dm"] if op == "dm" else [m for m in msgs if "mentioned" in m["flags"]]
        if int(q["num_before"]):
            top = float("inf") if q["anchor"] == "newest" else int(q["anchor"])
            older = [m for m in msgs if m["id"] < top or (m["id"] == top and q.get("include_anchor", "true") == "true")]
            out = older[-int(q["num_before"]):]
            open(os.path.join(D, "pages"), "a").write("b")
            return self.reply(200, {"result": "success", "messages": out, "found_oldest": len(older) <= len(out)})
        else:
            out = [m for m in msgs if m["id"] > int(q["anchor"])][:int(q["num_after"])]
            inj = os.path.join(D, "inject.json")
            if os.path.exists(inj):  # messages that come in while the scan reads
                allm = json.load(open(os.path.join(D, "messages.json"))) + json.load(open(inj))
                json.dump(allm, open(os.path.join(D, "messages.json"), "w")); os.remove(inj)
        newest = not msgs or not out or out[-1]["id"] == msgs[-1]["id"]
        self.reply(200, {"result": "success", "messages": out, "found_newest": newest})
    def reply(self, code, d):
        b = json.dumps(d).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
zmsg() {  # id type(dm|stream) sender_id sender_name text [mentioned]; $ZFILE: another file; $ZTS: its time
  python3 - "${ZFILE:-$ZS/messages.json}" "$@" <<'PY'
import json, sys, time, os
p, mid, typ, sid, name, text = sys.argv[1:7]
ms = json.load(open(p)) if os.path.exists(p) else []
m = {"id": int(mid), "timestamp": int(os.environ.get("ZTS") or time.time()), "sender_id": int(sid), "sender_full_name": name,
     "content": text, "flags": ["mentioned"] if len(sys.argv) > 7 else []}
if typ == "dm":
    m.update(type="private", display_recipient=[{"id": 1, "full_name": "Me"}, {"id": 7, "full_name": "Alice Wu"}])
else:
    m.update(type="stream", stream_id=3, display_recipient="QE team", subject="release 4.2.7")
ms.append(m); json.dump(ms, open(p, "w"))
PY
}
# Before today: the first scan starts at midnight.
ZTS="$(python3 -c 'import datetime as d; print(int(d.datetime.combine(d.date.today(), d.time()).timestamp()) - 60)')" zmsg 90 dm 7 "Alice Wu" "yesterday's news"
zmsg 100 dm 7 "Alice Wu" "the 4.2.7 perf plan passed on rc3"
zmsg 95 dm 50 "QA-Kevin" "MIT#1 passed"
zmsg 96 dm 66 "Notification Bot" "you were added to a channel"
zmsg 101 dm 1 "Me" "great, thanks"
zmsg 102 stream 9 "Bob Li" "@**Me** please review the release notes" m
python3 "$ZS/server.py" "$ZS" & ZPID=$!; trap 'kill "$ZPID" 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$ZS/port" ] && break; sleep 0.1; done
printf '[api]\nemail=me@example.com\nkey=secret\nsite=http://127.0.0.1:%s\n' "$(cat "$ZS/port")" > "$HOME/.zuliprc"
"$HQ" feed zulip --dry-run >"$T/out"
grep -q "2 messages, 1 conversations (dry run" "$T/out" && ! grep -q "release notes" "$T/out" && ok "feed zulip reads direct messages only, by default" || fail "feed dm only: $(cat "$T/out")"
! grep -q "yesterday's news" "$T/out" && ok "feed: the first scan starts at the start of today" || fail "feed first scan since midnight"
! grep -q "MIT#1 passed\|added to a channel" "$T/out" && ok "feed zulip: bots' messages aren't read (nor a system bot's)" || fail "feed bots: $(cat "$T/out")"
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["feed"]={"zulip": {"bots": True}}; json.dump(c, open(p,"w"))' "$T/root/hq.json"
"$HQ" feed zulip --dry-run | grep -q "MIT#1 passed" && ok "feed zulip: bots are read when hq.json asks for them" || fail "feed bots on"
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c.pop("feed"); json.dump(c, open(p,"w"))' "$T/root/hq.json"
rm -f "$ZS/pages"; HQ_ZULIP_PAGE=1 "$HQ" feed zulip --dry-run | grep -q "2 messages, 1 conversations" && [ "$(wc -c <"$ZS/pages" | tr -d ' ')" = 6 ] && ok "feed: the first scan reads back a page at a time, to the start of today" || fail "feed first scan pages: $(cat "$ZS/pages")"
"$HQ" feed zulip --since 48 --dry-run | grep -q "yesterday's news" && ok "feed --since: the first scan looks back that many hours" || fail "feed --since"
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["feed"]={"zulip": {"mentions": True}}; json.dump(c, open(p,"w"))' "$T/root/hq.json"
"$HQ" feed zulip --dry-run | grep -q "3 messages, 2 conversations (dry run" && [ ! -e "$T/root/secretary/feed/state.json" ] && ok "feed --dry-run: reads, saves nothing; mentions when hq.json asks for them" || fail "feed dry run"
FJ="$("$HQ" feed zulip --no-sort --json)"
echo "$FJ" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["messages"]==3 and r["conversations"]==2 and len(r["items"])==2, r' && ok "feed zulip: one item per conversation" || fail "feed items"
FA="$(echo "$FJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0])')"; FB="$(echo "$FJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][1])')"
hqi inbox --json | python3 -c '
import json,sys
x={n["id"]:n for n in json.load(sys.stdin)["items"]}["'"$FA"'"]
assert x["via"]=="zulip" and x["state"]=="unsorted" and x["msgs"]==[100,101], x
t=x["text"].split("\n")
assert t[0].startswith("Zulip · DM with Alice Wu · http://127.0.0.1:") and "#narrow/dm/7-Alice-Wu" in t[0], t
assert t[1].endswith("Alice Wu: the 4.2.7 perf plan passed on rc3") and t[2].endswith("me: great, thanks"), t' && ok "feed item: conversation link, who said what, own lines as context" || fail "feed item text"
ls "$T"/root/secretary/feed/zulip/*.jsonl >/dev/null && [ "$(cat "$T"/root/secretary/feed/zulip/*.jsonl | wc -l | tr -d ' ')" = 3 ] && ok "feed keeps the raw messages locally" || fail "feed raw"
! grep -q secret "$T/root/secretary/feed/state.json" && ok "feed state holds no key" || fail "key in state"
python3 -c 'import json,sys; u=json.load(open(sys.argv[1]))["zulip"]["users"]; assert u["50"] is True and u["66"] is True and u["7"] is False, u' "$T/root/secretary/feed/state.json" && ok "feed zulip remembers who is a bot" || fail "bot cache"
answer '{"kind":"note","task":"'"$ITA"'","text":"Alice on Zulip: 4.2.7 perf plan passed on rc3","confidence":0.9,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$FA" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="unsorted" and x["dest"]["kind"]=="note" and not x["skip"], x' && ! card "$ITA" | grep -q "Alice on Zulip: 4.2.7 perf plan" && grep -q "reached the user on Zulip" "$FAKE_DIR/args" && ok "feed sort: even a confident log line waits for a click, with the feed's prompt" || fail "feed note"
hqi inbox move --json --task="$ITA" -- "$FA" note >/dev/null && card "$ITA" | grep -q "Alice on Zulip: 4.2.7 perf plan" && card "$ITA" | grep -q "#narrow/dm/7-Alice-Wu" && ok "feed: taking the guess files it, the conversation link as a ref" || fail "feed ref"
answer '{"kind":"todo","task":"'"$ITB"'","owner":"me","text":"Review the release notes (Bob)","confidence":0.95,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$FB" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="unsorted" and x["dest"]["kind"]=="todo", x' && ! card "$ITB" | grep -q "release notes" && ok "feed sort: a todo waits for a click, however sure" || fail "feed todo waits"
[ -z "$("$HQ" feed zulip --json --no-sort | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["items"]))')" ] && ok "feed: the next scan starts after the last message" || fail "feed cursor"
zmsg 103 dm 7 "Alice Wu" "lunch?"
zmsg 104 dm 1 "Me" "sure"
answer '{"kind":"skip","confidence":0.9,"reason":"chit-chat","alternatives":[]}'
FC="$("$HQ" feed zulip --claude "$FAKE" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["messages"]==2 and r["skipped"]==1, r; print(r["items"][0])')" && ok "feed zulip sorts what it adds; a likely skip is counted" || fail "feed sort run"
hqi inbox --json | python3 -c 'import json,sys; x=[n for n in json.load(sys.stdin)["items"] if n["id"]=="'"$FC"'"][0]; assert x["state"]=="unsorted" and x["skip"], x' && ok "a likely skip still waits on the board, marked skip" || fail "skip waits"
hqi inbox drop -- "$FC" >/dev/null && hqi inbox restore --json -- "$FC" | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="unsorted" and x["skip"], x' && ok "a dropped likely skip can be restored, folded as before" || fail "skip restore"
hqi inbox move --json --task="$ITA" -- "$FC" note | python3 -c 'import json,sys; x=json.load(sys.stdin); assert x["state"]=="sorted" and not x["skip"], x' && ok "a likely skip can still be filed" || fail "skip filed"
zmsg 105 dm 1 "Me" "one more thing"
[ "$("$HQ" feed zulip --no-sort --json | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["messages"], len(r["items"]))')" = "1 0" ] && ok "feed: a conversation with only your own new lines adds nothing" || fail "feed own only"
"$HQ" feed | grep -q "zulip: last scan .*1 messages" && ok "feed status shows the last scan" || fail "feed status"
zmsg 106 dm 7 "Alice Wu" "ping"
ZFILE="$ZS/inject.json" zmsg 107 stream 9 "Bob Li" "@**Me** one more" m
ZFILE="$ZS/inject.json" zmsg 108 dm 7 "Alice Wu" "the plan is at https://example.com/plan-doc"
[ "$("$HQ" feed zulip --no-sort --json | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["messages"])')" = 1 ] && [ ! -e "$ZS/inject.json" ] && ok "feed zulip: messages that come in mid-scan are left out" || fail "feed zulip mid-scan"
FD="$("$HQ" feed zulip --no-sort --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["messages"]==2 and len(r["items"])==2, r; print(r["items"][1])')" && ok "feed zulip: …and come with the next scan, from both narrows" || fail "feed zulip next scan"
[ "$(echo "$FJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][1])')" = "$FB" ] && hqi inbox --json | python3 -c '
import json,sys
x={n["id"]:n for n in json.load(sys.stdin)["items"]}
b=x["'"$FB"'"]; d=x["'"$FD"'"]
assert "release notes" in b["text"] and "one more" in b["text"] and b["msgs"]==[102,107] and not b.get("dest"), b
assert "ping" in d["text"] and "plan-doc" in d["text"] and d["msgs"]==[106,108] and d["text"].count("Zulip · DM with Alice Wu")==1, d' && ok "feed: news for a conversation still waiting joins its item, the guess cleared" || fail "feed merge"
answer '{"kind":"note","task":"'"$ITB"'","text":"Alice shared the plan","confidence":0.9,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" --json "$FD" >/dev/null; hqi inbox move --json --task="$ITB" -- "$FD" note >/dev/null
card "$ITB" | grep -q "Alice shared the plan" && card "$ITB" | grep -q "#narrow/dm/7-Alice-Wu" && ! card "$ITB" | grep -q "example.com/plan-doc" && ok "feed sort: only the conversation link becomes a ref, not links in the messages" || fail "feed refs first line"
printf '[api]\nemail=me@example.com\nkey=secret\nsite=http://localhost:%s\n' "$(cat "$ZS/port")" > "$HOME/.zuliprc"
"$HQ" feed zulip --since 48 --dry-run | grep -q "^zulip: 10 messages" && ok "feed zulip: another server starts over (the cursor is per site)" || fail "feed zulip site"
zmsg 109 dm 77 "Flaky Lookup" "hello there"
"$HQ" feed zulip --since 48 --dry-run | grep -q "hello there" && ok "feed zulip: a sender whose lookup fails is read, the scan goes on" || fail "feed lookup error"
printf 'email=me@example.com\nkey=SUPERSECRET\n' > "$HOME/.zuliprc"
"$HQ" feed zulip >"$T/out" 2>&1 || true; "$HQ" feed status --json >>"$T/out"; "$HQ" feed all >>"$T/out" 2>&1 || true
"$HQ" feed all --dry-run >"$T/out2" 2>&1 && fail "feed all --dry-run exits 0 on a failure"; grep -q "^zulip failed: can't read" "$T/out2" && ok "feed all --dry-run says which source failed, and fails" || fail "feed all dry run failure"
! grep -q SUPERSECRET "$T/out" && grep -q "can't read .*zuliprc (line 1): it should be an \[api\] section" "$T/out" && tail -1 "$T/out" | grep -q "^zulip failed: can't read" && ok "feed: an unreadable zuliprc fails feed all, and no error quotes the key" || fail "zuliprc error: $(cat "$T/out")"
printf '[api]\nemail=me@example.com\nkey=wrong\nsite=http://127.0.0.1:%s\n' "$(cat "$ZS/port")" > "$HOME/.zuliprc"
{ "$HQ" feed zulip 2>&1 || true; } | grep -q "HTTP 401 bad key" && ok "feed: a Zulip error is reported" || fail "feed error"
kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null || true; rm -f "$HOME/.zuliprc"

# hq feed jira: issues you are assignee, reporter or watcher of, from a fake Jira; one item per issue
# with what changed since the last scan, from someone else.
"$HQ" feed | grep -q "jira: not set up" && ok "feed without a Jira site: not set up" || fail "feed no jira"
{ "$HQ" feed all 2>&1 || true; } | grep -q "no feed is set up" && ok "feed all with nothing set up says so" || fail "feed all none"
JS="$T/jira"; mkdir -p "$JS"
cat > "$JS/server.py" <<'PY'
import http.server, json, sys, urllib.parse, os, datetime as dt
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        for pre, host in (("/same", "127.0.0.1"), ("/away", "localhost")):
            if u.path.startswith(pre):
                self.send_response(302)
                self.send_header("Location", f"http://{host}:{self.server.server_port}{u.path[len(pre):]}?{u.query}")
                self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.headers.get("Authorization") != "Basic bWVAZXhhbXBsZS5jb206dG9r":
            return self.reply(401, {"errorMessages": ["Client must be authenticated"]})
        if u.path == "/rest/api/2/myself":
            return self.reply(200, {"accountId": "me-1", "displayName": "Me"})
        assert u.path == "/rest/api/2/search/jql" and "changelog" in q["expand"], self.path
        mins = int(q["jql"].split("updated >= -")[1].split("m")[0])
        cut = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=mins)
        iss = [i for i in json.load(open(os.path.join(D, "issues.json")))
               if dt.datetime.strptime(i["fields"]["updated"], "%Y-%m-%dT%H:%M:%S.%f%z") >= cut]
        if os.path.exists(os.path.join(D, "dup")):  # two pages, the second repeats the first
            return self.reply(200, {"issues": iss, "isLast": False, "nextPageToken": "p2"} if "nextPageToken" not in q
                              else {"issues": iss, "isLast": True})
        self.reply(200, {"issues": iss, "isLast": True})
    def reply(self, code, d):
        b = json.dumps(d).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
jira() {  # key event(new|comment|status|old|late) author_id author_name [text]: adds to the fake issues
  python3 - "$JS/issues.json" "$@" <<'PY'
import json, sys, os, datetime as dt
p, key, ev, aid, name = sys.argv[1:6]; text = sys.argv[6] if len(sys.argv) > 6 else ""
ts = lambda h=0: (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%S.000+0000")
iss = json.load(open(p)) if os.path.exists(p) else []
i = next((x for x in iss if x["key"] == key), None)
if not i:
    i = {"key": key, "fields": {"summary": f"Fix the loader ({key})", "status": {"name": "Open"}, "priority": {"name": "Major"},
         "issuetype": {"name": "Bug"}, "assignee": {"accountId": "me-1", "displayName": "Me"},
         "reporter": {"accountId": aid, "displayName": name}, "created": ts(100), "updated": ts(100),
         "description": "", "comment": {"comments": []}}, "changelog": {"histories": []}}
    iss.append(i)
f, who = i["fields"], {"accountId": aid, "displayName": name}
nid = str(1 + sum(len(x["fields"]["comment"]["comments"]) + len(x["changelog"]["histories"]) for x in iss))
if ev == "new":
    f["created"] = ts(); f["description"] = text
elif ev == "comment":
    f["comment"]["comments"].append({"id": nid, "author": who, "body": text, "created": ts(), "updated": ts()})
elif ev == "status":
    i["changelog"]["histories"].append({"id": nid, "author": who, "created": ts(), "items": [{"field": "status", "fromString": "Open", "toString": text}]})
elif ev in ("old", "late"):  # a comment from 50 hours ago; one from 3 minutes ago that search only now finds
    h = 50 if ev == "old" else 0.05
    f["comment"]["comments"].append({"id": nid, "author": who, "body": text, "created": ts(h), "updated": ts(h)})
f["updated"] = ts({"old": 50, "late": 0.05}.get(ev, 0))
json.dump(iss, open(p, "w"))
PY
}
jira QA-1 new u-7 "Alice Wu" "the loader drops rows"
jira QA-1 comment u-7 "Alice Wu" "[~accountid:me-1] can you take this one?"
jira QA-2 old u-8 "Bob Li" "long ago"
jira QA-2 status u-8 "Bob Li" "In Progress"
jira QA-3 comment me-1 "Me" "my own note"
python3 "$JS/server.py" "$JS" & JPID=$!; trap 'kill "$JPID" "$ZPID" 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$JS/port" ] && break; sleep 0.1; done
export HQ_JIRA_EMAIL=me@example.com HQ_JIRA_TOKEN=tok
"$HQ" feed jira --site "http://127.0.0.1:$(cat "$JS/port")" --dry-run | grep -q "jira: 2 issues (dry run" && [ ! -e "$T/root/secretary/feed/jira" ] && ok "feed jira --dry-run: reads, saves nothing" || fail "jira dry run"
grep -q '"jira": "http://127.0.0.1:' "$HOME/.claude/hq/config.json" && ! grep -q 127.0.0.1 "$T/root/hq.json" && ok "feed jira --site is remembered in this machine's config.json, not hq.json" || fail "jira site saved"
JJ="$("$HQ" feed jira --no-sort --json)"
echo "$JJ" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["conversations"]==2 and len(r["items"])==2, r' && ok "feed jira: one item per issue; an issue with only your own changes adds nothing" || fail "jira items"
hqi inbox --json | python3 -c '
import json,sys
xs={n["id"]:n for n in json.load(sys.stdin)["items"]}
x=[n for n in xs.values() if n.get("issue")=="QA-2"][0]; t=x["text"].split("\n")
assert x["via"]=="jira", x
assert t[0].startswith("Jira · QA-2: Fix the loader (QA-2) · http://127.0.0.1:") and t[0].endswith("/browse/QA-2"), t
assert "you: assignee" in t[1] and t[2].endswith("Bob Li: status: Open → In Progress") and len(t)==3, t
a=[n for n in xs.values() if n.get("issue")=="QA-1"][0]["text"]
assert "Alice Wu: created it: the loader drops rows" in a and "Alice Wu: commented: @me can you take this one?" in a, a' && ok "feed jira item: issue link, its state, your role, what changed (old comments left out, mentions of you as @me)" || fail "jira item text"
ls "$T"/root/secretary/feed/jira/*.jsonl >/dev/null && ! grep -q '"tok"\|tok"' "$T/root/secretary/feed/state.json" && ok "feed jira keeps the raw issues, and no token" || fail "jira raw"
[ -z "$("$HQ" feed jira --json --no-sort | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["items"]))')" ] && ok "feed jira: the next scan re-reads the last minutes but adds nothing it has seen" || fail "jira cursor"
jira QA-3 late u-8 "Bob Li" "found it late"
"$HQ" feed jira --json --no-sort | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["conversations"]==1, r' && ok "feed jira: a change Jira's search finds late, from before the cursor, still comes" || fail "jira late"
jira QA-1 comment u-7 "Alice Wu" "any news?"
answer '{"kind":"skip","confidence":0.9,"reason":"nothing new","alternatives":[]}'
"$HQ" feed all --claude "$FAKE" >"$T/out" 2>&1; tail -1 "$T/out" | grep -q "^jira 1 → to review 0, likely skip 1" && grep -q "one Jira issue the user is assignee" "$FAKE_DIR/args" && [ "$(cat "$FAKE_DIR/token")" = none ] && ok "feed all scans what is set up, sorts with the Jira prompt (not given the token), sums up on one line" || fail "feed all"
touch "$JS/dup"; jira QA-1 comment u-7 "Alice Wu" "and?"
"$HQ" feed jira --dry-run | grep -q "^jira: 1 issues" && ok "feed jira: an issue on two pages is one item" || fail "jira dup pages"
rm "$JS/dup"
JP="$(cat "$JS/port")"
HQ_JIRA_SITE="http://127.0.0.1:$JP/same" "$HQ" feed jira --dry-run | grep -q "^jira: " && ok "feed jira: the token follows a redirect on the same host" || fail "jira same-host redirect"
{ HQ_JIRA_SITE="http://127.0.0.1:$JP/away" "$HQ" feed jira --dry-run 2>&1 || true; } | grep -q "HTTP 401" && ok "feed jira: …but not to another host" || fail "jira redirect away"
printf '[api]\nemail=me@example.com\nkey=secret\nsite=http://127.0.0.1:1\n' > "$HOME/.zuliprc"
python3 -c 'import fcntl,os,sys,time; os.makedirs(os.path.dirname(sys.argv[1]),exist_ok=True); f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' "$HOME/.claude/hq/state/locks/feed-zulip.lock" "$T/locked" & LPID=$!
for _ in $(seq 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
! "$HQ" feed all --no-sort >"$T/out" 2>&1 && tail -1 "$T/out" | grep -q "^jira 1 · zulip failed: a zulip scan is already running" && ok "feed all: a source already scanning fails, the others still run" || fail "feed all lock: $(cat "$T/out")"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null || true; rm -f "$HOME/.zuliprc"
"$HQ" feed | grep -q "jira: last scan .*1 issues" && ok "feed status shows the Jira scan" || fail "jira status"
export HQ_JIRA_TOKEN=wrong
{ "$HQ" feed jira 2>&1 || true; } | grep -q "HTTP 401 Client must be authenticated" && ok "feed: a Jira error is reported" || fail "jira error"
! "$HQ" feed all >"$T/out" 2>&1 && tail -1 "$T/out" | grep -q "jira failed: Jira myself: HTTP 401" && ok "feed all: a failed source fails the run, named on the last line" || fail "feed all failure"
unset HQ_JIRA_EMAIL HQ_JIRA_TOKEN
kill "$JPID" 2>/dev/null; wait "$JPID" 2>/dev/null || true

# hq jumps: the pet's jump log, last N days, by state x source.
mkdir -p "$HOME/.claude/pet"
NOW="$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
cat > "$HOME/.claude/pet/jumps.jsonl" <<EOF
{"at":"$NOW","session":"a","source":"board-card","state":"permission","peekedAgo":30}
{"at":"$NOW","session":"b","source":"pet-list","state":"replied"}
{"at":"$NOW","session":"b","source":"board-peek","state":"replied","peekedAgo":5000}
{"at":"2020-01-01T00:00:00Z","session":"old","source":"hotkey","state":"question"}
{"at":"$NOW","session":"odd","source":["x"],"state":7}
{"at":"$NOW","session":"c","source":"pet-list","state":"replied","terminal":"board"}
[1, 2]
not json
EOF
"$HQ" jumps --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["total"]==4 and r["boardOpens"]==1 and r["grid"]["7"]=={"[\x27x\x27]":1} and r["grid"]["replied"]=={"pet-list":1,"board-peek":1} and r["peekedFirst"]=={"permission":1} and r["states"]==["permission","replied","7"], r' && ok "hq jumps counts the last week by state x source" || fail "hq jumps"
"$HQ" jumps | grep -q "^permission " && ok "hq jumps prints a table" || fail "hq jumps table"
rm "$HOME/.claude/pet/jumps.jsonl"; "$HQ" jumps | grep -q "no jumps" && ok "hq jumps without a log says so" || fail "hq jumps empty"

# automatic status: waiting-on-me ↔ active follow the asks and @me todos; nothing else moves by itself
AS="$("$HQ" new "Auto status" --no-focus | head -1)"; CA="$(ls "$T"/root/tasks/$AS-*/TASK.md)"
"$HQ" bind "$AS" --session sess-as >/dev/null
st() { sed -n '/^---$/,/^---$/p' "$CA" | sed -n 's/^status: //p'; }
stop sess-as "$(printf 'First question.\n```hq-asks\n- Which dataset?\n```')" >/dev/null
[ "$(st)" = waiting-on-me ] && grep -q "active → waiting-on-me (auto" "$CA" && ok "auto status: a new ask with no status written puts an active task waiting on you" || fail "ask did not wait: $(st)"
"$HQ" ask resolve "$AS.1" do --via board --note "the big one" >/dev/null
[ "$(st)" = active ] && grep -q "waiting-on-me → active (auto, board)" "$CA" && ok "auto status: answering the last ask makes it active again" || fail "answer did not settle: $(st)"
"$HQ" ask reopen "$AS.1" --via board >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: taking the answer back waits again" || fail "reopen: $(st)"
"$HQ" ask resolve "$AS.1" do --via board >/dev/null
stop sess-as "$(printf 'Two things.\n```hq-asks\n- Ship on Friday?\n- Which region?\n```')" >/dev/null
"$HQ" ask resolve "$AS.2" do --via board >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: one ask still open keeps it waiting" || fail "settled early: $(st)"
"$HQ" ask snooze "$AS.3" --via board >/dev/null; "$HQ" ask reopen "$AS.2" --via board >/dev/null; "$HQ" ask resolve "$AS.2" do --via board >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: a snoozed ask is still open" || fail "snoozed: $(st)"
"$HQ" addtodo "$AS" "@me send the form" >/dev/null
stop sess-as "$(printf 'Noted.\n```hq-resolved\n- %s.3 do: us-east\n```' "$AS")" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: an open @me todo keeps it waiting" || fail "todo ignored: $(st)"
"$HQ" addtodo "$AS" "@claude rerun" >/dev/null
stop sess-as "$(printf 'Thanks.\n```hq-update\ndone: send the form\n```')" >/dev/null
[ "$(st)" = active ] && ok "auto status: ticking off the last @me todo (an @claude one left) makes it active" || fail "todo done: $(st)"
N="$("$HQ" show "$AS" | grep -c '^- \[' || true)"
"$HQ" todo "$AS" "$((N-1))" open --via board >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: undoing that tick waits again" || fail "todo undo: $(st)"
"$HQ" todo "$AS" "$((N-1))" done --via board >/dev/null
"$HQ" set "$AS" status=waiting-on-me >/dev/null
stop sess-as "$(printf 'Done that.
```hq-update
done: rerun
```')" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: ticking an @claude todo leaves it waiting" || fail "@claude tick moved it: $(st)"
"$HQ" set "$AS" "waiting_on_me=sign the form" >/dev/null; "$HQ" addtodo "$AS" "@me sign" >/dev/null
stop sess-as "$(printf 'ok
```hq-update
done: sign
```')" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: the legacy waiting_on_me field keeps it waiting" || fail "legacy field: $(st)"
"$HQ" set "$AS" "waiting_on_me=" >/dev/null
"$HQ" set "$AS" status=waiting-on-me >/dev/null; "$HQ" addtodo "$AS" "@me approve" >/dev/null
N="$("$HQ" show "$AS" | grep -c '^- \[' || true)"
"$HQ" todo "$AS" "$N" drop --via board >/dev/null
[ "$(st)" = active ] && ok "auto status: dropping it on the board does too" || fail "board todo: $(st)"
"$HQ" set "$AS" status=active >/dev/null
stop sess-as "$(printf 'Asking, still working.\n```hq-update\nstatus: active\n```\n```hq-asks\n- Token?\n```')" >/dev/null
[ "$(st)" = active ] && ok "auto status: a status the reply wrote wins over its ask" || fail "status overridden: $(st)"
"$HQ" set "$AS" status=blocked >/dev/null
"$HQ" ask resolve "$AS.4" do --via board >/dev/null
[ "$(st)" = blocked ] && ok "auto status: blocked is never changed by an answer" || fail "blocked moved: $(st)"
"$HQ" set "$AS" status=waiting-on-me >/dev/null
stop sess-as "$(printf 'Ok.\n```hq-asks\n- Again?\n```\n```hq-update\nstatus: waiting-on-me\n```')" >/dev/null
stop sess-as "$(printf 'Got it.\n```hq-resolved\n- %s.5 do: yes\n```\n```hq-update\nstatus: waiting-on-me\nnext: wait\n```' "$AS")" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: answers recorded with a status written keep that status" || fail "said status lost: $(st)"
Q="$("$HQ" ask add "$AS" "Final?")"
[ "$(st)" = waiting-on-me ] || fail "not waiting before hq-resolved: $(st)"
stop sess-as "$(printf 'Recorded.\n```hq-resolved\n- %s do: yes\n```' "$Q")" >/dev/null
[ "$(st)" = active ] && ok "auto status: an hq-resolved block answering the last ask makes it active" || fail "hq-resolved settle: $(st)"
stop sess-as "$(printf 'One ask, one rejected status.\n```hq-asks\n- Which one?\n```\n```hq-update\nstatus: waiting-on-me\ndone: no such todo\n```')" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: a rejected block's status does not stop the ask's move" || fail "rejected status: $(st)"
"$HQ" set "$AS" status=active >/dev/null
stop sess-as "$(printf 'Template echoed.\n```hq-asks\n- And this?\n```\n```hq-update\nstatus: active | waiting-on-me | blocked | done | abandoned\n```')" >/dev/null
[ "$(st)" = waiting-on-me ] && ok "auto status: an echoed template's status does not either" || fail "placeholder status: $(st)"
for a in $("$HQ" asks "$AS" | grep -o "$AS\.[0-9]*" | sort -u); do "$HQ" ask resolve "$a" do --via board >/dev/null; done
[ "$(st)" = active ] || fail "asks left open: $(st)"
"$HQ" addtodo "$AS" "@me last one" >/dev/null; "$HQ" set "$AS" status=waiting-on-me >/dev/null
F="$(grep -c 'waiting-on-me → active (auto' "$CA")"
stop sess-as "$(printf 'Next question.\n```hq-update\ndone: last one\n```\n```hq-asks\n- Next?\n```')" >/dev/null
[ "$(st)" = waiting-on-me ] && [ "$(grep -c 'waiting-on-me → active (auto' "$CA")" = "$F" ] && ok "auto status: a reply that ticks the last @me todo and asks again stays waiting, no back-and-forth" || fail "flip-flop: $(st)"
OT="$("$HQ" new "Other task" --no-focus | head -1)"; "$HQ" ask add "$OT" "Other?" >/dev/null; "$HQ" set "$OT" status=waiting-on-me >/dev/null
stop sess-as "$(printf 'Answered for the other task too.\n```hq-resolved\n- %s.1 do: yes\n```' "$OT")" >/dev/null
sed -n '/^---$/,/^---$/p' "$T"/root/tasks/$OT-*/TASK.md | grep -q '^status: active' && ok "auto status: an hq-resolved answer for another task settles that task" || fail "other task not settled"
"$HQ" set "$AS" status=blocked >/dev/null
stop sess-as "$(printf 'Waiting on the review.\n```hq-update\ntodo: @me merge once reviewed\n```')" >/dev/null
[ "$(st)" = blocked ] && ok "auto status: a new @me todo leaves a blocked task blocked" || fail "blocked moved by a todo: $(st)"
stop sess-as "$(printf 'A question.\n```hq-asks\n- Which branch?\n```')" >/dev/null
[ "$(st)" = waiting-on-me ] && grep -q 'status blocked → waiting-on-me (auto, session): a new question for you' "$CA" \
  && ok "auto status: a new ask on a blocked task makes it waiting-on-me, logged" || fail "blocked + ask: $(st)"
"$HQ" set "$AS" status=blocked >/dev/null
stop sess-as "$(printf 'Still stuck.\n```hq-asks\n- Ping them?\n```\n```hq-update\nstatus: blocked\n```')" >/dev/null
[ "$(st)" = blocked ] && ok "auto status: an ask with status: blocked written stays blocked" || fail "said blocked lost: $(st)"
"$HQ" ask add "$AS" "From the CLI?" >/dev/null
[ "$(st)" = blocked ] && ok "auto status: hq ask add leaves a blocked task blocked" || fail "cli ask moved blocked: $(st)"
"$HQ" set "$AS" status=done >/dev/null
stop sess-as "$(printf 'One more.\n```hq-asks\n- Reopen it?\n```')" >/dev/null
[ "$(st)" = done ] && ok "auto status: an ask on a done task leaves it done" || fail "done moved: $(st)"
"$HQ" unbind --session sess-as >/dev/null

# Card budget: closed todos past the newest 5, todo ticks, log entries past the newest 20 and process
# links (builds, runs, comments) move to HISTORY.md next to the card; nothing is lost.
BT="$("$HQ" new "Budget" --no-focus | head -1)"; BC="$(ls "$T"/root/tasks/$BT-*/TASK.md)"; BH="$(dirname "$BC")/HISTORY.md"
for i in 1 2 3 4 5 6 7 8; do "$HQ" addtodo "$BT" "@claude step $i" >/dev/null; done
for i in 1 2 3 4 5 6 7; do "$HQ" todo "$BT" "$i" done --text "step $i" >/dev/null; done
[ "$(grep -c '^- \[x\]' "$BC")" = 5 ] && grep -q '^- \[ \] @claude step 8' "$BC" && ! grep -q 'step 1 \|step 2 ' "$BC" \
  && ok "budget: the card keeps the 5 most recently closed todos and every open one" || fail "closed todos on card: $(grep '^- \[' "$BC")"
[ "$(sed -n '/^## Todos/,/^## /p' "$BH" | grep -c '^- \[x\] @claude step [12] ')" = 2 ] && ok "budget: the older closed todos are in HISTORY.md" || fail "history todos: $(cat "$BH")"
! grep -q 'todo #' "$BC" && [ "$(grep -c ': todo #[0-9]* → done (cli): ' "$BH")" = 7 ] && ok "budget: todo ticks go to HISTORY.md, not the card's log" || fail "ticks: $(grep 'todo #' "$BC" "$BH")"
"$HQ" board --json | python3 -c "import json,sys; t=[x for x in json.load(sys.stdin)['tasks'] if x['id']=='$BT'][0]; assert sum(1 for d in t['todos'] if d['state']=='done')==5, t['todos']" && ok "budget: board json shows the card's todos" || fail "board todos"
for i in $(seq 1 25); do "$HQ" log "$BT" "note $i" >/dev/null; done
[ "$(sed -n '/^## Log/,$p' "$BC" | grep -c ': note ')" = 20 ] && grep -q ': note 25$' "$BC" && ! grep -q ': note 5$' "$BC" \
  && grep -q ': note 1$' "$BH" && grep -q ': note 5$' "$BH" && ok "budget: the card keeps the newest 20 log entries, the rest go to HISTORY.md" || fail "log budget: $(sed -n '/^## Log/,$p' "$BC")"
blast() { "$HQ" board --json | python3 -c 'import json,sys; print([t for t in json.load(sys.stdin)["tasks"] if t["id"]=="'"$BT"'"][0]["lastActive"])'; }
newest="$(grep -hoE "^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" "$BC" "$BH" | cut -c3- | sort | tail -1)"
[ "$(blast)" = "$newest" ] && ok "board json: lastActive is the newest log line's time, to the second" || fail "lastActive: $(blast) vs $newest"
cp "$BH" "$BH.bak"; python3 - "$BH" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("## Log\n", "## Log\n- 2099-01-02 03:04:05: later\n", 1))
PY
[ "$(blast)" = "2099-01-02 03:04:05" ] && ok "...counting the log lines moved to HISTORY.md" || fail "lastActive history: $(blast)"
mv "$BH.bak" "$BH"
LT="$("$HQ" new "Last active" --no-focus | head -1)"; LC="$(ls "$T"/root/tasks/$LT-*/TASK.md)"
printf -- '- 2099-01-01: onboarded\n' >> "$LC"   # a date-only line (hq-onboard) is no time
"$HQ" log "$LT" "a note" >/dev/null; "$HQ" set "$LT" status=done >/dev/null
lt() { "$HQ" board --json | python3 -c 'import json,sys; t=[t for t in json.load(sys.stdin)["tasks"] if t["id"]=="'"$LT"'"][0]; print(t.get("closed_at",""), "|", t["lastActive"])'; }
python3 -c 'import sys; a,b=sys.argv[1].split(" | "); assert len(a)==19 and b==a, sys.argv[1]' "$(lt)" \
  && ok "closing writes closed_at, to the second, and lastActive is it (date-only log lines don't count)" || fail "closed_at: $(lt)"
"$HQ" ref add "$BT" "PR #5 https://github.com/o/r/pull/5" >/dev/null
"$HQ" ref add "$BT" "build #77 https://jenkins.example.com/job/x/77/" >/dev/null
"$HQ" ref add "$BT" "run https://github.com/o/r/actions/runs/123" >/dev/null
brefs() { "$HQ" board --json | python3 -c 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin)["tasks"] if t["id"]=="'"$BT"'"][0]["refs"], ensure_ascii=False))'; }
[ "$(brefs)" = '["PR #5 https://github.com/o/r/pull/5"]' ] && grep -qx -- '- build #77 https://jenkins.example.com/job/x/77/' "$BH" && grep -qx -- '- run https://github.com/o/r/actions/runs/123' "$BH" \
  && ok "budget: builds and runs are process links, kept in HISTORY.md" || fail "process links: $(brefs) / $(sed -n '/^## Links/,/^## /p' "$BH")"
"$HQ" ref pin "$BT" "build #77 https://jenkins.example.com/job/x/77/" >/dev/null
[ "$(brefs)" = '["PR #5 https://github.com/o/r/pull/5", "! build #77 https://jenkins.example.com/job/x/77/"]' ] && ! grep -q 'job/x/77' "$BH" \
  && ok "ref pin keeps a process link on the card (key mark) and takes it out of HISTORY.md" || fail "pin: $(brefs)"
"$HQ" ref add "$BT" "build #77 passed https://jenkins.example.com/job/x/77/" >/dev/null
[ "$(brefs)" = '["PR #5 https://github.com/o/r/pull/5", "! build #77 passed https://jenkins.example.com/job/x/77/"]' ] && ok "a pinned link keeps its mark when a newer title merges in" || fail "pin merge: $(brefs)"
out="$("$HQ" ref remove "$BT" "https://github.com/o/r/actions/runs/123")"
[ "$out" = '{"removed": [], "history": ["run https://github.com/o/r/actions/runs/123"]}' ] && ! grep -q 'runs/123' "$BH" && ok "ref remove takes a link out of HISTORY.md too" || fail "remove from history: $out"
"$HQ" ref restore "$BT" "$out" && grep -qx -- '- run https://github.com/o/r/actions/runs/123' "$BH" && ok "ref restore puts it back in HISTORY.md" || fail "restore history: $(cat "$BH")"
"$HQ" bind "$BT" --session sess-bud >/dev/null
stop sess-bud "$(printf 'ok\n```hq-update\nref!: build #78 https://jenkins.example.com/job/x/78/\nref: build #79 https://jenkins.example.com/job/x/79/\n```')" >/dev/null
brefs | grep -q '"! build #78 https://jenkins.example.com/job/x/78/"' && ! brefs | grep -q '/79/' && grep -q 'job/x/79/' "$BH" \
  && ok "hq-update: ref! keeps a build on the card, ref: sends it to HISTORY.md" || fail "ref!: $(brefs)"
python3 - "$T/root/hq.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["process_links"] = ["/releases/runs/"]; json.dump(c, open(p, "w"))
PY
"$HQ" ref add "$BT" "run #9 https://qa.example.com/releases/runs/all/9" >/dev/null
! brefs | grep -q 'runs/all/9' && grep -q 'runs/all/9' "$BH" && ok "hq.json process_links adds URL patterns" || fail "process_links: $(brefs)"
c="$(hook '{"session_id":"sess-bud","hook_event_name":"SessionStart"}')"
echo "$c" | grep -q "$BT's history is in .*HISTORY.md" && ok "SessionStart says where the history is, to read only when needed" || fail "no history note: $c"
"$HQ" board --json | python3 -c "
import json,sys
t=[x for x in json.load(sys.stdin)['tasks'] if x['id']=='$BT'][0]
h=t['history']; assert any('note 1' in l for l in h['log']) and any(x['text']=='step 1' for x in h['todos']) and any('runs/all/9' in x for x in h['links']), h
assert t['historyInfo']['log'] >= 12, t['historyInfo']" && ok "board json carries the history" || fail "board history"
# A repeated done: for a todo already in HISTORY.md is a no-op (no substring match on another
# open todo); the block's other lines still apply. A repeated log: already in HISTORY.md is not re-added.
"$HQ" addtodo "$BT" "@claude step 1 again" >/dev/null
stop sess-bud "$(printf 'ok\n```hq-update\ndone: step 1\nlog: note 1\nlog: after the repeat\n```')" >/dev/null
grep -q '^- \[ \] @claude step 1 again' "$BC" && grep -q ': after the repeat$' "$BC" && ! grep -q ': note 1$' "$BC" \
  && ok "hq-update: done:/log: already in HISTORY.md are not applied again" || fail "settled repeat: $(grep 'step 1\|note 1\|repeat' "$BC")"
# Closed in the same second: the order they were ticked in decides which stay on the card.
OT="$("$HQ" new "Tie order" --no-focus | head -1)"; OC="$(ls "$T"/root/tasks/$OT-*/TASK.md)"
for i in 1 2 3 4 5 6 7; do "$HQ" addtodo "$OT" "@claude job $i" >/dev/null; done
for i in 7 6 5 4 3 2 1; do "$HQ" todo "$OT" "$i" done --text "job $i" >/dev/null; done
! grep -q 'job [67] ' "$OC" && [ "$(grep -c '^- \[x\] @claude job [1-5] ' "$OC")" = 5 ] && ok "budget: same-second ticks keep the latest closed on the card" || fail "tie order: $(grep '^- \[' "$OC")"
# A closed todo with nested lines in HISTORY.md: each todo line is its own item.
python3 - "$(dirname "$OC")/HISTORY.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("## Todos\n", "## Todos\n- [x] @me parent n\n  - [x] @claude child n\n", 1); open(p, "w", encoding="utf-8").write(s)
PY
"$HQ" board --json | python3 -c "
import json,sys
t=[x for x in json.load(sys.stdin)['tasks'] if x['id']=='$OT'][0]; xs=[d['text'] for d in t['history']['todos']]
assert 'parent n' in xs and 'child n' in xs, xs" && ok "board json: a nested closed todo in HISTORY.md shows as its own item" || fail "nested history todo"
# Taking a quick note back removes the process link it sent to HISTORY.md, and a card it made
# (which has only TASK.md and HISTORY.md) is removed.
NJ="$(hqi inbox add --json -- "build https://jenkins.example.com/job/y/5/ failed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
answer '{"kind":"todo","task":"'"$BT"'","owner":"claude","text":"look at build 5","refs":["https://jenkins.example.com/job/y/5/"],"confidence":0.95,"reason":"r","alternatives":[]}'
hqi inbox sort --claude "$FAKE" "$NJ" >/dev/null
grep -q 'job/y/5/' "$BH" && ! brefs | grep -q 'job/y/5' && hqi inbox move -- "$NJ" unsorted >/dev/null && ! grep -q 'job/y/5/' "$BH" \
  && ok "taking a note back removes its process link from HISTORY.md" || fail "inbox undo history: $(grep 'job/y' "$BH")"
NJ="$(hqi inbox add --json -- "new job https://jenkins.example.com/job/z/1/" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
answer '{"kind":"task","title":"Jenkins card","text":"t","refs":["https://jenkins.example.com/job/z/1/"],"confidence":0.9,"reason":"r","alternatives":[]}'
JT="$(hqi inbox sort --claude "$FAKE" --json "$NJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
[ -f "$(ls -d "$T"/root/tasks/$JT-*)/HISTORY.md" ] && hqi inbox move -- "$NJ" unsorted >/dev/null && ! ls -d "$T"/root/tasks/$JT-* >/dev/null 2>&1 \
  && ok "taking back an untouched new card removes it, HISTORY.md and all" || fail "inbox undo card with history: $(ls "$T"/root/tasks/$JT-* 2>&1)"
"$HQ" unbind --session sess-bud >/dev/null
python3 - "$SRC/bin/hq" <<'PY' && ok "continued_title re-dates a dated title, or marks it continued"
import os, datetime as dt, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))
from hqlib import continuation as hq
d = dt.date(2026, 11, 23); f = hq.continued_title
assert f("release test all 4.2.7 on 2026 Nov 22", d) == "release test all 4.2.7 on 2026 Nov 23"
assert f("run 2026-11-22", d) == "run 2026-11-23" and f("run 2026/11/2", d) == "run 2026/11/23"
assert f("跑 11月22日 回归", d) == "跑 11月23日 回归" and f("standup Nov 22", d) == "standup Nov 23"
assert f("卡片预算", d) == "卡片预算（续 11-23）" and f("Card budget", d) == "Card budget (cont. 11-23)"
assert f("4.2.7 release", d) == "4.2.7 release (cont. 11-23)"
assert f("run Nov 20, 2025 x", d) == "run Nov 23, 2026 x" and f("2025年11月20日 回归", d) == "2026年11月23日 回归"
assert f("Nov 20, then", d) == "Nov 23, then"
assert f("Decide 2 options", d) == "Decide 2 options (cont. 11-23)" and f("Junit 5 upgrade", d) == "Junit 5 upgrade (cont. 11-23)"
PY
# hq continue: the work goes on on a new card; the old one is closed and points at it.
CT="$("$HQ" new "Nightly 2026-01-05" --category benchmark --workdir "$T" --no-focus | head -1)"; CC="$(ls "$T"/root/tasks/$CT-*/TASK.md)"
python3 - "$CC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("<what done looks like>", "Nightly green").replace("<where it stands, 2-5 lines>", "two plans left")
open(p, "w", encoding="utf-8").write(s)
PY
"$HQ" addtodo "$CT" "@claude open one" >/dev/null; "$HQ" addtodo "$CT" "@me closed one" >/dev/null; "$HQ" todo "$CT" 2 done >/dev/null
python3 - "$CC" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^(- \[x\] @me closed one[^\n]*\n)", lambda m: m.group(1) + "  - [ ] @claude child still open\n", s, count=1)
s = s.replace("Nightly green\n", "Nightly green\n- [ ] acceptance: p99 < 10ms\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
"$HQ" ref add "$CT" "PR #8 https://github.com/o/r/pull/8" >/dev/null; "$HQ" set "$CT" "next=rerun the two plans" >/dev/null
"$HQ" focus add "$CT" >/dev/null
"$HQ" ask add "$CT" "Which plan first?" >/dev/null; "$HQ" ask add "$CT" "Rerun both?" >/dev/null
"$HQ" set "$CT" "status=blocked" >/dev/null
"$HQ" bind "$CT" --session sess-cont >/dev/null; hook '{"session_id":"sess-cont","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null
out="$("$HQ" continue "$CT" --json)"
NT="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["to"])')"; NC="$(ls "$T"/root/tasks/$NT-*/TASK.md)"
echo "$out" | python3 -c "import json,sys,datetime; r=json.load(sys.stdin); assert r['title']=='Nightly '+datetime.date.today().isoformat() and r['todos']==2 and r['sessions']==['sess-cont'] and r['asks']==[{'from':'$CT.1','to':r['to']+'.1'},{'from':'$CT.2','to':r['to']+'.2'}], r" \
  && ok "hq continue makes the new card (title re-dated) and says what came along" || fail "continue: $out"
grep -q '^- \[ \] @claude open one <!--t:' "$NC" && ! grep -q 'closed one' "$NC" && grep -q '^Nightly green$' "$NC" && grep -q '^two plans left$' "$NC" \
  && ok "the new card has the goal, status and open todos (with their times)" || fail "new card: $(cat "$NC")"
[ "$(grep -c 'acceptance: p99' "$NC")" = 1 ] && grep -q '^- \[ \] @claude child still open' "$NC" && grep -q '^status: blocked' "$NC" \
  && ok "continue: a goal checklist is not copied twice, an open child of a closed todo comes unindented, status carries" || fail "continue extras: $(cat "$NC")"
"$HQ" board --json | python3 -c "
import json,sys
ts={x['id']:x for x in json.load(sys.stdin)['tasks']}; o={a['id']:a for a in ts['$CT']['asks']}; n={a['id']:a for a in ts['$NT']['asks']}
assert o['$CT.1']['state']=='moved' and n['$NT.1']['state']=='open' and n['$NT.1']['text']=='Which plan first?' and n['$NT.1'].get('moved_from')=='$CT.1', (o, n)" \
  && ok "continue moves open asks to the new card under new ids" || fail "asks moved"
"$HQ" board --json | python3 -c "
import json,sys
ts={x['id']:x for x in json.load(sys.stdin)['tasks']}; n=ts['$NT']; o=ts['$CT']
assert n['refs']==['PR #8 https://github.com/o/r/pull/8'] and n['next']=='rerun the two plans' and n['category']=='benchmark' and n['workdirs']==['$T'], n
assert o['status']=='done' and 'continued in $NT' in o['body'] and 'continued from $CT' in n['body'], o" && ok "links, next, category and folders carried over; the old card is done and points at the new one" || fail "continue cards"
"$HQ" focus --json | python3 -c "import json,sys; ids=json.load(sys.stdin)['ids']; assert '$NT' in ids and '$CT' not in ids, ids" && ok "the new card takes the old one's place in Focus" || fail "focus after continue"
c="$(hook '{"session_id":"sess-cont","hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
echo "$c" | grep -q "$CT, was continued in $NT" && echo "$c" | grep -q "$CT.1 is now $NT.1" && ok "a session on the old card is moved and told on its next prompt, asks included" || fail "rebind note: $c"
"$HQ" ask resolve "$NT.1" do --via board --note "nightly first" >/dev/null
ctxof sess-cont | grep -q "^- $NT.1 \"Which plan first?\" → answer: nightly first" && ok "an answer to a moved ask reaches the session" || fail "moved ask answer: $(ctxof sess-cont)"
"$HQ" ask resolve "$CT.2" drop --via board >/dev/null
"$HQ" board --json | python3 -c "
import json,sys
n={a['id']:a for a in [x for x in json.load(sys.stdin)['tasks'] if x['id']=='$NT'][0]['asks']}; assert n['$NT.2']['state']=='drop', n" \
  && ok "resolving a moved ask by its old id resolves the new one" || fail "old id redirect"
"$HQ" continue "$CT" 2>/dev/null && fail "continued a done task" || ok "only an open task can be continued"
"$HQ" unbind --session sess-cont >/dev/null

# hq garden: what a weekly look over the board would tidy, and what was proposed already.
GS="$("$HQ" secretary --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"])')"
# Earlier sections leave look-alike cards ("p1 docs", "p2 docs 1"): out of the way, but $S4.
for x in $("$HQ" board --json | python3 -c 'import json,sys; print(" ".join(t["id"] for t in json.load(sys.stdin)["tasks"] if t["status"] in ("active","blocked","waiting-on-me")))'); do
  [ "$x" = "$S4" ] || [ "$x" = "$GS" ] || "$HQ" set "$x" status=abandoned >/dev/null
done
G1="$("$HQ" new "Rerun perf baseline on 4.2.7" --no-focus | head -1)"
G2="$("$HQ" new "perf baseline rerun for 4.2.7 release" --no-focus | head -1)"
G3="$("$HQ" new "Loader crash on upgrade" --no-focus | head -1)"
G4="$("$HQ" new "Write the customer reply" --no-focus | head -1)"
G5="$("$HQ" new "Rerun perf baseline on 4.2.7 — part 2 after $G1." --no-focus | head -1)"
"$HQ" ref add "$G3" "TSE-4242 https://jira.example.com/browse/TSE-4242" >/dev/null
"$HQ" ref add "$G4" "TSE-4242 https://jira.example.com/browse/TSE-4242" >/dev/null
"$HQ" ref add "$G4" "build 7 https://jenkins.example.com/job/x/7/" >/dev/null
"$HQ" garden --json > "$T/g.json"
python3 - "$T/g.json" "$S4" "$G1" "$G2" "$G3" "$G4" "$G5" "$GS" <<'PY2' && ok "garden: a zombie over budget, look-alike titles, a shared ticket; cards naming each other last" || fail "garden findings"
import json, sys
g = json.load(open(sys.argv[1])); s4, g1, g2, g3, g4, g5, sec = sys.argv[2:]
kinds = [(f["kind"], f["task"]) for f in g["findings"]]
assert ("zombie", s4) in kinds and ("over-budget", s4) in kinds, kinds
assert all(t != sec for _, t in kinds), kinds
pairs = [tuple(p["tasks"]) for p in g["duplicates"]]
assert (g1, g2) in pairs, pairs
shared = [p for p in g["duplicates"] if tuple(p["tasks"]) == (g3, g4)]
assert shared and shared[0]["sharedLinks"] == ["TSE-4242", "https://jira.example.com/browse/TSE-4242"], shared
assert pairs.index((g3, g4)) < pairs.index((g1, g2)), pairs      # a shared link first
named = [p for p in g["duplicates"] if g5 in p["tasks"] and g1 in p["tasks"]]
assert named and named[0]["mention"] and g["duplicates"][-1]["mention"], g["duplicates"]
assert all(not f["settled"] for f in g["findings"]), g["findings"]
PY2
# A hand-made card without an id is skipped, not a crash (the weekly report runs garden too).
mkdir -p "$T/root/tasks/noid" && printf -- '---\ntitle: "Rerun perf baseline by hand"\nstatus: active\n---\n\n## Goal\nx\n' > "$T/root/tasks/noid/TASK.md"
"$HQ" garden --json >/dev/null && ok "garden skips a card without an id" || fail "garden on a card without an id"
rm -rf "$T/root/tasks/noid"
"$HQ" garden | grep -q "^zombie: $S4 " && "$HQ" garden | grep -q "^duplicate? $G3 " && ok "garden prints the findings as text" || fail "garden text: $("$HQ" garden)"
"$HQ" ask add "$GS" "Close $S4 as abandoned (quiet since 2020)?" >/dev/null
GA="$("$HQ" asks "$GS" | grep -o "$GS\.[0-9]*" | tail -1)"
"$HQ" garden --json | python3 -c '
import json,sys; f=[x for x in json.load(sys.stdin)["findings"] if x["task"]=="'"$S4"'"]
assert f and all(x["settled"]=="open ask '"$GA"'" for x in f), f' && ok "garden: an open ask about a task settles its findings" || fail "garden open ask"
"$HQ" garden | grep -q "already proposed" && ok "garden text lists what was proposed already" || fail "garden already proposed"
"$HQ" ask resolve "$GA" drop >/dev/null
"$HQ" garden --json | python3 -c '
import json,sys; f=[x for x in json.load(sys.stdin)["findings"] if x["task"]=="'"$S4"'"]
assert f and all(x["settled"].startswith("declined") for x in f), f' && ok "garden: a no stands while the card is unchanged" || fail "garden declined"
sleep 1; "$HQ" log "$S4" "picked up again" >/dev/null
"$HQ" garden --json | python3 -c '
import json,sys; f=[x for x in json.load(sys.stdin)["findings"] if x["task"]=="'"$S4"'"]
assert [x["kind"] for x in f]==["over-budget"] and f[0]["settled"] is None, f' && ok "garden: a card written since the no is proposed again (and no longer a zombie)" || fail "garden after change"
"$HQ" report weekly --no-gh --json | python3 -c 'import json,sys; g=json.load(sys.stdin)["garden"]; assert g["duplicates"], g' \
  && "$HQ" report weekly --no-gh | grep -q "^## Tidying the board" && ! "$HQ" report daily --no-gh | grep -q "Tidying" \
  && ok "the weekly report's facts end with the board's tidying; the daily's don't" || fail "garden in weekly report"
for x in "$G1" "$G2" "$G3" "$G4" "$G5"; do "$HQ" set "$x" status=abandoned >/dev/null; done

# ---- hq autoclose: todos closed by their PR, Jira issue or Jenkins build
AC="$T/ac"; mkdir -p "$AC/bin"
cat > "$AC/bin/gh" <<'SH'
#!/bin/sh
# gh pr view <url> --json …: state (and closedAt) from $AC_STATES ("<url> <STATE> [closedAt]"); unknown → error
[ "$1" = auth ] && exit 0
s=$(grep -F "$3 " "$AC_STATES" | head -1 | cut -d' ' -f2); c=$(grep -F "$3 " "$AC_STATES" | head -1 | cut -d' ' -f3)
[ -n "$s" ] || { echo "no pull request found" >&2; exit 1; }
if [ -n "$c" ]; then c="\"$c\""; else c=null; fi
n=${3##*/}; echo "{\"number\":$n,\"title\":\"t$n\",\"state\":\"$s\",\"mergedAt\":null,\"closedAt\":$c,\"isDraft\":false}"
SH
# The keychain is never asked: a stub `security` that finds nothing.
printf '#!/bin/sh\necho "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2\nexit 44\n' > "$AC/bin/security"
chmod +x "$AC/bin/gh" "$AC/bin/security"
cat > "$AC/server.py" <<'PY'
import http.server, json, sys, os
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        st = json.load(open(os.path.join(D, "states.json")))
        if self.headers.get("Authorization") is None:
            return self.reply(401, {})
        p = self.path.split("?")[0]
        if p.startswith("/rest/api/2/issue/"):
            k = p.rsplit("/", 1)[1]
            if k not in st:
                return self.reply(404, {"errorMessages": ["Issue does not exist"]})
            cat = "done" if st[k] in ("Done", "Closed") else "indeterminate"
            return self.reply(200, {"key": k, "fields": {"status": {"name": st[k], "statusCategory": {"key": cat}}}})
        if p.endswith("/api/json"):
            b = p[:-len("/api/json")]
            if b not in st:
                return self.reply(404, {})
            r = st[b]
            return self.reply(200, {"building": r == "RUNNING", "result": None if r == "RUNNING" else r,
                                    "fullDisplayName": "line one\nline two"})
        self.reply(404, {})
    def reply(self, code, d):
        b = json.dumps(d).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_port))
s.serve_forever()
PY
echo '{"QA-9": "Done", "QA-10": "In Progress", "/job/release_test/12": "SUCCESS", "/job/release_test/13": "FAILURE", "/job/release_test/14": "RUNNING", "/job/release_test/21": "SUCCESS", "/job/release_test/7": "SUCCESS"}' > "$AC/states.json"
python3 "$AC/server.py" "$AC" & APID=$!; trap 'kill "$APID" "$JPID" "$ZPID" 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$AC/port" ] && break; sleep 0.1; done
AS="http://127.0.0.1:$(cat "$AC/port")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "https://github.com/o/r/pull/5 MERGED" "https://github.com/o/r/pull/6 CLOSED 2020-01-01T00:00:00Z" "https://github.com/o/r/pull/7 OPEN" \
  "https://github.com/o/r/pull/8 CLOSED $NOW" > "$AC/prs"
acenv() { env PATH="$AC/bin:$PATH" AC_STATES="$AC/prs" HQ_JIRA_SITE="$AS" HQ_JIRA_EMAIL=me@example.com HQ_JIRA_TOKEN=tok HQ_JENKINS_SITE="$AS" HQ_JENKINS_USER=ci "$@"; }
acq() { acenv HQ_JENKINS_TOKEN=jt "$HQ" "$@"; }
A1="$("$HQ" new "Autoclose me" --no-focus | head -1)"
"$HQ" ref add "$A1" "https://github.com/o/r/pull/6" >/dev/null; "$HQ" ref add "$A1" "$AS/job/release_test/21/" >/dev/null
"$HQ" ref add "$A1" "$AS/job/release_test/7/" >/dev/null
for t in "@me review and merge https://github.com/o/r/pull/5/files" "@claude review #6" "@me 跟进 QA-9 里的问题" \
         "@me verify QA-10 (UTF-8 too)" "@me 等 $AS/job/release_test/12/console 跑完" "@me wait for $AS/job/release_test/13/" \
         "@me 合并 #7，等 $AS/job/release_test/14/ 跑完" "@me no link here" "@me merge #5, then reinstall" "@claude #5 合并后：重装" \
         "@me comment the result on https://github.com/o/r/pull/5" "@me watch #21" "@me 跟进QA-9里的回复" "@me review #8" \
         "@me 合并 #5 再重装" "@me merge #5 and reinstall" "@me 合并 #5，重装" "@me 写 #5 的审计报告" "@me 把 #21 的结果发给 Atul 等人"; do
  "$HQ" addtodo "$A1" "$t" >/dev/null; done
"$HQ" set "$A1" status=waiting-on-me >/dev/null
CARD="$(ls "$T"/root/tasks/"$A1"-*/TASK.md)"; cp "$CARD" "$AC/before"
acq autoclose --dry-run --json | python3 -c '
import json,sys; r=json.load(sys.stdin)
c={x["text"][:12]:x["state"] for x in r["closed"]}
assert r["todos"]==10 and r["dry"] and r["errors"]==[], r
assert c=={"review and m":"done","review #6":"drop","跟进 QA-9 里的问题":"done","等 http://127":"done","watch #21":"done","跟进QA-9里的回复":"done"}, c
w={x["text"][:8]:x["why"] for x in r["waiting"]}
assert "QA-10 In Progress" in w["verify Q"] and "failure" in w["wait for"] and "running" in w["合并 #7，等 "] and "o/r#7 open" in w["合并 #7，等 "], w
assert [x["why"] for x in r["waiting"] if x["text"] == "review #8"] == ["PR o/r#8 closed just now"], r["waiting"]' \
  && cmp -s "$CARD" "$AC/before" && ok "autoclose --dry-run: merged PR (link or #n via refs), Done issue, passed build (link or #n via the card's links) close; open, failed, running, just-closed wait; nothing written" || fail "autoclose dry run"
acq autoclose | tail -1 | grep -q "^10 todos with links → closed 5, dropped 1$" && ok "autoclose: the job's last line counts what it closed" || fail "autoclose summary"
grep -q "\[x\] @me review and merge" "$CARD" "$(dirname "$CARD")/HISTORY.md" && grep -q "\[-\] @claude review #6" "$CARD" && grep -q "\[x\] @me 跟进 QA-9" "$CARD" \
  && grep -q "\[ \] @me verify QA-10" "$CARD" && grep -q "\[ \] @me wait for" "$CARD" && grep -q "\[ \] @me no link here" "$CARD" \
  && ok "autoclose ticks and drops on the card; the rest stay open" || fail "autoclose card"
for t in "merge #5, then reinstall" "#5 合并后：重装" "comment the result on" "合并 #5 再重装" "merge #5 and reinstall" "合并 #5，重装" "写 #5 的审计报告" "把 #21 的结果发给 Atul 等人"; do
  grep -qF "[ ] @me $t" "$CARD" || grep -qF "[ ] @claude $t" "$CARD" || fail "autoclose closed: $t"; done
ok "autoclose leaves open a todo with a step after (then, 后：, 再, and …, a bare clause after a comma), or not about finishing it (审计, 等人)"
grep -q "auto-closed todo #[0-9]* (PR o/r#5 merged): review and merge .* — reopen it on the board or with hq todo $A1 [0-9]* open --text" "$CARD" \
  && grep -q "auto-dropped todo #[0-9]* (PR o/r#6 closed unmerged)" "$CARD" && grep -q "→ done (auto: PR o/r#5 merged)" "$(dirname "$CARD")/HISTORY.md" \
  && ! grep -q "line two" "$CARD" && ok "autoclose logs why on the card (a build by its short name) and the tick in HISTORY.md" || fail "autoclose log"
# The hint, run as written, reopens that todo, though its number moved since (the budget sent the
# first todo closed to HISTORY.md): --text finds it by its text.
UNDO="$(grep -o "hq todo $A1 [0-9]* open --text '跟进QA-9里的回复'" "$CARD")"
eval "\"\$HQ\" ${UNDO#hq }" >/dev/null && grep -q "\[ \] @me 跟进QA-9里的回复" "$CARD" && ok "the logged undo command reopens the right todo" || fail "autoclose undo: $UNDO"
acq autoclose --json | python3 -c '
import json,sys; r=json.load(sys.stdin); assert r["closed"]==[] and [x["text"] for x in r["reopened"]]==["跟进QA-9里的回复"], r' \
  && grep -q "\[ \] @me 跟进QA-9里的回复" "$CARD" && ok "autoclose leaves a todo you reopened alone" || fail "autoclose reopened"
python3 - "$T/root/secretary/autoclose.json" <<'PY' && acq autoclose >/dev/null && grep -q "\[ \] @me 跟进QA-9里的回复" "$CARD" && ok "a reopened todo stays remembered while it is open (past the 90 days)" || fail "autoclose reopened prune"
import json, sys; p = sys.argv[1]; d = json.load(open(p))
for v in d["closed"].values(): v["at"] = "2000-01-01T00:00:00"
d["final"] = {}; json.dump(d, open(p, "w"))
PY
python3 - "$AC/states.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["QA-10"] = "Done"; d["/job/release_test/14"] = "SUCCESS"; json.dump(d, open(p, "w"))
PY
sed -i '' 's#pull/7 OPEN#pull/7 MERGED#' "$AC/prs" 2>/dev/null || sed -i 's#pull/7 OPEN#pull/7 MERGED#' "$AC/prs"
acq autoclose >/dev/null && grep -q "\[x\] @me verify QA-10" "$CARD" && grep -q "\[x\] @me 合并 #7" "$CARD" && grep -q "\[ \] @me wait for" "$CARD" \
  && ok "autoclose: a todo naming several things closes once all are finished (UTF-8 isn't an issue); a failed build stays open; #7 next to 合并 is the PR, not build 7" || fail "autoclose all links"
python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["final"]; k="".join(f)
assert "/job/release_test/13" in k and "https://github.com/o/r/pull/7" in f and "pull/6" not in k and "pull/8" not in k and "QA-" not in k and "UTF-8" not in k, f' \
  "$T/root/secretary/autoclose.json" && ok "autoclose remembers merged PRs and finished builds; not closed PRs (they reopen), issues or 404s" || fail "autoclose final"
"$HQ" addtodo "$A1" "@me wait for build $AS/job/release_test/15/" >/dev/null
acq autoclose -v > "$AC/out" && grep -q "wait for build .* (release_test #15 not found)" "$AC/out" && grep -q "\[ \] @me wait for build" "$CARD" \
  && ok "a build that is gone (404) leaves its todo open, and isn't an error" || fail "autoclose 404 build: $(cat "$AC/out")"
"$HQ" addtodo "$A1" "@me watch $AS/job/release_test/16/" >/dev/null
acenv HQ_JENKINS_TOKEN= "$HQ" autoclose > "$AC/out" 2>&1 && fail "autoclose without a Jenkins token should fail" || true
grep -q "jenkins: no Jenkins API token in the keychain" "$AC/out" \
  && ok "autoclose: a source without credentials fails the run and says how to set it up" || fail "autoclose no token: $(cat "$AC/out")"
acenv HQ_JENKINS_TOKEN=jt HQ_JENKINS_SITE="${AS/http:/https:}" "$HQ" autoclose --dry-run --json | python3 -c '
import json,sys; r=json.load(sys.stdin); assert r["links"]["jenkins"]==0, r' && ok "autoclose sends Jenkins credentials only to the site, scheme too (no http when it is https)" || fail "autoclose scheme"
printf '#!/bin/sh\n[ "$1" = auth ] && exit 1\nexit 1\n' > "$AC/gh-out"; chmod +x "$AC/gh-out"; mkdir -p "$AC/bin2"; cp "$AC/gh-out" "$AC/bin2/gh"
env PATH="$AC/bin2:$AC/bin:$PATH" AC_STATES="$AC/prs" HQ_JENKINS_SITE= HQ_JIRA_SITE= "$HQ" autoclose > "$AC/out" 2>&1 && fail "autoclose with gh logged out should fail" || true
tail -1 "$AC/out" | grep -q "pr: gh can't reach GitHub" && ok "autoclose: gh logged out or offline fails the run" || fail "autoclose gh down: $(cat "$AC/out")"
"$HQ" site jenkins jenkins.example.com | grep -q "^jenkins: https://jenkins.example.com$" && grep -q '"jenkins": "https://jenkins.example.com"' "$HOME/.claude/hq/config.json" \
  && "$HQ" site jenkins - | grep -q "^jenkins: -$" && grep -q '"root"' "$HOME/.claude/hq/config.json" && ok "hq site keeps a site in this machine's config.json (root kept), and forgets it" || fail "hq site"
"$HQ" set "$A1" status=done >/dev/null
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null || true

# ---- intake: a duty's Auto intake makes tasks from GitHub review requests
IK="$T/intake"; mkdir -p "$IK/bin" "$T/work-rev"
cat > "$IK/bin/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "search prs") echo "$*" > "$IK/search-args"; cat "$IK/search.json" ;;
  "pr view") printf '{"headRefOid":"%s","headRefName":"feat-%s","baseRefName":"main"}\n' "$(cat "$IK/head" 2>/dev/null || echo abc)" "$3" ;;
  "api user") echo me ;;
  api*) cat "$IK/events" 2>/dev/null ;;
  *) exit 1 ;;
esac
SH
cat > "$IK/claude" <<'SH'
#!/bin/sh
if [ "$1" = agents ]; then echo '[{"id":"abcd1234","sessionId":"abcd1234-0000-4000-8000-000000000001"}]'; exit 0; fi
printf '%s\n' "$@" > "$IK/claude-args"; pwd -P > "$IK/claude-cwd"; echo "${CLAUDE_PET_JOB:-none} ${ORCA_TERMINAL_HANDLE:-none} ${TERM_PROGRAM:-none} ${ITERM_SESSION_ID:-none}" > "$IK/claude-env"; echo "Started background session abcd1234"
SH
chmod +x "$IK/bin/gh" "$IK/claude"
cat > "$IK/search.json" <<'JS'
[{"repository":{"nameWithOwner":"acme/web"},"number":12,"title":"Fix login","url":"https://github.com/acme/web/pull/12","author":{"login":"ann"},"isDraft":false},
 {"repository":{"nameWithOwner":"acme/web"},"number":13,"title":"WIP","url":"https://github.com/acme/web/pull/13","author":{"login":"ann"},"isDraft":true},
 {"repository":{"nameWithOwner":"other/lib"},"number":5,"title":"Bump","url":"https://github.com/other/lib/pull/5","author":{"login":"bob"},"isDraft":false}]
JS
ik() { env IK="$IK" PATH="$IK/bin:$PATH" "$HQ" "$@"; }
"$HQ" project add rev --kind duty >/dev/null
printf '### github-review\nrepos: acme/web\nworkdir: %s\nrun: yes\npermissions: skip\n<!-- a note -->\nbogus: 1\ngoal: Look at it.\nNote: carefully\nprompt: Review {url} by {author}.\n\n### Steps\n<keep this>\nKeep it short.\n### jira-filter\nrepos: x\n' "$T/work-rev" | "$HQ" project section rev intake >/dev/null
"$HQ" project show rev --json | python3 -c '
import json,sys; i=json.load(sys.stdin)["intake"]; c=i["github-review"]
assert c["repos"]==["acme/web"] and c["run"] is True and c["permissions"]=="review" and c["done"]=="manual" and c["focus"] is True, c
assert c["prompt"]=="Review {url} by {author}.\n\n### Steps\n<keep this>\nKeep it short." and c["goal"]=="Look at it.\nNote: carefully", c
assert len(c["problems"])==1 and "unknown key" in c["problems"][0], c
assert "makes no tasks yet" in i["jira-filter"]["problems"][0], i' \
  && grep -q "^## Auto intake" "$T/root/projects/rev/PROJECT.md" && ok "intake section: repos, switches, defaults, a prompt kept as written (### Steps, <…> lines) up to the next source, goal lines, unknown keys and sources flagged" || fail "intake section"
ik intake | tail -1 | grep -q "github-review: no duty set up" && [ ! -f "$IK/search-args" ] && ok "intake: a section without the switch on asks GitHub nothing" || fail "intake off"
"$HQ" project set rev auto=github-review >/dev/null
N0="$(ls "$T/root/tasks" | wc -l)"
ik intake --dry-run | tail -1 | grep -q "github-review: 1 waiting, 1 new" && [ "$(ls "$T/root/tasks" | wc -l)" = "$N0" ] && ok "intake --dry-run: drafts and other repos left out, nothing made" || fail "intake dry run"
CLAUDE_PET_JOB=intake-scan ORCA_TERMINAL_HANDLE=term_stale TERM_PROGRAM=Orca ITERM_SESSION_ID=w0t0p0:AB ik intake --claude "$IK/claude" --json > "$IK/out.json"
IT="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"][0]; m=r["made"]; assert len(m)==1 and m[0]["session"].startswith("abcd1234"), r; print(m[0]["task"])' "$IK/out.json")"
ITC="$(ls "$T"/root/tasks/$IT-*/TASK.md)"
grep -q '^project: rev' "$ITC" && grep -q '^intake: github-review' "$ITC" && grep -q '^intake_key: acme/web#12' "$ITC" && grep -q '^intake_done: manual' "$ITC" \
  && grep -q 'PR acme/web#12 https://github.com/acme/web/pull/12' "$ITC" && grep -q '^Note: carefully$' "$ITC" \
  && grep -q 'title: "Review web#12: Fix login"' "$ITC" && grep -q '"abcd1234"' "$ITC" && grep -q "review-requested=@me" "$IK/search-args" \
  && ok "intake: a task in the duty, marked as come in by itself, with the PR as a ref, the default title and the section's goal" || fail "intake task: $(cat "$ITC")"
grep -qx -- "--bg" "$IK/claude-args" && grep -q "^Start by running \`.*/hq bind $IT\`" "$IK/claude-args" \
  && [ "$(grep -B1 "^Start by running" "$IK/claude-args" | head -1)" = "--" ] \
  && ! grep -q -- "--dangerously-skip-permissions" "$IK/claude-args" && grep -A1 -x -- "--permission-mode" "$IK/claude-args" | grep -qx dontAsk \
  && grep -qx "Skill(code-review)" "$IK/claude-args" && grep -qx "Bash(gh pr diff https://github.com/acme/web/pull/12:\*)" "$IK/claude-args" \
  && grep -qx "Bash(.*/hq bind $IT)" "$IK/claude-args" && ! grep -qxE "Edit|Write|WebFetch|Bash|Skill|Bash\(gh pr (view|diff|checks):\*\)" "$IK/claude-args" \
  && grep -q "never write \`status: done\`" "$IK/claude-args" && grep -q "Then: Review https://github.com/acme/web/pull/12 by ann." "$IK/claude-args" \
  && grep -q "Keep it short." "$IK/claude-args" && [ "$(cat "$IK/claude-cwd")" = "$(cd "$T/work-rev" && pwd -P)" ] && [ "$(cat "$IK/claude-env")" = "none none none none" ] \
  && ok "intake run: a background session in the workdir, told to bind, never skipping permissions (permissions: skip is review — dontAsk, read-only tools, Skill only code-review, gh only on this PR, the prompt after --), with the filled prompt and the manual-done rule, not as the pet's job nor in hq's terminal tab" || fail "intake launch: $(cat "$IK/claude-args")"
"$HQ" bind "$IT" --session sess-ik | grep -q "came in by itself and the user closes it" && "$HQ" unbind --session sess-ik >/dev/null && ok "a bound session is told it doesn't close the task" || fail "intake protocol"
mv "$T/root/secretary/intake/state.json" "$IK/state.bak"
ik intake --claude "$IK/claude" | tail -1 | grep -q "0 new tasks" && ok "intake: an open card for the PR is enough, state or not (a scan stopped part-way)" || fail "intake dedup by card"
mv "$IK/state.bak" "$T/root/secretary/intake/state.json"
ik intake --claude "$IK/claude" | tail -1 | grep -q "github-review: 1 waiting, 0 new tasks" && ok "intake: a PR whose task is open makes no other" || fail "intake repeat"
MSG='done\n\n```hq-update\nstatus: done\n```'
hook "{\"session_id\":\"abcd1234-0000-4000-8000-000000000001\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" | grep -q "the user closes it" \
  && grep -q '^status: active' "$ITC" && ok "a session can't close a task that came in by itself (done: manual)" || fail "intake manual done: $(grep status: "$ITC")"
"$HQ" ask add "$IT" "Post the comments?" >/dev/null
hook "{\"session_id\":\"abcd1234-0000-4000-8000-000000000001\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" | grep -q "the user closes it" \
  && ok "…nor hold a close over open asks" || fail "intake manual done with asks"
SETOUT="$(CLAUDE_CODE_SESSION_ID=sess-x "$HQ" set "$IT" status=done 2>&1 || true)"; echo "$SETOUT" | grep -q "the user closes it" && ! grep -q "^status: done" "$ITC" && ok "…nor hq set from inside a session" || fail "intake hq set guard"
"$HQ" set "$IT" status=done >/dev/null
echo "2020-01-01T00:00:00Z" > "$IK/events"; echo def > "$IK/head"
ik intake --claude "$IK/claude" | tail -1 | grep -q "0 new tasks" && ok "intake: closed, and not asked again since (new commits or not): no new task" || fail "intake closed not asked"
python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))' >> "$IK/events"
IT2="$(ik intake --claude "$IK/claude" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["made"][0]["task"])')"
[ "$IT2" != "$IT" ] && ok "intake: asked again after it was closed: a new task" || fail "intake asked again"
"$HQ" set "$IT2" intake_done=auto >/dev/null
hook "{\"session_id\":\"abcd1234-0000-4000-8000-000000000001\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"$MSG\"}" >/dev/null
grep -q '^status: done' "$T"/root/tasks/$IT2-*/TASK.md && grep -q '^intake_closed_by: session' "$T"/root/tasks/$IT2-*/TASK.md && ok "done: auto — the session may close it, and it says so" || fail "intake auto done"
"$HQ" intake status --json | python3 -c '
import json,sys; s=json.load(sys.stdin); ids=[t["id"] for t in s["recent"]]
assert ids==[sys.argv[2], sys.argv[1]] and all(t["status"]=="done" for t in s["recent"]), s["recent"]
d=s["sources"]["github-review"]; assert d["last"]["made"]==[sys.argv[2]] and d["duties"][0]["name"]=="rev" and d["duties"][0]["problems"], d' "$IT" "$IT2" \
  && ok "intake status: recent tasks that came in by itself, done ones too, and the last scan" || fail "intake status"
python3 - "$IK/search.json" <<'PY'
import json, sys
json.dump([{"repository": {"nameWithOwner": "acme/web"}, "number": n, "title": f"PR {n}", "url": f"https://github.com/acme/web/pull/{n}",
            "author": {"login": "ann"}, "isDraft": False} for n in range(20, 25)], open(sys.argv[1], "w"))
PY
ik intake --claude "$IK/claude" | tail -1 | grep -q "github-review: 5 waiting, 3 new tasks (.*), 2 left for the next scan" \
  && ik intake --claude "$IK/claude" | tail -1 | grep -q "github-review: 5 waiting, 2 new tasks" && ok "intake: at most 3 new tasks a scan; the rest come next time" || fail "intake cap"
IC="$("$HQ" intake status --json | python3 -c 'import json,sys; print([t["id"] for t in json.load(sys.stdin)["recent"] if t["status"]!="done"][0])')"
ICN="$("$HQ" continue "$IC" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["to"])')"
grep -q '^intake_key: acme/web#' "$T"/root/tasks/$ICN-*/TASK.md && grep -q '^intake_done: manual' "$T"/root/tasks/$ICN-*/TASK.md && ok "hq continue carries what came in by itself" || fail "intake continue"
printf '### github-review\nrepos: acme/web\nworkdir: %s/nope\nrun: yes\n' "$T" | "$HQ" project section rev intake >/dev/null
"$HQ" project show rev --json | python3 -c 'import json,sys; c=json.load(sys.stdin)["intake"]["github-review"]; assert "no folder" in c["problems"][0], c' \
  && python3 -c 'import json; print(json.dumps([{"repository":{"nameWithOwner":"acme/web"},"number":30,"title":"X","url":"https://github.com/acme/web/pull/30","author":{"login":"ann"},"isDraft":False}]))' > "$IK/search.json" \
  && rm -f "$IK/claude-args" && ! ik intake --claude "$IK/claude" >/dev/null 2>&1 && [ ! -f "$IK/claude-args" ] \
  && IB="$(grep -l '^intake_key: acme/web#30' "$T"/root/tasks/*/TASK.md)" && grep -q '^status: waiting-on-me' "$IB" && grep -q 'could not start a background session: no folder to run in' "$IB" \
  && grep -q 'ann asked you to review https://github.com/acme/web/pull/30 (feat-30 → main)' "$IB" \
  && ok "intake: a workdir written wrong is flagged; no session starts anywhere else, the task (default goal) waits on you" || fail "intake bad workdir"
printf '### github-review\nrepos: *\nworkdir: %s\nrun: yes\npermissions: review\n' "$T/work-rev" | "$HQ" project section rev intake >/dev/null
"$HQ" project show rev --json | python3 -c 'import json,sys; c=json.load(sys.stdin)["intake"]["github-review"]; assert c["permissions"]=="review" and any(p.startswith("repos: *") for p in c["problems"]), c' \
  && python3 -c 'import json; print(json.dumps([{"repository":{"nameWithOwner":"zed/x"},"number":31,"title":"X","url":"https://github.com/zed/x/pull/31","author":{"login":"eve"},"isDraft":False}]))' > "$IK/search.json" \
  && rm -f "$IK/claude-args" && ! ik intake --claude "$IK/claude" >/dev/null 2>&1 && [ ! -f "$IK/claude-args" ] \
  && grep -q 'repos: \* with permissions: review' "$(grep -l '^intake_key: zed/x#31' "$T"/root/tasks/*/TASK.md)" \
  && ok "intake: repos: * with permissions: review is flagged, and no session starts — anyone could start one" || fail "intake any repo review"
"$HQ" project set rev auto= >/dev/null


# Asks written in a reply (T-116): parallel Stop hooks, multi-line asks, blocks that weren't
# applied, and Later from the chat.
"$HQ" new "Asks fixes" >/dev/null
AC="$(ls "$T"/root/tasks/T-*-asks-fixes/TASK.md)"; AID="$(basename "$(dirname "$AC")" | cut -d- -f1-2)"
"$HQ" bind "$AID" --session sess-ask >/dev/null
for i in 0 1 2 3 4 5; do
  stop sess-ask "$(printf 'ok\n```hq-asks\n- parallel question %s?\n```' $i)" >/dev/null &
done; wait
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=json.load(sys.stdin); assert len(a)==6 and len({x["id"] for x in a})==6 and sorted(x["text"] for x in a)==[f"parallel question {i}?" for i in range(6)], a' \
  && ok "parallel Stop hooks asking on one card each get their own ask id" || fail "parallel asks collided"
for i in 0 1 2 3 4 5; do "$HQ" ask resolve "$AID.$((i+1))" drop >/dev/null; done
stop sess-ask "$(printf 'ok\n```hq-asks\n- Which index?\n  a) btree\n  b) hash\n- Ship it?\n```')" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=json.load(sys.stdin); assert [x["text"] for x in a]==["Which index?\n  a) btree\n  b) hash", "Ship it?"], a' \
  && ok "an ask's indented lines stay with it; only a top-level bullet starts a new ask" || fail "multi-line ask split"
stop sess-ask "$(printf 'ok\n```hq-asks\n1. First?\n   more on the first\n2. Second?\n```')" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=[x["text"] for x in json.load(sys.stdin)]; assert a[-2:]==["First?\n   more on the first", "Second?"], a' \
  && ok "numbered asks: the same" || fail "numbered multi-line ask"
stop sess-ask "$(printf 'ok\n```hq-asks\nPlain one?\nPlain two?\n```')" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=[x["text"] for x in json.load(sys.stdin)]; assert a[-2:]==["Plain one?", "Plain two?"], a' \
  && ok "a block with no bullets is still one ask a line" || fail "unbulleted asks"
for a in $("$HQ" asks "$AID" --json | python3 -c 'import json,sys; print(" ".join(x["id"] for x in json.load(sys.stdin)))'); do "$HQ" ask resolve "$a" drop >/dev/null; done
# An hq-update with text after it, and no other at the end: not applied, and the session is told.
out="$(stop sess-ask "$(printf 'Here:\n```hq-update\nnext: mid-reply next\n```\nand some more words.')")"
! grep -q "mid-reply next" "$AC" && echo "$out" | grep -q '"decision": "block"' && echo "$out" | grep -q "not at the end" \
  && ok "an hq-update block followed by text is not applied, and the session is told why" || fail "non-trailing hq-update dropped silently: $out"
out="$(stop sess-ask "$(printf 'For example:\n```hq-update\nnext: just an example\n```\nso:\n```hq-update\nnext: the real next\n```')")"
grep -q "the real next" "$AC" && ! grep -q "just an example" "$AC" && ! echo "$out" | grep -q "not at the end" \
  && ok "one mid-reply with another at the end is an example: no complaint" || fail "example hq-update complained: $out"
# hq-resolved lines that can't be read, or name no ask: told, not dropped.
"$HQ" ask add "$AID" "Real question?" >/dev/null
RQ="$("$HQ" asks "$AID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Real question?"][0])')"
out="$(stop sess-ask "$(printf 'ok\n```hq-resolved\n- %s maybe: unclear\n- T-999.1 do: yes\n- %s do: fine\n```\n```hq-update\ntouch\n```' "$RQ" "$RQ")")"
echo "$out" | grep -q '"decision": "block"' && echo "$out" | grep -q "$RQ maybe" && echo "$out" | grep -q "T-999.1" \
  && "$HQ" asks "$AID" --all --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$RQ"'"][0]; assert a["state"]=="do", a' \
  && ok "bad hq-resolved lines are sent back; the good ones are recorded" || fail "bad hq-resolved lines dropped silently: $out"
python3 -c 'import json; print(json.dumps({"session_id":"sess-ask","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"ok\n```hq-resolved\n- T-999.2 do: yes\n```"}))' | "$HQ" hook >/dev/null
ctxof sess-ask | grep -q "T-999.2" && ok "a bad hq-resolved line while another Stop hook held the turn is reported next prompt" || fail "deferred hq-resolved problem lost"
# Later from the chat is Later on the board: the ask stays open, out of sight until tomorrow or a date.
"$HQ" ask add "$AID" "Ask Ping first?" >/dev/null
LQ="$("$HQ" asks "$AID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Ask Ping first?"][0])')"
stop sess-ask "$(printf 'ok\n```hq-resolved\n- %s later: waiting on Ping\n```\n```hq-update\ntouch\n```' "$LQ")" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys,datetime as d; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LQ"'"][0]; assert a["state"]=="open" and d.datetime.fromisoformat(a["snoozed_until"]).date()==d.date.today()+d.timedelta(days=1) and a["later_note"]=="waiting on Ping", a' \
  && ok "later in hq-resolved puts the ask off till tomorrow, as the board's Later does" || fail "chat later closed the ask"
ctxof sess-ask | grep -q "$LQ (the user will answer this later: waiting on Ping" && ok "the session sees the note it put off" || fail "later note not shown"
stop sess-ask "$(printf 'ok\n```hq-resolved\n- %s later until 2030-01-02: after the offsite\n```\n```hq-update\ntouch\n```' "$LQ")" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LQ"'"][0]; assert a["state"]=="open" and a["snoozed_until"]=="2030-01-02T00:00:00" and a["later_note"]=="after the offsite", a' \
  && ok "later until a date puts it off till then" || fail "later until"
out="$(stop sess-ask "$(printf 'ok\n```hq-resolved\n- %s later until someday: hmm\n```\n```hq-update\ntouch\n```' "$LQ")")"
echo "$out" | grep -q "someday" && ok "later until something that isn't a date is sent back" || fail "bad later date dropped: $out"
"$HQ" ask resolve "$LQ" later until 2031-03-04 "need Ping" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LQ"'"][0]; assert a["state"]=="open" and a["snoozed_until"]=="2031-03-04T00:00:00" and a["later_note"]=="need Ping", a' \
  && ok "hq ask resolve … later until DATE: the same" || fail "cli later until"
"$HQ" ask resolve "$LQ" later >/dev/null
"$HQ" asks "$AID" | grep -q "$LQ .*\[later — until " && ok "hq ask resolve … later keeps the ask open" || fail "cli later closed the ask"
# Review fixes: a resolved line without "- " is its own answer; "until" with no date is a note;
# an offset or a space before the time is part of the date; later on an answered ask is refused.
"$HQ" ask add "$AID" "Alpha?" >/dev/null; "$HQ" ask add "$AID" "Beta?" >/dev/null
AQ="$("$HQ" asks "$AID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Alpha?"][0])')"
BQ="$("$HQ" asks "$AID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Beta?"][0])')"
stop sess-ask "$(printf 'ok
```hq-resolved
- %s do: yes
  and a second line
%s drop until the API settles
```
```hq-update
touch
```' "$AQ" "$BQ")" >/dev/null
"$HQ" asks "$AID" --all --json | python3 -c 'import json,sys; a={x["id"]:x for x in json.load(sys.stdin)}; assert a["'"$AQ"'"]["state"]=="do" and a["'"$AQ"'"]["note"]=="yes\nand a second line", a["'"$AQ"'"]; assert a["'"$BQ"'"]["state"]=="drop" and a["'"$BQ"'"]["note"]=="until the API settles", a["'"$BQ"'"]' \
  && ok "hq-resolved: one answer a line, an indented line is the note's next line, until without a date is a note" || fail "hq-resolved items"
stop sess-ask "$(printf 'ok
```hq-resolved
- %s later until 2030-01-02 09:30: Ping out
```
```hq-update
touch
```' "$LQ")" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LQ"'"][0]; assert a["snoozed_until"]=="2030-01-02T09:30:00" and a["later_note"]=="Ping out", a' \
  && ok "later until a date and time" || fail "later until date time"
stop sess-ask "$(printf 'ok
```hq-resolved
- %s later until 2030-01-02T09:30:00+00:00: Ping out
```
```hq-update
touch
```' "$LQ")" >/dev/null
"$HQ" asks "$AID" --json | python3 -c 'import json,sys,datetime as d; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$LQ"'"][0]; exp=d.datetime(2030,1,2,9,30,tzinfo=d.timezone.utc).astimezone().replace(tzinfo=None).isoformat(); assert a["snoozed_until"]==exp and a["later_note"]=="Ping out", (a, exp)' \
  && ok "later until a time with an offset" || fail "later until offset"
out="$(stop sess-ask "$(printf 'ok
```hq-resolved
- %s later: too late
```
```hq-update
touch
```' "$AQ")")"
echo "$out" | grep -q "already answered" && "$HQ" asks "$AID" --all --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$AQ"'"][0]; assert a["state"]=="do" and not a.get("snoozed_until"), a' \
  && ok "later on an answered ask is sent back" || fail "later on answered ask: $out"
{ "$HQ" ask resolve "$AQ" later 2>&1 || true; } | grep -q "already answered" && ok "hq ask resolve … later on an answered ask is refused" || fail "cli later on answered ask"
{ "$HQ" ask resolve "$LQ" later until 2>&1 || true; } | grep -q "usage" && ok "later until with no date is refused" || fail "cli later until no date"
# A second answer to an answered ask: the session's and the CLI's go back, the board's replaces it.
"$HQ" ask resolve "$AQ" do --via board --note "the user's own words" >/dev/null
note_is() { "$HQ" asks "$AID" --all --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$1"'"][0]; assert (a["state"], a["note"])==("'"$2"'", "'"$3"'"), a'; }
out="$(stop sess-ask "$(printf 'ok
```hq-resolved
- %s drop: my summary
```
```hq-update
touch
```' "$AQ")")"
echo "$out" | grep -q "already answered (do: the user's own words)" && echo "$out" | grep -q "leave this line out" && note_is "$AQ" do "the user's own words" \
  && ok "an hq-resolved line on an answered ask is sent back, the answer kept" || fail "session re-answer: $out"
{ "$HQ" ask resolve "$AQ" drop 2>&1 || true; } | grep -q "already answered.*ask reopen $AQ" && note_is "$AQ" do "the user's own words" \
  && ok "hq ask resolve on an answered ask is refused" || fail "cli re-answer"
"$HQ" ask resolve "$AQ" drop --via board --note "changed my mind" && note_is "$AQ" drop "changed my mind" \
  && ok "the board still changes an answer" || fail "board re-answer"
"$HQ" ask reopen "$AQ" --via board
out="$(stop sess-ask "$(printf 'ok
```hq-resolved
- %s do: go
```
```hq-update
touch
```' "$AQ")")"
note_is "$AQ" do "go" && ! echo "$out" | grep -q "already answered" && ok "an ask reopened (Undo) is answered again" || fail "answer after reopen: $out"
# An ask continued twice: its first id still answers the copy on the card it is on now.
MV="$("$HQ" new "Moving asks" | head -1 | grep -o 'T-[0-9]*' | head -1)"
"$HQ" ask add "$MV" "Keep going?" >/dev/null; "$HQ" ask add "$MV" "Ship it?" >/dev/null
MV2="$("$HQ" continue "$MV" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["to"])')"
MV3="$("$HQ" continue "$MV2" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["to"])')"
mstate() { "$HQ" asks "$MV3" --all --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="'"$1"'"][0]; print(a["state"], a.get("note",""))'; }
"$HQ" ask resolve "$MV.1" do "yes" && [ "$(mstate "$MV3.1")" = "do yes" ] \
  && ok "an ask continued twice is answered where it is now" || fail "resolve after two continues: $(mstate "$MV3.1")"
"$HQ" ask resolve "$MV3.2" do --via board --note "the user's words" >/dev/null
"$HQ" bind "$MV3" --session sess-mv >/dev/null
out="$(stop sess-mv "$(printf 'ok
```hq-resolved
- %s drop: retold
```
```hq-update
touch
```' "$MV.2")")"
echo "$out" | grep -q "$MV.2 (now $MV3.2) is already answered (do: the user's words)" && echo "$out" | grep -q "leave this line out" && [ "$(mstate "$MV3.2")" = "do the user's words" ] \
  && ok "an hq-resolved line under a moved ask's old id, answered where it is now, is sent back" || fail "moved re-answer: $out"
out="$(stop sess-ask "$(printf 'Two examples:
```hq-update
next: ex one
```
and
```hq-update
next: ex two
```
done.')")"
! echo "$out" | grep -q "not at the end" && ! grep -q "ex one\|ex two" "$AC" && ok "two hq-update examples mid-reply: neither applied, no complaint" || fail "two examples: $out"

# The echo (T-123): after each turn of a bound session the user gets one line — a systemMessage the
# session does not see — of what HQ wrote, and what it refused or could not record.
EID="$("$HQ" new "Echo" --no-focus | head -1)"; "$HQ" bind "$EID" --session sess-echo >/dev/null
EC="$(ls "$T"/root/tasks/$EID-*/TASK.md)"
echomsg() { python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t).get("systemMessage","") if t else "")'; }
sent() { python3 -c 'import json,sys; t=sys.stdin.read().strip(); print("decision" in json.loads(t) if t else False)'; }
out="$(stop sess-echo "Just chatting, no blocks.")"
[ -z "$out" ] && ok "echo: a turn with no blocks says nothing" || fail "echo on a plain reply: $out"
out="$(stop sess-echo "$(printf 'Two examples:\n```hq-update\nnext: ex one\n```\nand\n```hq-update\nnext: ex two\n```\ndone.')")"
[ -z "$out" ] && ok "echo: blocks shown mid-reply as examples say nothing" || fail "echo on examples: $out"
out="$(stop sess-echo "$(printf 'ok\n```hq-update\ntouch\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ $EID: nothing new on the card" ] && ok "echo: a touch-only block" || fail "echo touch: $out"
stop sess-echo "$(printf 'ok\n```hq-update\ntodo: @claude echo one\nlog: echo log\n```')" >/dev/null
out="$(stop sess-echo "$(printf 'again\n```hq-update\ntodo: @claude echo one\nlog: echo log\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ $EID: nothing new on the card" ] && ok "echo: a block sent twice counts nothing the second time" || fail "echo repeat: $out"
out="$(stop sess-echo "$(printf 'ok\n```hq-update\ndone: echo one\ntodo: @me look at it\nchange: @me look at it => @me look at it twice\n```')")"
[ "$(echo "$out" | sent)" = True ] && echo "$out" | echomsg | grep -q "^HQ $EID: hq-update NOT applied: .*(sent back to the session)$" \
  && ok "echo: a refused block is shown as not written, and sent back" || fail "echo refused: $out"
out="$(stop sess-echo "$(printf 'ok\n```hq-update\nstatus: nope\nnext: x\n```\nmore text after')")"
echo "$out" | echomsg | grep -q "hq-update NOT applied: the hq-update block isn't at the end of the reply, so it was taken for an example (sent back" \
  && ok "echo: a block not at the end is named in the user's words" || fail "echo not at end: $out"
out="$(python3 -c 'import json; print(json.dumps({"session_id":"sess-echo","hook_event_name":"Stop","stop_hook_active":True,"last_assistant_message":"ok\n```hq-update\nstatus: nope\n```"}))' | "$HQ" hook)"
[ "$(echo "$out" | sent)" = False ] && echo "$out" | echomsg | grep -q "hq-update NOT applied: status must be one of .*(the session hears at its next prompt)$" \
  && ok "echo: refused while another hook held the turn, and when the session will hear" || fail "echo stop_hook_active: $out"
hook '{"session_id":"sess-echo","hook_event_name":"UserPromptSubmit","prompt":"hi"}' >/dev/null
out="$(stop sess-echo "$(printf 'Question.\n```hq-asks\n- Ship the echo?\n```\n```hq-update\nstatus: done\n```')")"
EQ="$("$HQ" asks "$EID" --json | python3 -c 'import json,sys; print([a["id"] for a in json.load(sys.stdin) if a["text"]=="Ship the echo?"][0])')"
[ "$(echo "$out" | echomsg)" = "HQ $EID: status active → waiting-on-me, done held: waiting on 1 question(s), ask $EQ" ] && ok "echo: a new ask and a held close" || fail "echo ask/held: $out"
out="$(stop sess-echo "$(printf 'Noted.\n```hq-resolved\n- %s do: yes\n- T-999.1 do: nope\n```\n```hq-update\nref: Echo PR https://example.com/pr/echo\n```' "$EQ")")"
echo "$out" | echomsg | grep -q "^HQ $EID: status waiting-on-me → done, +1 ref, answer $EQ (do) recorded, 1 answer(s) NOT recorded: .*T-999.1.*(sent back to the session)$" \
  && ok "echo: answers recorded and not, a released close, a ref" || fail "echo resolved: $out"
python3 - "$HOME/.claude/hq/state/sessions.json" <<'PY'
import json, sys, time
p = sys.argv[1]; s = json.load(open(p)); s["sess-echo"]["turn_start"] = time.time() - 600; json.dump(s, open(p, "w"))
PY
touch -t 200001010000 "$EC"
out="$(stop sess-echo "Did a lot, forgot the card.")"
[ "$(echo "$out" | sent)" = True ] && [ "$(echo "$out" | echomsg)" = "HQ $EID: this turn did work but the card wasn't updated (the session was nudged)" ] \
  && ok "echo: the write-back guard is shown too" || fail "echo stale: $out"
out="$(stop sess-echo "$(printf 'ok\n```hq-update\nref: Echo PR (merged) https://example.com/pr/echo\nref: Echo doc https://example.com/doc/echo\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ $EID: +1 ref, 1 ref updated" ] && ok "echo: a renamed ref is not counted as a new one" || fail "echo ref rename: $out"
"$HQ" project add echop >/dev/null
out="$(stop sess-echo "$(printf 'ok\n```hq-update\nproject: echop\nlog: project kickoff notes written\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ $EID: +1 log, moved project" ] && grep -q ": project kickoff notes written" "$EC" \
  && ok "echo: the session's own log line that starts with 'project' counts, the move's line doesn't" || fail "echo project log: $out"
NID="$("$HQ" new "无项目回显" --no-focus | head -1)"; NC="$(ls "$T"/root/tasks/$NID-*/TASK.md)"
python3 - "$NC" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read(); t = re.sub(r"^## Status", "## 当前状态", t, flags=re.M); open(p, "w").write(t)
PY
grep -q '^## 当前状态' "$NC" || fail "zh card heading not set"
"$HQ" bind "$NID" --session sess-nop >/dev/null
out="$(stop sess-nop "$(printf 'ok\n```hq-update\nnext: 下一步\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ ${NID}：next" ] && ok "echo: a task with no project speaks its card's language" || fail "echo no-project zh: $out"
"$HQ" project add zhecho >/dev/null
printf -- '---\nname: zhecho\nkind: duty\n---\n\n## 目标\n回显。\n' > "$T/root/projects/zhecho/PROJECT.md"
ZID="$("$HQ" new "中文回显" --project zhecho --no-focus | head -1)"; "$HQ" bind "$ZID" --session sess-zh >/dev/null
out="$(stop sess-zh "$(printf '好\n```hq-update\nnext: 写测试\ntodo: @claude 跑测试\n```\n\n```hq-update\nstatus: 不对\n```\n')")"
[ "$(echo "$out" | echomsg)" = "HQ ${ZID}：next，+1 todo，hq-update 没写进卡片：status must be one of waiting-on-me, blocked, active, done, abandoned (got '不对')（已让 session 重写）" ] \
  && ok "echo: two blocks, one applied and one not, in the project's language" || fail "echo zh: $out"
out="$(stop sess-zh "$(printf '好\n```hq-update\nnext: 改文档\ndone: 跑测试\n```')")"
[ "$(echo "$out" | echomsg)" = "HQ ${ZID}：next，1 条 todo 完成" ] && ok "echo: what was written, in Chinese" || fail "echo zh written: $out"
# ---- hq doctor: hook wiring, stale bindings, state files, asks an old `later` closed — in a home of its own.
DH="$T/doctor-home"; mkdir -p "$DH/.claude"; echo '{}' > "$DH/.claude/settings.json"
HOME="$DH" "$SRC/install.sh" --root "$T/doctor-root" --yes --no-commands >/dev/null
DQ() { HOME="$DH" "$DH/.claude/hq/bin/hq" "$@"; }
python3 - "$SRC/../Sources/PetEmit/SettingsPatch.swift" "$SRC/hqlib/doctor.py" <<'PY' && ok "doctor: the pet's hook events match SettingsPatch.events" || fail "doctor pet events out of step with SettingsPatch.swift"
import re, sys
swift = open(sys.argv[1]).read()
body = re.search(r"static let events = \[(.*?)\]", swift, re.S).group(1)
want = re.findall(r'"([A-Za-z]+)"', re.sub(r"//.*", "", body))
hq = re.search(r"PET_HOOK_EVENTS = \((.*?)\)", open(sys.argv[2]).read(), re.S).group(1)
assert sorted(re.findall(r'"([A-Za-z]+)"', hq)) == sorted(want), (hq, want)
PY
out="$(DQ doctor)" && echo "$out" | grep -q "✓ hq hook on SessionStart, UserPromptSubmit, Stop" && echo "$out" | grep -q "Claude Pet is not installed" \
  && echo "$out" | grep -q "All good." && ok "doctor: a fresh install is all good" || fail "doctor fresh: $out"
mkdir -p "$DH/cfg"; echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/hq/bin/hq hook"},{"type":"command","command":"$HOME/.claude/hq/bin/hq hook"}]}]}}' > "$DH/cfg/settings.json"
out="$(CLAUDE_CONFIG_DIR="$DH/cfg" DQ doctor)" && fail "doctor with hooks missing should exit 1" || true
echo "$out" | grep -q "✗ hq hook missing on SessionStart, UserPromptSubmit" && echo "$out" | grep -q "wired twice on Stop" \
  && ok "doctor: a missing hook is an error (exit 1), a doubled one a warning; CLAUDE_CONFIG_DIR's settings are read" || fail "doctor missing hooks: $out"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/pet/pet-emit"}]}]}}' > "$DH/cfg/settings.json"
out="$(CLAUDE_CONFIG_DIR="$DH/cfg" DQ doctor || true)"
echo "$out" | grep -q "pet hook missing on SessionStart" && echo "$out" | grep -q "pet-emit, which is missing or not executable" \
  && ok "doctor: a pet hook wired on some events, to a binary that is gone" || fail "doctor pet hooks: $out"
echo 'not json' > "$DH/cfg/settings.json"
out="$(CLAUDE_CONFIG_DIR="$DH/cfg" DQ doctor)" && fail "doctor with an unreadable settings.json should exit 1" || true
echo "$out" | grep -q "✗ .*settings.json can't be read" && ok "doctor: an unreadable settings.json is an error" || fail "doctor bad settings: $out"

DOPEN="$(DQ new "Open one" --workdir "$T" | head -1)"; DDONE="$(DQ new "Done one" --workdir "$T" | head -1)"
DGONE="$(DQ new "Given up" --workdir "$T" | head -1)"
DQ bind "$DOPEN" --session d-recent >/dev/null; DQ bind "$DOPEN" --session d-old >/dev/null
DQ bind "$DDONE" --session d-done >/dev/null; DQ bind "$DDONE" --session d-held >/dev/null; DQ bind "$DDONE" --session d-live >/dev/null
DQ bind "$DGONE" --session d-held2 >/dev/null
DQ ask add "$DOPEN" "Ship it?" >/dev/null; DQ ask resolve "$DOPEN.1" do --via board >/dev/null
DQ set "$DDONE" status=done >/dev/null; DQ set "$DGONE" status=abandoned >/dev/null
sed -i.bak 's/^status: done$/status: done\
closing: done/' "$T"/doctor-root/tasks/"$DDONE"-*/TASK.md    # d-held's close, still held
python3 - "$DH/.claude/hq/state/sessions.json" "$DOPEN" <<'PY'
import json, sys
p, tid = sys.argv[1], sys.argv[2]
s = json.load(open(p))
s["d-old"]["bound_at"] = "2020-01-01T00:00:00+00:00"
s["d-done"]["delivered"] = [tid + ".1"]   # the older record of an answer told to it — on its earlier task
s["d-held"]["held"] = {"task": s["d-held"]["task"]}
s["d-held2"]["held"] = {"task": s["d-held2"]["task"]}   # a mark left after its task was closed outright
s["d-gone"] = {"task": "T-999", "bound_at": "2026-01-01T00:00:00+00:00"}
json.dump(s, open(p, "w"))
PY
DDIR="$(dirname "$(ls "$T"/doctor-root/tasks/"$DOPEN"-*/TASK.md)")"
python3 - "$DH/.claude/hq/state/todo-seen.json" "$DOPEN" <<'PY'
import json, sys
json.dump({sys.argv[2] + "|gone todo": "2026-01-01T00:00:00+08:00", "T-999|x": "2026-01-01T00:00:00+08:00"}, open(sys.argv[1], "w"))
PY
echo "- [ ] @me still open" >> "$DDIR/TASK.md"; DQ board --json >/dev/null    # a todo with no stamp of its own: first seen now
mkdir -p "$DH/.claude/hq/state/locks"; touch "$DH/.claude/hq/state/locks/T-777-deleted.lock" "$DH/.claude/hq/state/locks/T-778-held.lock"
touch "$DH/.claude/hq/state/locks/$(basename "$DDIR" | tr a-z A-Z).lock"   # the card's own, in another case
DQ ask add "$DOPEN" "Old later?" >/dev/null
echo "{\"type\":\"resolve\",\"id\":\"$DOPEN.2\",\"resolution\":\"later\",\"note\":\"\",\"via\":\"cli\",\"ts\":\"2026-11-20T10:00:00+08:00\"}" >> "$DDIR/asks.jsonl"
out="$(DQ doctor)"
echo "$out" | grep -q "2 of 7 session bindings are over" && ! echo "$out" | grep -q "d-done" \
  && ok "doctor: without the pet to say, a session bound today may still be running — kept even on a done task" || { echo "$out"; fail "doctor bindings without the pet"; }
mkdir -p "$DH/.claude/pet/sessions"; echo "{\"pid\": $$, \"sessionId\": \"d-recent\"}" > "$DH/.claude/pet/sessions/d-recent.json"
echo "{\"pid\": $$, \"sessionId\": \"d-live\"}" > "$DH/.claude/pet/sessions/d-live.json"    # running, no transcript yet
out="$(DQ doctor)"
echo "$out" | grep -q "4 of 7 session bindings are over" && echo "$out" | grep -q "d-done .*is done" && echo "$out" | grep -q "d-gone .*T-999 no longer exists" \
  && echo "$out" | grep -q "d-old .*quiet for" && echo "$out" | grep -q "d-held2 .*is abandoned" && ! echo "$out" | grep -q "d-held \|d-recent\|d-live" \
  && ok "doctor: bindings to a closed or deleted task, or of a session long quiet, are over; a running one (even with no transcript), a held close and a recent one are not" || { echo "$out"; fail "doctor bindings"; }
echo "$out" | grep -q "todo-seen.json: 2 of 3 entries" && echo "$out" | grep -q "T-777-deleted.lock" && ! echo "$out" | grep -q "$DOPEN-open-one.lock\|inbox.lock" \
  && ok "doctor: todo-seen entries of todos no longer open, lock files of no card" || fail "doctor state files: $out"
echo "$out" | grep -q "$DOPEN.2 .*2026-11-20  Old later?" && ok "doctor: lists an ask closed by an old later" || fail "doctor later: $out"
out="$(HQ_ROOT="$T/root" DQ doctor)"
echo "$out" | grep -q "HQ_ROOT (.*) is not the configured root" && ! echo "$out" | grep -q "session bindings are over\|of no card or project" \
  && ok "doctor under another HQ_ROOT leaves the shared bindings and lock files alone" || fail "doctor HQ_ROOT: $out"
HQ_ROOT="$T/root" DQ doctor --fix | grep -q "unbound\|removed" && fail "doctor --fix under another HQ_ROOT touched shared state" || true
DQ doctor --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["fixed"] is None and {c["area"] for c in d["checks"]} == {"hooks","bindings","state","asks"} and all(c["level"] in ("ok","warn","error") for c in d["checks"]), d' \
  && ok "doctor --json" || fail "doctor json"

python3 - "$DH/.claude/hq/state/locks/T-778-held.lock" "$DH/.claude/hq/bin/hq" "$DH" > "$T/doctor-fix.out" <<'PY'
import fcntl, os, subprocess, sys
with open(sys.argv[1], "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    print(subprocess.run([sys.argv[2], "doctor", "--fix"], env=dict(os.environ, HOME=sys.argv[3]), capture_output=True, text=True).stdout)
PY
out="$(cat "$T/doctor-fix.out")"
echo "$out" | grep -q "unbound 4 sessions" && echo "$out" | grep -q "dropped 2 todo-seen.json entries" && echo "$out" | grep -q "removed 1 lock file" \
  && echo "$out" | grep -q "reopened 1 ask: $DOPEN.2" && ok "doctor --fix says what it did" || fail "doctor fix: $out"
python3 - "$DH/.claude/hq/state/sessions.json" "$DH/.claude/hq/state/todo-seen.json" "$DOPEN" <<'PY' && ok "doctor --fix: stale bindings and todo-seen entries gone, the rest kept" || fail "doctor fix state"
import json, sys
s = json.load(open(sys.argv[1])); seen = json.load(open(sys.argv[2]))
assert sorted(s) == ["d-held", "d-live", "d-recent"], s
assert list(seen) == [sys.argv[3] + "|still open"], seen
PY
L="$DH/.claude/hq/state/locks"
[ ! -e "$L/T-777-deleted.lock" ] && [ -e "$L/T-778-held.lock" ] && ls "$L" | grep -qi "^$(basename "$DDIR").lock$" \
  && ok "doctor --fix: removes an orphan lock no one holds, keeps a held one and the cards' own" || fail "doctor fix locks: $(ls "$L")"
DQ asks "$DOPEN" --all --json | python3 -c 'import json,sys; a={x["id"]:x for x in json.load(sys.stdin)}; t=sys.argv[1]; assert a[t+".1"]["delivered"]=="d-done" and a[t+".2"]["state"]=="open", a' "$DOPEN" \
  && ok "doctor --fix: an unbound session's older delivered record moves onto the ask, on whichever task it is; the old-later ask is open again" || fail "doctor fix asks"
grep -q "^status: waiting-on-me" "$DDIR/TASK.md" && ok "doctor --fix: a reopened ask puts its task back on you" || fail "doctor fix status"
out="$(DQ doctor --fix)"; echo "$out" | grep -q "removed 1 lock file" && echo "$out" | grep -q "All good." && ok "doctor --fix again: the lock let go of is removed now" || fail "doctor fix again: $out"
out="$(DQ doctor --fix)"; echo "$out" | grep -q "Nothing to fix." && ok "doctor --fix with nothing left" || fail "doctor fix nothing: $out"
{ DQ doctor --days 0 2>&1 || true; } | grep -q "at least 1" && ok "doctor --days must be positive" || fail "doctor days"

"$SRC/uninstall.sh" >/dev/null
grep -q 'hq/bin/hq hook' "$HOME/.claude/settings.json" && fail "uninstall left hooks" || ok "uninstall removes hooks, keeps others"
grep -q other-tool "$HOME/.claude/settings.json" && [ -d "$T/root/tasks/T-001-benchmark-vs-neo4j" ] && ok "uninstall keeps other hooks and data"
[ ! -e "$HOME/.claude/hq/bin" ] && [ ! -e "$HOME/.claude/hq/hqlib" ] && ok "uninstall removes bin/hq and hqlib" || fail "uninstall left the CLI"
echo "$pass passed"
