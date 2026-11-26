"""Onboarding: `hq scan` over existing sessions and `hq import` of a plan."""
import argparse
import contextlib
import datetime as dt
import io
import json
import os
import re
import sys
import time

from .core import card_lock, die, hq_root, is_placeholder, ok_workdir, STATUSES, today
from .sessions import load_state, PET_SESSIONS, pid_alive
from .cards import append_log, card_paths, parse_card, safe_name, set_fields, STATUS_HEADING_RE, todo_owner
from .projects import (
    check_project_name, ensure_project_file, load_project, load_projects, norm_path, project_file,
    project_for_dirs, project_for_path, PROJECT_KINDS, same_name_project, save_projects,
    write_project_section,
)
from .focus import new_card, set_card_goal, task_template
from .update import _apply_update
from .peek import message_role, message_text, pet_session, session_title, transcript_tail


# ---------------------------------------------------------------- onboarding scan
# Reads the Claude Code transcripts already on this machine and lists the sessions, grouped by git
# repository (or directory outside one). Deterministic and read-only unless --apply-projects (one
# kind-less project per repository: kept for scripts). Turning sessions into task cards and lines of
# work needs judgment: /hq-onboard (Claude) does that with this output and writes it with `hq import`.
SCAN_SKIP = re.compile(r"-private-|-var-folders-|^-tmp-|-T-tgkb-|scratchpad")


def transcript_head(path, nbytes=96_000):
    out = []
    with open(path, "rb") as f:
        chunk = f.read(nbytes).decode("utf-8", "ignore").splitlines()
    for line in chunk[:-1] if len(chunk) > 1 else chunk:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def git_root(path):
    home = os.path.realpath(os.path.expanduser("~"))
    cur = os.path.realpath(path)
    while cur not in ("/", home) and os.path.dirname(cur) != cur:
        if os.path.exists(os.path.join(cur, ".git")):
            return cur
        cur = os.path.dirname(cur)
    return None


def scan_sessions(days):
    base = os.path.expanduser("~/.claude/projects")
    cutoff = time.time() - days * 86400
    state = load_state()
    rows = []
    for slug in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        if SCAN_SKIP.search(slug):
            continue
        d = os.path.join(base, slug)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(d, name)
            mtime = os.path.getmtime(path)
            if mtime < cutoff:
                continue
            head = transcript_head(path)
            tail = transcript_tail(path, 250_000)
            cwd = next((o.get("cwd") for o in head + tail if o.get("cwd")), None)
            if not cwd:
                continue
            first = next((t for t in (message_text(o) for o in head if message_role(o) == "user") if t), "")
            users = sum(1 for o in tail if message_role(o) == "user" and message_text(o))
            sid = name[:-6]
            pet = pet_session(sid) or {}
            rows.append({
                "sessionId": sid, "cwd": cwd, "title": session_title(tail) or session_title(head),
                "first": first[:200], "last": dt.datetime.fromtimestamp(mtime).astimezone().isoformat(timespec="minutes"),
                "turns_in_tail": users, "live": pid_alive(pet.get("pid")) if pet else False,
                "task": state.get(sid, {}).get("task"), "transcript": path,
            })
    rows.sort(key=lambda r: r["last"], reverse=True)
    return rows


def scan_projects(sessions):
    home = os.path.realpath(os.path.expanduser("~"))
    skip = {"/", home, os.path.realpath(hq_root(required=False) or "/")}
    groups = {}
    for r in sessions:
        root = git_root(r["cwd"]) or os.path.realpath(r["cwd"])
        if root in skip or not os.path.isdir(root):
            continue
        g = groups.setdefault(root, {"path": root, "name": safe_name(os.path.basename(root)), "sessions": [], "last": ""})
        g["sessions"].append(r["sessionId"])
        g["last"] = max(g["last"], r["last"])
        r["root"] = root
    out = sorted(groups.values(), key=lambda g: g["last"], reverse=True)
    for g in out:
        g["existing"] = project_for_path(g["path"]) or None
        g["count"] = len(g["sessions"])
    return out


