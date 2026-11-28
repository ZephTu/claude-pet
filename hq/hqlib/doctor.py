"""`hq doctor`: a health check of HQ itself."""
import datetime as dt
from .compat import fcntl
import json
import os
import re
import shutil
import sys
import time

from .core import (CONFIG, HOME_DIR, HQ_BIN, LOCK_DIR, OPEN_STATUSES, STATE, atomic_write, card_lock, die, gist,
                   hq_root, load_json, local_time)
from .sessions import PET_SESSIONS, load_state, save_state, session_alive, state_lock
from .cards import card_paths, parse_card
from .projects import load_projects, projects_dir
from .peek import find_transcript
from .asks import append_event, await_answer, read_asks
from .inbox import tilde


# ---------------------------------------------------------------- doctor: a health check of HQ itself
# What goes wrong silently: a hook not wired (or wired to a binary that is gone), so nothing is
# captured; bindings of sessions long over, to tasks since closed or deleted; state files that only
# grow; asks closed with `later` back when that closed them for good. `hq doctor` reports; `--fix`
# clears what is HQ's own state. settings.json is only ever read: a missing hook may be an install
# with --no-hooks, and wiring is the installers' job.
HQ_HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop")
# The pet's hook events — keep in step with SettingsPatch.events (Sources/PetEmit/SettingsPatch.swift);
# hq/tests/test_hq.sh checks they match.
PET_HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                   "PermissionRequest", "Stop", "SessionEnd", "PreCompact", "StopFailure", "PostToolUseFailure")
PET_EMIT = os.path.expanduser("~/.claude/pet/pet-emit")
if os.name == "nt":   # the Windows pet's hook: "$HOME/.claude/pet/pet-emit", which Git Bash finds as .exe
    PET_EMIT += ".exe"
DOCTOR_DAYS = 30            # a binding whose session has been quiet this long is over
DOCTOR_LIVE_SECONDS = 86400  # without the pet to say, a transcript written this recently may be running
# Lock files HQ takes besides one per card (its folder's name) and one per project (its name).
FIXED_LOCKS = {"new-card", "inbox", "feed-state", "intake", "autoclose"}


def counted(n, one, many=None):
    return f"{n} {one if n == 1 else many or one + 's'}"


def doctor_check(area, level, text, fix=None, items=None):
    return {"area": area, "level": level, "text": text, "fix": fix, "items": items or []}


