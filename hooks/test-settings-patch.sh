#!/bin/bash
# Test pet-emit --patch-settings / --unpatch-settings against throwaway files.
#
# This is the one thing this project does that can break someone else's machine:
# ~/.claude/settings.json drives every Claude Code session, and a bad edit there
# fails on THEIR box, days later, with no way to trace it back here. So the
# contract is tested against real files rather than in-process — backup, atomic
# write, parse-back and rollback only exist on disk.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
EMIT="${PET_EMIT:-$HERE/../.build/debug/PetEmit}"
if [ ! -x "$EMIT" ]; then
  echo "PetEmit binary not found: $EMIT"
  echo "run swift build before this test"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# Semantic comparison: the patcher re-serialises with sorted keys, so two files
# that mean the same thing are not necessarily the same bytes.
json_eq() {
  python3 -c 'import json,sys
sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$1" "$2" \
    && echo yes || echo no
}

# Prints a dotted path out of a JSON file, or "missing".
jq_path() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if isinstance(d,list):
        d=d[int(k)]
    elif k in d:
        d=d[k]
    else:
        print("missing"); sys.exit(0)
print(json.dumps(d,sort_keys=True,separators=(",",":")))' "$1" "$2"
}

count_pet_hooks() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])).get("hooks",{})
n=0
for ev,groups in d.items():
    for g in groups:
        for h in g.get("hooks",[]):
            if h.get("command","").endswith("/pet/pet-emit"):
                n+=1
print(n)' "$1"
}

PET='$HOME/.claude/pet/pet-emit'
LEGACY='$HOME/.claude/pet/pet-emit.sh'

echo "== a machine with no settings.json yet =="
FRESH="$WORK/fresh.json"
"$EMIT" --patch-settings "$FRESH" >/dev/null 2>&1
check "the file is created" "$([ -f "$FRESH" ] && echo yes || echo no)" "yes"
# Mirrors SettingsPatch.events — update both together.
check "all 9 events get a hook" "$(count_pet_hooks "$FRESH")" "9"

echo "== running it twice changes nothing =="
BEFORE="$(cat "$FRESH")"
OUT="$("$EMIT" --patch-settings "$FRESH" 2>&1)"
check "it says so out loud" "$(echo "$OUT" | grep -c 'already present')" "1"
check "the file is byte-identical" "$([ "$BEFORE" = "$(cat "$FRESH")" ] && echo yes || echo no)" "yes"

echo "== a user's own settings survive the round trip =="
USER_FILE="$WORK/user.json"
cat > "$USER_FILE" <<'JSON'
{
  "model": "claude-opus-5",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/bin/audit-bash.sh", "timeout": 30 }
        ]
      }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "~/bin/wrap-up.sh" } ] }
    ]
  },
  "env": { "FOO": "bar" }
}
JSON
ORIGINAL_USER_HOOK="$(jq_path "$USER_FILE" hooks.PreToolUse.0)"
ORIGINAL_SESSION_END="$(jq_path "$USER_FILE" hooks.SessionEnd.0)"
cp "$USER_FILE" "$WORK/user.orig.json"

"$EMIT" --patch-settings "$USER_FILE" >/dev/null 2>&1
check "the user's Bash hook group is untouched" \
  "$(jq_path "$USER_FILE" hooks.PreToolUse.0)" "$ORIGINAL_USER_HOOK"
check "the pet's hook went into a NEW group" \
  "$(jq_path "$USER_FILE" hooks.PreToolUse.1.hooks.0.command)" "\"$PET\""
check "an unrelated top-level key is untouched" "$(jq_path "$USER_FILE" model)" '"claude-opus-5"'
check "env survives too" "$(jq_path "$USER_FILE" env.FOO)" '"bar"'
check "the user's SessionEnd group is untouched" \
  "$(jq_path "$USER_FILE" hooks.SessionEnd.0)" "$ORIGINAL_SESSION_END"

"$EMIT" --unpatch-settings "$USER_FILE" >/dev/null 2>&1
check "no pet hook is left behind" "$(count_pet_hooks "$USER_FILE")" "0"
check "uninstall returns the file to what it meant before" \
  "$(json_eq "$USER_FILE" "$WORK/user.orig.json")" "yes"

echo "== the backup =="
# NOT a count: the backup name carries a seconds-resolution timestamp, so the
# patch and the unpatch above collapse into one file or stay two depending on
# whether they straddled a second boundary. Asserting a number made this test
# pass or fail by the clock. What actually matters is that a backup exists and
# that it holds what the file said before it was touched.
check "a backup was written" \
  "$([ "$(ls "$WORK" | grep -c 'user.json.bak-claudepet-')" -ge 1 ] && echo yes || echo no)" "yes"
# Lexical order, not mtime: two backups written inside one second can share a
# modification time, and the suffix (-2, -3) is what actually orders them.
OLDEST_BACKUP="$(ls "$WORK"/user.json.bak-claudepet-* 2>/dev/null | head -1)"
check "the backup holds what the file said before it was touched" \
  "$(json_eq "$OLDEST_BACKUP" "$WORK/user.orig.json")" "yes"

echo "== upgrading from the old shell hook =="
LEG="$WORK/legacy.json"
cat > "$LEG" <<JSON
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "$LEGACY", "timeout": 5 } ] } ] } }
JSON
"$EMIT" --patch-settings "$LEG" >/dev/null 2>&1
check "the legacy command is rewritten in place" \
  "$(jq_path "$LEG" hooks.Stop.0.hooks.0.command)" "\"$PET\""
check "no stale .sh path is left anywhere" "$(grep -c 'pet-emit.sh' "$LEG")" "0"
check "the legacy entry keeps its other fields" \
  "$(jq_path "$LEG" hooks.Stop.0.hooks.0.timeout)" "5"
check "the rewrite did not also append a duplicate group" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hooks"]["Stop"]))' "$LEG")" "1"

echo "== a settings.json we cannot parse is left alone =="
BROKEN="$WORK/broken.json"
printf '{ "hooks": { oops' > "$BROKEN"
BEFORE_BROKEN="$(cat "$BROKEN")"
"$EMIT" --patch-settings "$BROKEN" >/dev/null 2>&1
check "it refuses with a non-zero exit" "$?" "1"
check "the file is byte-identical" \
  "$([ "$BEFORE_BROKEN" = "$(cat "$BROKEN")" ] && echo yes || echo no)" "yes"

echo "== removing from a file that has no pet hooks =="
ONLY_USER="$WORK/only-user.json"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/bin/mine.sh"}]}]}}' > "$ONLY_USER"
cp "$ONLY_USER" "$WORK/only-user.orig.json"
"$EMIT" --unpatch-settings "$ONLY_USER" >/dev/null 2>&1
check "the user's lone hook is still there" \
  "$(json_eq "$ONLY_USER" "$WORK/only-user.orig.json")" "yes"

if [ "$fails" = "0" ]; then
  echo ""
  echo "ALL PASS"
  exit 0
fi
echo ""
echo "$fails FAILED"
exit 1