def cmd_scan(args):
    sessions = scan_sessions(args.days)
    projects = scan_projects(sessions)
    if args.apply_projects:
        only = set(x.strip() for x in (args.only or "").split(",") if x.strip())
        taken = set(x["name"] for x in load_projects())
        added = []
        for g in projects:
            if g["existing"] or (only and g["name"] not in only and g["path"] not in only):
                continue
            name, n = safe_name(g["name"]), 2
            while name in taken:
                suffix = f"-{n}"
                name, n = safe_name(g["name"])[:40 - len(suffix)] + suffix, n + 1
            save_projects(load_projects() + [{"name": name, "paths": [g["path"]]}])
            taken.add(name)
            added.append(name)
        assigned = 0
        for path in card_paths():
            meta = parse_card(path)
            if not meta.get("project"):
                guess = project_for_dirs(meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else [])
                if guess:
                    set_fields(path, {"project": guess, "updated": meta.get("updated", today())})
                    assigned += 1
        print(json.dumps({"added": added, "assigned": assigned}) if args.json
              else f"added {len(added)} project(s): {', '.join(added) or '-'}; assigned {assigned} task(s)")
        return
    if args.json:
        print(json.dumps({"days": args.days, "projects": projects, "sessions": sessions}, ensure_ascii=False, indent=1))
        return
    print(f"Sessions in the last {args.days} days: {len(sessions)}\n")
    print("Suggested projects:")
    for g in projects:
        flag = f"(already: {g['existing']})" if g["existing"] else "(new)"
        print(f"  {g['name']:<24} {g['count']:>3} session(s)  last {g['last'][:16]}  {flag}  {g['path']}")
    print("\nSessions:")
    for r in sessions:
        live = "live " if r["live"] else "     "
        print(f"  {r['sessionId'][:8]} {live}{r['last'][:16]}  {os.path.basename(r.get('root') or r['cwd']):<20} "
              f"{(r['title'] or r['first'] or '')[:60]}")
    print("\nThese are repositories, not projects: one often holds several lines of work."
          "\nTurn the sessions into duties, projects and task cards: run /hq-onboard in Claude Code.")


# ---------------------------------------------------------------- onboarding import
# /hq-onboard ends in one plan: the projects (goals and duties) and task cards Claude drafted from
# the user's sessions and the user confirmed. `hq import` checks the whole plan before writing
# anything — one call instead of a new/set/addtodo/ref/log/bind per task, each a model round trip
# over the whole conversation — and --dry-run shows the user what it would create.
IMPORT_PROJECT_KEYS = ("name", "kind", "title", "goal", "done_when", "brief", "parent", "due", "paths")
IMPORT_TASK_KEYS = ("title", "project", "status", "next", "state", "goal", "todos", "refs", "workdirs",
                    "sessions", "confidence", "log")