def doctor_hooks():
    """settings.json: HQ's hook on its three events and the pet's on its own, each pointing at a
    program that is there, and the Python hq runs with."""
    out = []
    path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")
    try:
        settings = json.load(open(path, encoding="utf-8"))
        if not isinstance(settings, dict):
            raise ValueError("not a JSON object")
    except FileNotFoundError:
        return [doctor_check("hooks", "error", f"{tilde(path)} does not exist: no hook runs — run hq/install.sh")]
    except (OSError, ValueError) as e:
        return [doctor_check("hooks", "error", f"{tilde(path)} can't be read ({e}): Claude Code ignores it, so no hook runs")]
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    if os.path.realpath(path) != os.path.realpath(os.path.expanduser("~/.claude/settings.json")):
        out.append(doctor_check("hooks", "warn", f"CLAUDE_CONFIG_DIR is set: checking {tilde(path)}, but hq/install.sh and the "
                                "pet's installer wire ~/.claude/settings.json only — copy their hooks into this one"))

    def commands(ev):
        return [h.get("command") or "" for g in (hooks.get(ev) or []) if isinstance(g, dict)
                for h in (g.get("hooks") or []) if isinstance(h, dict)]

    def wiring(events, match):
        n = {ev: sum(1 for c in commands(ev) if match(c)) for ev in events}
        missing = [ev for ev in events if not n[ev]]
        twice = [ev for ev in events if n[ev] > 1]
        found = [ev for ev in events if n[ev]]
        return missing, twice, found

    missing, twice, found = wiring(HQ_HOOK_EVENTS, lambda c: ".claude/hq/bin/hq hook" in c)
    if not found:
        # Maybe on purpose (an install with --no-hooks): a warning, not an error.
        out.append(doctor_check("hooks", "warn", f"hq hook not in {tilde(path)}: sessions bound to a task get no card, "
                                "and nothing they write is recorded — run hq/install.sh, unless you installed with --no-hooks on purpose"))
    elif missing:
        out.append(doctor_check("hooks", "error", f"hq hook missing on {', '.join(missing)} — run hq/install.sh to add it"))
    else:
        out.append(doctor_check("hooks", "ok", f"hq hook on {', '.join(HQ_HOOK_EVENTS)}"))
    if twice:
        out.append(doctor_check("hooks", "warn", f"hq hook wired twice on {', '.join(twice)}: each turn is recorded twice "
                                f"— remove the extra in {tilde(path)}"))
    if found:
        if not os.path.isfile(HQ_BIN):
            out.append(doctor_check("hooks", "error", f"the hq hook runs {tilde(HQ_BIN)}, which is not there — run hq/install.sh"))
        elif not os.access(HQ_BIN, os.X_OK):
            out.append(doctor_check("hooks", "error", f"{tilde(HQ_BIN)} is not executable — chmod +x it"))
        elif ("hqlib" in open(HQ_BIN + (".py" if os.name == "nt" else ""),   # Windows: bin/hq runs bin/hq.py
                              encoding="utf-8", errors="replace").read()     # an hq of before the split has none
              and not os.path.isfile(os.path.join(HOME_DIR, "hqlib", "hooks.py"))):
            out.append(doctor_check("hooks", "error", f"hq's modules ({tilde(os.path.join(HOME_DIR, 'hqlib'))}) are missing: "
                                    "every hook fails — run hq/install.sh"))
    ver = ".".join(map(str, sys.version_info[:3]))
    if os.name == "nt":
        # bin/hq is install.sh's sh script, which names its Python: no python3 on PATH is needed.
        level = "ok" if sys.version_info >= (3, 9) else "error"
        out.append(doctor_check("hooks", level, f"hq runs with {sys.executable} ({ver})"
                                + ("" if sys.version_info >= (3, 9) else " — hq needs Python 3.9 or later")))
    else:
        py = shutil.which("python3")
        where = f"python3 on PATH is {py}" if py else "no python3 on PATH"
        level = "ok" if py and sys.version_info >= (3, 9) else "error"
        out.append(doctor_check("hooks", level, f"hq runs with {sys.executable} ({ver}); {where}"
                                + ("" if sys.version_info >= (3, 9) else " — hq needs Python 3.9 or later")
                                + ("" if py else " — the hook's `#!/usr/bin/env python3` finds nothing")))

    pet_cmd = lambda c: c.strip() in ("$HOME/.claude/pet/pet-emit", PET_EMIT) or (
        os.name == "nt" and c.strip() == '"$HOME/.claude/pet/pet-emit"')   # windows/install.ps1 quotes it
    legacy = any("/.claude/pet/pet-emit.sh" in c for ev in hooks for c in commands(ev))
    missing, twice, found = wiring(PET_HOOK_EVENTS, pet_cmd)
    if not found and not os.path.exists(PET_EMIT) and not legacy:
        out.append(doctor_check("hooks", "ok", "Claude Pet is not installed (its hooks are not needed for HQ)"))
        return out
    if legacy:
        out.append(doctor_check("hooks", "warn", "a hook still runs the old pet-emit.sh — reinstall the pet (scripts/install.sh)"))
    if not found:
        out.append(doctor_check("hooks", "warn", "pet-emit is installed but not wired: the pet sees no session — "
                                "reinstall the pet (scripts/install.sh)"))
    elif missing:
        out.append(doctor_check("hooks", "warn", f"pet hook missing on {', '.join(missing)} — reinstall the pet (scripts/install.sh)"))
    else:
        out.append(doctor_check("hooks", "ok", f"pet hook on its {len(PET_HOOK_EVENTS)} events"))
    if twice:
        out.append(doctor_check("hooks", "warn", f"pet hook wired twice on {', '.join(twice)}"))
    if found and not os.access(PET_EMIT, os.X_OK):
        out.append(doctor_check("hooks", "warn", f"the pet's hook runs {tilde(PET_EMIT)}, which is missing or not executable "
                                "— reinstall the pet (scripts/install.sh)"))
    return out


def doctor_card(tid, metas):
    """The card a task id names, found by its folder as find_card (and so the hook) finds it."""
    tid = tid.upper() if re.match(r"^t-\d+$", tid or "", re.I) else (tid or "")
    for m in metas:
        d = os.path.basename(m["dir"])
        if tid and (d == tid or d.startswith(tid + "-")):
            return m
    return None