def checked(fn, *a):
    """fn(*a) → (result, None), or (None, why) where fn would have died."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            return fn(*a), None
    except SystemExit:
        return None, re.sub(r"^hq: ", "", err.getvalue().strip()) or "invalid"


def flat_text(v):
    """One line, the whole of it (one_line cuts it short)."""
    return " ".join(str(v).split())


def transcript_ids():
    base = os.path.expanduser("~/.claude/projects")
    out = set()
    for slug in os.listdir(base) if os.path.isdir(base) else []:
        d = os.path.join(base, slug)
        if os.path.isdir(d):
            out.update(n[:-6] for n in os.listdir(d) if n.endswith(".jsonl"))
    return out


def import_check(plan):
    """(problems, projects, tasks): the plan's projects and tasks normalized, and every reason it
    can't be applied as it stands. Writes nothing."""
    problems = []
    if not isinstance(plan, dict):
        return ["the plan is a JSON object: {\"projects\": [...], \"tasks\": [...]}"], [], []
    extra = set(plan) - {"projects", "tasks"}
    if extra:
        problems.append(f"unknown top-level key(s): {', '.join(sorted(extra))} (a plan has projects and tasks)")
    listed = [x["name"] for x in load_projects()]
    used = {(parse_card(p).get("project") or "") for p in card_paths()}
    projects, tasks, kinds = [], [], {}

    def strings(where, item, key):
        v = item.get(key)
        if v is None:
            return []
        if isinstance(v, str):
            v = [v]
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            problems.append(f"{where}: `{key}` is a list of strings")
            return []
        return [flat_text(x) for x in v if x.strip()]

    def text_of(where, item, key, flat=True):
        v = item.get(key)
        if v is None:
            return ""
        if key == "done_when" and isinstance(v, list) and all(isinstance(x, str) for x in v):
            v = "\n".join("- " + re.sub(r"^\s*[-*]\s+", "", flat_text(x)) for x in v if x.strip())
        if not isinstance(v, str):
            problems.append(f"{where}: `{key}` is a string" + (" (or a list of criteria)" if key == "done_when" else ""))
            return ""
        return flat_text(v) if flat else v.strip()

    def owner(path, extra):
        """The project whose directory holds `path` (deepest wins), counting the plan's new ones."""
        best, depth = "", -1
        t = norm_path(path)
        for name, roots in [(x["name"], x["paths"]) for x in load_projects()] + extra:
            for r in map(norm_path, roots):
                if (t == r or t.startswith(r + os.sep)) and len(r) > depth:
                    best, depth = name, len(r)
        return best

    def dirs(where, raw):
        out = []
        for d in raw:
            n = os.path.normpath(os.path.expanduser(d))
            if not os.path.isabs(n) or not os.path.isdir(n):
                problems.append(f"{where}: {d!r} is not an existing absolute path")
            elif not ok_workdir(n):
                problems.append(f"{where}: {d!r} — /, the home folder and the HQ root are never a project's or task's directory")
            else:
                out.append(n)
        return list(dict.fromkeys(out))

    raw_projects = plan.get("projects") or []
    if not isinstance(raw_projects, list):
        problems.append("`projects` is a list")
        raw_projects = []
    for i, pr in enumerate(raw_projects):
        where = f"project #{i + 1}"
        if not isinstance(pr, dict):
            problems.append(f"{where} is not an object")
            continue
        where = f"project {pr.get('name') or '#' + str(i + 1)!r}"
        bad = set(pr) - set(IMPORT_PROJECT_KEYS)
        if bad:
            problems.append(f"{where}: unknown key(s) {', '.join(sorted(bad))} (keys: {', '.join(IMPORT_PROJECT_KEYS)})")
        name, why = checked(check_project_name, str(pr.get("name") or ""))
        if why:
            problems.append(f"{where}: {why}")
            continue
        if name in listed:
            problems.append(f"{where} already exists — leave it out of `projects` and use it by name in tasks")
        elif os.path.exists(os.path.dirname(project_file(name))):
            problems.append(f"{where}: {os.path.dirname(project_file(name))} is left from an earlier project — "
                            "pick another name, or remove that folder first")
        elif same_name_project(name, listed + list(used)):
            problems.append(f"{where}: {same_name_project(name, listed + list(used))!r} already exists — "
                            "names that differ only in case would share a folder")
        elif name in kinds or same_name_project(name, list(kinds)):
            problems.append(f"{where} is in the plan twice")
        kind = pr.get("kind")
        if kind not in PROJECT_KINDS:
            problems.append(f"{where}: kind is goal (has an end) or duty (a standing responsibility), got {kind!r}")
        due = text_of(where, pr, "due")
        if due:
            try:
                dt.date.fromisoformat(due)
            except ValueError:
                problems.append(f"{where}: due is a date, YYYY-MM-DD (got {due!r})")
            if kind == "duty":
                problems.append(f"{where}: a duty has no deadline")
        text = {k: text_of(where, pr, k, flat=False) for k in ("goal", "done_when", "brief")}
        for k, v in text.items():
            if v and is_placeholder(v):
                problems.append(f"{where}: `{k}` is a placeholder, not a value")
        kinds[name] = kind
        projects.append({"name": name, "kind": kind, "title": text_of(where, pr, "title") or name,
                         "parent": text_of(where, pr, "parent"), "due": due,
                         "paths": dirs(where, strings(where, pr, "paths")), **text})
    for pr in projects:
        parent = pr["parent"]
        if not parent:
            continue
        where = f"project {pr['name']!r}"
        if pr["kind"] != "goal":
            problems.append(f"{where}: only a goal sits under a duty")
        elif parent == pr["name"]:
            problems.append(f"{where} can't sit under itself")
        elif kinds.get(parent, (load_project(parent) or {}).get("kind") if parent in listed else None) != "duty":
            problems.append(f"{where}: parent must be a duty, existing or in the plan (no duty {parent!r})")

    raw_tasks = plan.get("tasks") or []
    if not isinstance(raw_tasks, list):
        problems.append("`tasks` is a list")
        raw_tasks = []
    known_ids = transcript_ids() | {n[:-5] for n in (os.listdir(PET_SESSIONS) if os.path.isdir(PET_SESSIONS) else [])
                                    if n.endswith(".json")}
    state = load_state()
    me = os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    claimed = {}
    open_titles, on_cards = {}, {}
    for p in card_paths():
        m = parse_card(p)
        for x in m.get("sessions") if isinstance(m.get("sessions"), list) else []:
            on_cards.setdefault(str(x)[:8], m.get("id"))
        if m.get("status") not in ("done", "abandoned"):
            open_titles.setdefault((m.get("project") or "", flat_text(m.get("title") or "").casefold()), m.get("id"))
    plan_paths = [(x["name"], x["paths"]) for x in projects]
    has_status = bool(STATUS_HEADING_RE.search(task_template()))
    for i, t in enumerate(raw_tasks):
        where = f"task #{i + 1}"
        if not isinstance(t, dict):
            problems.append(f"{where} is not an object")
            continue
        title = text_of(where, t, "title")
        if title:
            where = f"task {title!r}"
        else:
            problems.append(f"{where} has no title")
        bad = set(t) - set(IMPORT_TASK_KEYS)
        if bad:
            problems.append(f"{where}: unknown key(s) {', '.join(sorted(bad))} (keys: {', '.join(IMPORT_TASK_KEYS)})")
        project = text_of(where, t, "project")
        if project and project not in listed and project not in kinds and project not in used:
            problems.append(f"{where}: no project {project!r} — existing ({', '.join(listed) or 'none'}) or in the plan's projects")
        status = text_of(where, t, "status") or "active"
        if status not in STATUSES:
            problems.append(f"{where}: status must be one of {', '.join(STATUSES)} (got {status!r})")
        state_lines = strings(where, t, "state")
        if any(x.startswith("#") for x in state_lines):
            problems.append(f"{where}: a state line can't be a heading")
        if state_lines and not has_status:
            problems.append(f"{where}: `state` needs a `## Status` / `## 当前状态` section, and the task template "
                            "(templates/TASK.md) has none — leave state out or add the section to the template")
        sessions = []
        for sid in strings(where, t, "sessions"):
            hits = [x for x in known_ids if x == sid] or ([x for x in known_ids if x.startswith(sid)] if len(sid) >= 8 else [])
            if len(hits) != 1:
                problems.append(f"{where}: session {sid!r} " + ("matches several — give more of it" if hits else "is not a session on this machine"))
                continue
            full = hits[0]
            bound = state.get(full, {}).get("task") or on_cards.get(full[:8])
            if full == me:
                problems.append(f"{where}: {full[:8]} is this session — it isn't one of the sessions being imported")
            elif bound:
                problems.append(f"{where}: session {full[:8]} is already on {bound}")
            elif full in claimed:
                problems.append(f"{where}: session {full[:8]} is also on task {claimed[full]!r} — one task per session")
            else:
                claimed[full] = title
                pet = pet_session(full) or {}
                sessions.append({"id": full, "live": bool(pet) and pid_alive(pet.get("pid"))})
        values = {"next": text_of(where, t, "next"), "confidence": text_of(where, t, "confidence"),
                  "goal": text_of(where, t, "goal", flat=False)}
        workdirs = dirs(where, strings(where, t, "workdirs"))
        if not project:
            # What the card will get anyway (new_card by its workdirs, a bind by the session's
            # directory): decided here, so the preview and the title check see it.
            for d in workdirs + [(pet_session(s["id"]) or {}).get("cwd") or "" for s in sessions if s["live"]]:
                project = owner(d, plan_paths) if d else ""
                if project:
                    break
        dup = open_titles.get((project, title.casefold()))
        if title and dup:
            problems.append(f"{where}: {dup} already has this title in {project or 'no project'} — leave it out, or say what is new")
        elif title:
            open_titles[(project, title.casefold())] = "another task in the plan"
        lists = {k: strings(where, t, k) for k in ("todos", "refs", "log")}
        # A todo with no owner shows in nobody's list: not Needs you (@me), not a session's (@claude).
        for x in lists["todos"]:
            if not todo_owner(x):
                problems.append(f"{where}: todo {x!r} has no owner — start it with @me (the user does it), "
                                "@claude (a session does it) or @<name> (someone else)")
        for v in [title, values["next"], values["goal"]] + state_lines + sum(lists.values(), []):
            if v and is_placeholder(v):
                problems.append(f"{where}: {v!r} is a placeholder, not a value")
        tasks.append({"title": title, "project": project, "status": status, "state": state_lines,
                      "workdirs": workdirs, "sessions": sessions,
                      **values, **lists})
    if not projects and not tasks and not problems:
        problems.append("the plan is empty")
    return problems, projects, tasks


def import_apply(projects, tasks):
    """Write a checked plan: duties first (a goal can sit under one made here), then the tasks."""
    from .commands import cmd_bind
    made_projects, made_tasks = [], []
    for pr in sorted(projects, key=lambda x: x["kind"] != "duty"):
        save_projects(load_projects() + [{"name": pr["name"], "paths": pr["paths"]}])
        fields = {k: pr[k] for k in ("kind", "title", "parent", "due") if pr[k]}
        path = ensure_project_file(pr["name"], fields)
        for k in ("goal", "done_when", "brief"):
            if pr[k]:
                write_project_section(path, k, pr[k], pr["kind"])
        append_log(path, "Created by /hq-onboard (hq import) from the user's Claude Code sessions", touch=False)
        made_projects.append(pr["name"])
    for t in tasks:
        tid, card = new_card(t["title"], project=t["project"] or None, workdirs=t["workdirs"], focus=False)
        if t["goal"]:
            set_card_goal(card, t["goal"])
        ids = ", ".join(s["id"][:8] for s in t["sessions"]) or "none"
        note = f"Created by /hq-onboard from sessions {ids}" + (f" (confidence {t['confidence']})" if t["confidence"] else "") \
            + "; the status was inferred from the conversations — check it."
        entries = [("status", t["status"])] + [("next", t["next"])] * bool(t["next"]) \
            + [("state", x) for x in t["state"]] + [("todo", x) for x in t["todos"]] \
            + [("ref", x) for x in t["refs"]] + [("log", note)] + [("log", x) for x in t["log"]]
        with card_lock(card):
            left = _apply_update(card, entries, "import")
            if left:    # checked beforehand, so not expected: write what can be written, and say so
                with contextlib.suppress(Exception):
                    _apply_update(card, [e for e in entries if e[0] != "state"], "import")
        for s in t["sessions"]:
            if s["live"]:
                with contextlib.redirect_stdout(io.StringIO()):
                    cmd_bind(argparse.Namespace(session=s["id"], task=tid))
        ended = [s["id"][:8] for s in t["sessions"] if not s["live"]]
        if ended:
            have = parse_card(card).get("sessions")
            have = have if isinstance(have, list) else []
            set_fields(card, {"sessions": have + [x for x in ended if x not in have]})
        meta = parse_card(card)
        made_tasks.append({"id": tid, "title": t["title"], "project": meta.get("project") or "",
                           "status": meta.get("status"), "problems": left})
    return made_projects, made_tasks