def binding_verdict(sid, e, metas, now, days):
    """Why the binding of session `sid` is over, or None to keep it. A session still running is
    never over, whatever its task."""
    if not isinstance(e, dict) or not isinstance(e.get("task"), str):
        return "not a binding"
    path, live = find_transcript(sid)
    live = live or session_alive(sid) is True
    quiet = now - os.path.getmtime(path) if path else None
    if quiet is None:
        # No transcript found (or one under another CLAUDE_CONFIG_DIR): go by when it was bound.
        bound = local_time(e.get("bound_at") or "")
        quiet = (dt.datetime.now() - bound).total_seconds() if bound else None
    if live or (not os.path.isdir(PET_SESSIONS) and quiet is not None and quiet < DOCTOR_LIVE_SECONDS):
        return None
    meta = doctor_card(e["task"], metas)
    if meta is None:
        return f"{e['task']} no longer exists"
    if isinstance(e.get("held"), dict) and meta.get("closing"):
        return None            # holding a close until its asks are answered
    if meta.get("status") not in OPEN_STATUSES:
        return f"{e['task']} is {meta.get('status')}"
    if quiet is None or quiet > days * 86400:
        return f"quiet for {int(quiet // 86400)} days" if quiet is not None else "no transcript"
    return None


def stale_bindings(state, metas, days):
    now = time.time()
    out = []
    for sid, e in state.items():
        why = binding_verdict(sid, e, metas, now, days)
        if why:
            out.append({"session": sid, "task": (e or {}).get("task") if isinstance(e, dict) else None, "why": why})
    return out


def open_todo_keys(metas):
    """The keys todo-seen.json keeps a first-seen time under (stamp_todos), for every todo open now."""
    keys = set()
    for m in metas:
        keys.update(f"{m.get('id')}|{t['text']}" for t in m["todos"] if t["state"] == "open")
        if m.get("waiting_on_me"):
            keys.add(f"{m.get('id')}|{m['waiting_on_me']}")
    return keys


def orphan_locks(metas):
    """Lock files of no card, project or HQ-wide lock: a deleted card's, a renamed project's."""
    if not os.path.isdir(LOCK_DIR):
        return []
    # Named as card_lock names them (the real folder), compared without case: on macOS's disk
    # "Perf.lock" is the lock a project renamed to "perf" still takes.
    known = set(FIXED_LOCKS) | {os.path.basename(os.path.realpath(m["dir"])) for m in metas}
    known |= {f"feed-{s}" for s in ("zulip", "jira")}
    pdir = projects_dir()
    if os.path.isdir(pdir):
        known |= {os.path.basename(os.path.realpath(os.path.join(pdir, n))) for n in os.listdir(pdir)}
    known |= {p["name"] for p in load_projects()}
    known = {k.casefold() for k in known}
    return sorted(n for n in os.listdir(LOCK_DIR) if n.endswith(".lock") and n[:-5].casefold() not in known)


def legacy_later_asks(metas):
    """Asks answered `later` when that closed them for good (before it meant "put off"): on open
    tasks, never to come back by themselves."""
    out = []
    for m in metas:
        if m.get("status") not in OPEN_STATUSES:
            continue
        for a in read_asks(m["dir"]):
            if a.get("state") == "later":
                out.append({"id": a["id"], "task": m["id"], "at": a.get("resolved_at") or a.get("ts"),
                            "text": a.get("text", ""), "card": m["path"]})
    return out


def other_root():
    """HQ_ROOT naming another root than config.json's: sessions.json and the lock files in
    ~/.claude/hq are shared by every root, so this root's cards can't say which of them are stale."""
    env = os.environ.get("HQ_ROOT")
    conf = load_json(CONFIG, {}).get("root") if isinstance(load_json(CONFIG, {}), dict) else None
    if not env or not conf:
        return None
    return env if os.path.realpath(os.path.expanduser(env)) != os.path.realpath(os.path.expanduser(conf)) else None


def doctor_metas():
    return [parse_card(p) for p in card_paths()]


def gather_doctor(days=DOCTOR_DAYS):
    checks = doctor_hooks()
    root = hq_root(required=False)
    if not root or not os.path.isdir(os.path.join(root, "tasks")):
        checks.append(doctor_check("bindings", "error", "no HQ root configured (config.json's root, or HQ_ROOT) — "
                                   "run hq/install.sh --root <dir>"))
        return checks
    metas = doctor_metas()
    shared = not other_root()
    if not shared:
        checks.append(doctor_check("bindings", "warn", f"HQ_ROOT ({os.environ['HQ_ROOT']}) is not the configured root: "
                                   "session bindings, todo-seen.json and lock files are shared by all roots, so they are "
                                   "not checked — run hq doctor without HQ_ROOT"))

    # Bindings.
    raw = None
    try:
        raw = json.load(open(STATE, encoding="utf-8")) if os.path.exists(STATE) else {}
        if not isinstance(raw, dict):
            raise ValueError("not a JSON object")
    except (OSError, ValueError) as e:
        raw = None
        checks.append(doctor_check("bindings", "error", f"{tilde(STATE)} can't be read ({e}): no session finds its task "
                                   "— move it aside and bind the sessions again"))
    if isinstance(raw, dict) and shared:
        stale = stale_bindings(raw, metas, days)
        if stale:
            checks.append(doctor_check("bindings", "warn", f"{len(stale)} of {counted(len(raw), 'session binding')} are over "
                                       "(task closed or gone, or session quiet)", "unbind them",
                                       [f"{x['session'][:8]}  {x['task'] or '-':<6} {x['why']}" for x in stale]))
        else:
            checks.append(doctor_check("bindings", "ok", f"{counted(len(raw), 'session binding')}, none stale"))

    # todo-seen.json
    seen_path = os.path.join(HOME_DIR, "state", "todo-seen.json")
    seen = load_json(seen_path, {}) if shared else {}
    if not isinstance(seen, dict):
        checks.append(doctor_check("state", "warn", "todo-seen.json is not a JSON object: open todos lose when they were "
                                   "first seen", "reset it"))
    elif seen:
        gone = sorted(set(seen) - open_todo_keys(metas))
        if gone:
            checks.append(doctor_check("state", "warn", f"todo-seen.json: {len(gone)} of {len(seen)} entries are for todos "
                                       "no longer open", "drop them"))
        else:
            checks.append(doctor_check("state", "ok", f"todo-seen.json: {counted(len(seen), 'entry', 'entries')}, all for open todos"))

    # Lock files
    orphans = orphan_locks(metas) if shared else []
    if orphans:
        checks.append(doctor_check("state", "warn", f"{counted(len(orphans), 'lock file')} of no card or project",
                                   "remove them", orphans))
    elif os.path.isdir(LOCK_DIR) and shared:
        checks.append(doctor_check("state", "ok", "lock files: each belongs to a card, a project or HQ"))

    # Asks
    later = legacy_later_asks(metas)
    if later:
        checks.append(doctor_check("asks", "warn", f"{counted(len(later), 'ask')} on open tasks closed with `later` back when "
                                   "that closed asks for good — they never come back", "reopen them",
                                   [f"{a['id']:<9} {(a['at'] or '')[:10]}  {gist(a['text'], 60)}" for a in later]))
    else:
        checks.append(doctor_check("asks", "ok", "no ask left closed by an old `later`"))
    return checks