def import_preview(projects, tasks):
    out = []
    if projects:
        out.append(f"Projects to create ({len(projects)}):")
        for pr in sorted(projects, key=lambda x: x["kind"] != "duty"):
            bits = [pr["kind"], f'"{pr["title"]}"'] + [f"under {pr['parent']}"] * bool(pr["parent"]) \
                + [f"due {pr['due']}"] * bool(pr["due"]) + [f"dirs {', '.join(pr['paths'])}"] * bool(pr["paths"])
            out.append(f"  + {pr['name']:<20} " + " · ".join(bits))
    if tasks:
        out.append(f"Tasks to create ({len(tasks)}):")
        for name in dict.fromkeys(t["project"] for t in tasks):
            out.append(f"  {name or '(no project)'}")
            for t in (x for x in tasks if x["project"] == name):
                ses = ", ".join(s["id"][:8] + (" live" if s["live"] else "") for s in t["sessions"]) or "no sessions"
                meta = [f"{len(t['todos'])} todo(s)"] * bool(t["todos"]) + [f"{len(t['refs'])} link(s)"] * bool(t["refs"]) \
                    + [ses] + [t["confidence"]] * bool(t["confidence"])
                out.append(f"    {t['status']:<13} {t['title']}")
                if t["next"]:
                    out.append(f"    {'':<13} next: {t['next']}")
                out.append(f"    {'':<13} " + " · ".join(meta))
    return "\n".join(out)