def doctor_fix(days=DOCTOR_DAYS):
    """Clear HQ's own stale state; returns what was done, one line each."""
    done = []
    root = hq_root(required=False)
    if not root or not os.path.isdir(os.path.join(root, "tasks")):
        return done
    metas = doctor_metas()
    shared = not other_root()

    if shared and os.path.exists(STATE):
        # Judged outside the lock (it searches transcripts, and every session's hooks wait on that
        # lock); only an entry unchanged since is removed.
        judged = load_json(STATE, None)
        stale = stale_bindings(judged, metas, days) if isinstance(judged, dict) else []
        with state_lock():
            state = load_state() if stale else None
            if isinstance(state, dict):
                stale = [x for x in stale if x["session"] in state and state[x["session"]] == judged[x["session"]]]
                for x in stale:
                    e = state.pop(x["session"])
                    # `delivered` in sessions.json is the older record of answers already told to a
                    # session, still honoured by the hook. A re-bound or continued session carries
                    # it over, so it can name asks of any task: each goes onto its own ask.
                    for aid in sorted(set(e.get("delivered") or []) if isinstance(e, dict) else []):
                        m = doctor_card(str(aid).rsplit(".", 1)[0], metas)
                        if not m:
                            continue
                        with card_lock(m["path"]):
                            a = next((a for a in read_asks(m["dir"]) if a["id"] == aid), None)
                            if a and not a.get("delivered"):
                                append_event(m["dir"], {"type": "delivered", "id": aid, "session": x["session"]})
                if stale:
                    save_state(state)
                    done.append(f"unbound {counted(len(stale), 'session')}")

    seen_path = os.path.join(HOME_DIR, "state", "todo-seen.json")
    seen = load_json(seen_path, {}) if shared else {}
    if not isinstance(seen, dict):
        atomic_write(seen_path, "{}")
        done.append("reset todo-seen.json")
    else:
        keep = open_todo_keys(doctor_metas())
        kept = {k: v for k, v in seen.items() if k in keep}
        if len(kept) < len(seen):
            atomic_write(seen_path, json.dumps(kept, ensure_ascii=False))
            done.append(f"dropped {counted(len(seen) - len(kept), 'todo-seen.json entry', 'todo-seen.json entries')}")

    removed = 0
    # The cards as they are now (one made during the binding pass has a lock already).
    for name in (orphan_locks(doctor_metas()) if shared else []):
        p = os.path.join(LOCK_DIR, name)
        if os.name == "nt":
            # Windows deletes no file any process has open, so a lock that is held (or being
            # taken) stays; nor would it delete this one while it is open here to test it.
            try:
                os.remove(p)
                removed += 1
            except OSError:
                pass
            continue
        try:
            with open(p, "a") as f:
                # Only a lock no one holds: unlinking a held one would let the next taker lock a
                # new file while the holder still works under the old one.
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.remove(p)
                removed += 1
        except OSError:
            pass
    if removed:
        done.append(f"removed {counted(removed, 'lock file')}")

    reopened = []
    for a in legacy_later_asks(metas):
        with card_lock(a["card"]):
            # Still closed by that `later`: an answer given since is not undone.
            now = next((x for x in read_asks(os.path.dirname(a["card"])) if x["id"] == a["id"]), None)
            if not now or now.get("state") != "later":
                continue
            append_event(os.path.dirname(a["card"]), {"type": "reopen", "id": a["id"], "via": "doctor"})
        await_answer(a["card"], "doctor")
        reopened.append(a["id"])
    if reopened:
        done.append(f"reopened {counted(len(reopened), 'ask')}: {', '.join(reopened)}")
    return done


DOCTOR_MARK = {"ok": "✓", "warn": "!", "error": "✗"}
DOCTOR_AREAS = [("hooks", "Hooks"), ("bindings", "Session bindings"), ("state", "State files"), ("asks", "Asks")]


def doctor_text(checks, fixed=None):
    lines = []
    if fixed is not None:
        lines += (["Fixed:"] + [f"  {x}" for x in fixed] if fixed else ["Nothing to fix."]) + ["", "Now:"]
    for area, title in DOCTOR_AREAS:
        group = [c for c in checks if c["area"] == area]
        if not group:
            continue
        lines.append(title)
        for c in group:
            lines.append(f"  {DOCTOR_MARK[c['level']]} {c['text']}" + (f"  [--fix: {c['fix']}]" if c["fix"] else ""))
            for it in c["items"][:12]:
                lines.append(f"      {it}")
            if len(c["items"]) > 12:
                lines.append(f"      … and {len(c['items']) - 12} more")
    problems = [c for c in checks if c["level"] != "ok"]
    fixable = [c for c in problems if c["fix"]]
    lines.append("")
    if not problems:
        lines.append("All good.")
    else:
        lines.append(counted(len(problems), "problem")
                     + (f"; `hq doctor --fix` clears {len(fixable)} of them." if fixable else "."))
    return "\n".join(lines)


def cmd_doctor(args):
    if args.days < 1:
        die("--days must be at least 1")
    fixed = doctor_fix(args.days) if args.fix else None
    checks = gather_doctor(args.days)
    if args.json:
        print(json.dumps({"checks": checks, "fixed": fixed}, ensure_ascii=False, indent=1))
    else:
        print(doctor_text(checks, fixed))
    if any(c["level"] == "error" for c in checks):
        sys.exit(1)