def cmd_import(args):
    try:
        raw = sys.stdin.read() if args.plan == "-" else open(os.path.expanduser(args.plan), encoding="utf-8").read()
        plan = json.loads(raw)
    except OSError as e:
        die(f"can't read the plan: {e}")
    except ValueError as e:
        die(f"the plan is not valid JSON: {e}")
    problems, projects, tasks = import_check(plan)
    if problems or args.dry_run:
        if args.json:
            print(json.dumps({"ok": not problems, "dry_run": args.dry_run, "written": False, "problems": problems,
                              "projects": projects, "tasks": tasks}, ensure_ascii=False, indent=1))
        else:
            if problems:
                print("Nothing written — fix these and run it again:\n" + "\n".join(f"  - {p}" for p in problems)
                      + ("\n" if projects or tasks else ""))
            if projects or tasks:
                print(import_preview(projects, tasks))
        sys.exit(1 if problems else 0)
    made_projects, made_tasks = import_apply(projects, tasks)
    failed = any(t["problems"] for t in made_tasks)
    if args.json:
        print(json.dumps({"ok": not failed, "dry_run": False, "written": True, "projects": made_projects,
                          "tasks": made_tasks}, ensure_ascii=False, indent=1))
        sys.exit(1 if failed else 0)
    if made_projects:
        print(f"created {len(made_projects)} project(s): {', '.join(made_projects)}")
    for t in made_tasks:
        print(f"{t['id']}  {t['status']:<13} {t['project'] or '-':<16} {t['title']}")
        for p in t["problems"]:
            print(f"      ! {p}")
    if failed:
        print("Some cards were written only in part (marked !): fix them on the board or with hq set / hq log.")
        sys.exit(1)
