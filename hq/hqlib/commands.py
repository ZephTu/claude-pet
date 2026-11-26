"""The small card commands: new, bind, set, todo, ref, workdir, ask, focus and the like."""
import json
import os
import sys

from .core import card_lock, die, now_iso, ok_workdir, snoozed, STATUS_ALIASES, STATUSES
from .sessions import bound_task, load_state, save_state, session_id, state_lock
from .cards import (
    _set_fields, add_todo, append_log, card_paths, card_todos, category_usage, check_category, ensure_listed,
    find_card, load_categories, mark_todo, parse_card, recategorize, save_categories, set_fields, todo_owner,
)
from .refs import KEY_MARK, merge_refs, ref_key, unmarked
from .history import history_add, history_drop_links, process_ref
from .projects import (
    brief_hash, ensure_project, fill_template, intake_lang, intake_manual, INTAKE_MANUAL_DONE, load_project,
    prefs_text, project_brief_text, project_for_dirs, project_for_path,
)
from .asks import (
    add_ask, append_event, await_answer, CLOSED_STATUSES, find_ask, read_asks, resolve_ask, settle_status,
    snooze_ask, snooze_until,
)
from .protocol import open_asks_text, protocol
from .focus import focus_add, focus_state, load_focus, new_card, save_focus, set_card_goal
from .peek import pet_session


def cmd_category(args):
    cats = load_categories()
    usage = category_usage()
    if args.action == "list":
        rows = [{"name": c, "count": usage.get(c, 0), "listed": True} for c in cats]
        rows += [{"name": c, "count": n, "listed": False} for c, n in usage.items() if c and c not in cats]
        if args.json:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
            return
        for r in rows:
            print(f"{r['name']:<24} {r['count']:>3} task(s){'' if r['listed'] else '   (not in list — used on cards)'}")
        if usage.get(""):
            print(f"{'(none)':<24} {usage['']:>3} task(s)")
        return
    if not args.names:
        die(f"usage: hq category {args.action} NAME" + (" NEW" if args.action == "rename" else ""))
    name = check_category(args.names[0])
    if args.action == "add":
        if name in cats:
            die(f"category {name!r} already exists")
        save_categories(cats + [name])
    elif args.action == "rename":
        if len(args.names) < 2:
            die("usage: hq category rename OLD NEW")
        new = check_category(args.names[1])
        if new in cats and new != name:
            die(f"{new!r} already exists — to merge, use: hq category remove {name!r} --to {new!r}")
        if name not in cats and not usage.get(name):
            die(f"no category {name!r}")
        save_categories([new if c == name else c for c in cats] if name in cats else cats + [new])
        n = recategorize(name, new)
        print(f"renamed {name!r} → {new!r} ({n} task(s) updated)")
    elif args.action == "remove":
        n_used = usage.get(name, 0)
        if n_used and args.to is None:
            print(f"hq: {n_used} task(s) use {name!r}. Re-run with --to <category> to move them, "
                  f"or --to '' to leave them uncategorized.", file=sys.stderr)
            sys.exit(3)
        to = ""
        if args.to:
            to = check_category(args.to)
            if to == name:
                die("--to must be a different category")
            ensure_listed(to)
        save_categories([c for c in load_categories() if c != name])
        n = recategorize(name, to) if n_used else 0
        print(f"removed {name!r}" + (f" ({n} task(s) moved to {to or '(none)'!r})" if n else ""))


def cmd_focus(args):
    if args.action in ("add", "remove"):
        if not args.tasks:
            die(f"usage: hq focus {args.action} T-012 ...")
        ids = [parse_card(find_card(x))["id"] for x in args.tasks]
        if args.action == "add":
            focus_add(ids)
        else:
            save_focus([i for i in load_focus() if i not in ids])
    elif args.action == "order":
        # Focus in the given order (the board's drag); anything not named keeps its place after.
        ids = list(dict.fromkeys(parse_card(find_card(x))["id"] for x in args.tasks))   # no repeats
        cur = load_focus()
        save_focus([i for i in ids if i in cur] + [i for i in cur if i not in ids])
    elif args.action == "carry":
        pass                        # nothing to carry: Focus no longer resets each day
    st = focus_state()
    if args.json:
        print(json.dumps(st, ensure_ascii=False))
        return
    print(f"Focus: {', '.join(st['ids']) or '— nothing in Focus yet'}")


def cmd_new(args):
    title, goal, todos = args.title, args.goal, []
    if args.template:
        # One of the project's "common work" templates: its title (unless one is given), goal and todos.
        if not args.project:
            die("--template needs --project (the duty or project the template belongs to)")
        pr = load_project(check_category(args.project)) or {}
        want = args.template.strip().casefold()
        tpl = next((t for t in pr.get("templates", []) if t["name"].casefold() == want), None)
        if not tpl:
            names = ", ".join(t["name"] for t in pr.get("templates", [])) or "none"
            die(f"project {args.project!r} has no template {args.template!r} (templates: {names})")
        # A title or goal the board prefilled from the template still has its {date} to fill.
        title = fill_template(title or tpl["title"] or tpl["name"])
        goal = fill_template(goal or tpl["goal"])
        todos = [fill_template(t) for t in tpl["todos"]]
    if not (title or "").strip():
        die("a task needs a title")
    tid, p = new_card(title, slug=args.slug, category=args.category or None, project=args.project,
                      lead=args.lead, workdirs=args.workdir, focus=not args.no_focus)
    if args.phase:
        set_fields(p, {"phase": args.phase})
    if (goal or "").strip():
        set_card_goal(p, goal)
    for t in todos:
        add_todo(p, t)
    print(tid)
    print(p)


def cmd_bind(args):
    sid = session_id(args.session)
    if not sid:
        die("no session id (run inside Claude Code or pass --session)")
    card = find_card(args.task)
    meta = parse_card(card)
    # Bound from inside the session (its own Bash tool) the session reads this output now;
    # bound from outside (the board) it learns the rules on its next prompt.
    from_inside = sid == os.environ.get("CLAUDE_CODE_SESSION_ID")
    fields = {}
    sessions = meta.get("sessions") if isinstance(meta.get("sessions"), list) else []
    if sid[:8] not in sessions:
        fields["sessions"] = sessions + [sid[:8]]
    # The session's directory is where this task's work happens: remember it on the card.
    cwd = os.getcwd() if from_inside else (pet_session(sid) or {}).get("cwd")
    workdirs = meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else []
    if cwd and cwd not in workdirs and ok_workdir(cwd):
        fields["workdirs"] = workdirs + [cwd]
    if not meta.get("project"):
        # Only a default: the folder suggests a project, the card's `project` decides.
        guess = project_for_path(cwd) or project_for_dirs(workdirs)
        if guess:
            fields["project"] = guess
    if fields:
        set_fields(card, fields)
        meta = parse_card(card)         # its project decides the brief
    brief, prefs = project_brief_text(meta), prefs_text(meta)
    with state_lock():
        state = load_state()
        old = state.get(sid, {})
        prev = old.get("task")
        state[sid] = {"task": meta["id"], "bound_at": now_iso(), "announced": from_inside,
                      "delivered": old.get("delivered", [])}
        if from_inside:
            state[sid]["brief"] = brief_hash(brief)
            state[sid]["prefs"] = brief_hash(prefs)
        save_state(state)
    if prev and prev != meta["id"]:
        print(f"(re-bound from {prev})")
    print(protocol(meta))
    if from_inside:
        for t in (brief, prefs):
            if t:
                print("\n" + t)
    t = open_asks_text(meta)
    if t:
        print("\n" + t)


def cmd_unbind(args):
    sid = session_id(args.session)
    with state_lock():
        state = load_state()
        if state.pop(sid, None) is None:
            print("this session was not bound")
        save_state(state)


def cmd_whoami(args):
    sid = session_id(args.session)
    t = bound_task(sid)
    print(t or "(not bound)")


def cmd_touch(args):
    set_fields(find_card(args.task), {})


def cmd_log(args):
    append_log(find_card(args.task), args.message)


def cmd_set(args):
    fields = {}
    for kv in args.fields:
        if "=" not in kv:
            die(f"expected key=value, got {kv}")
        k, v = kv.split("=", 1)
        if k == "status":
            v = STATUS_ALIASES.get(v.lower(), v.lower())
            if v not in STATUSES:
                die(f"status must be one of {', '.join(STATUSES)} (or {', '.join(STATUS_ALIASES)})")
        if k == "category" and v:
            v = check_category(v)
            ensure_listed(v)
        if k == "project" and v:
            v = check_category(v)
            ensure_project(v)
        fields[k] = v
    card = find_card(args.task)
    if "status" in fields:
        fields.setdefault("closing", None)   # a status set outright replaces a held close
        if parse_card(card).get("intake"):
            if fields["status"] in CLOSED_STATUSES and os.environ.get("CLAUDE_CODE_SESSION_ID") and intake_manual(card):
                die(f"{args.task}: {INTAKE_MANUAL_DONE[intake_lang(card)]}")
            fields["intake_closed_by"] = None    # closed by the user (or reopened)
    set_fields(card, fields)


def cmd_todo(args):
    card = find_card(args.task)
    with card_lock(card):
        _cmd_todo(args, card)


def _cmd_todo(args, card):
    lines = open(card, encoding="utf-8").read().split("\n")
    todos = card_todos(lines)
    pick = next((x for x in todos if x[1] == args.index), None)
    if args.text is not None:
        # The caller saw this text at #index; the card may have changed since (a session added
        # or removed a todo). Trust the text, not the position.
        want = " ".join(args.text.split())
        if not pick or pick[3] != want:
            pick = next((x for x in todos if x[3] == want), None)
            if not pick:
                die(f"{args.task} no longer has the todo {args.text!r} — refresh and try again")
    if not pick:
        die(f"{args.task} has no todo #{args.index}")
    mark_todo(card, lines, pick, args.state, args.via)
    if todo_owner(pick[2].group(3)) == "me":
        if args.state in ("done", "drop"):
            settle_status(card, args.via)
        else:
            await_answer(card, args.via)    # the board's Undo of a tick


def cmd_workdir(args):
    """hq workdir add|remove T-1 PATH: the folders a task's work happens in; the board's New session
    starts in the first. Binding a session adds its folder by itself — this is for a task that has
    none yet (made on the board or from a quick note) or the wrong one. remove prints what it took
    out as JSON ({"removed": [{i, path}, …]}); `hq workdir restore T-1 '<that JSON>'` puts it back
    where it was, a folder that has since gone included."""
    card = find_card(args.task)
    norm = lambda w: os.path.normpath(os.path.abspath(os.path.expanduser(w)))
    with card_lock(card):
        meta = parse_card(card)
        have = [w for w in meta.get("workdirs") or [] if isinstance(w, str)] if isinstance(meta.get("workdirs"), list) else []
        if args.action == "restore":
            try:
                back = sorted((int(x["i"]), str(x["path"])) for x in json.loads(args.path)["removed"])
            except (ValueError, KeyError, TypeError) as e:
                die(f"restore wants the JSON remove printed: {e}")
            out = list(have)
            for i, w in back:
                if norm(w) not in {norm(x) for x in out}:
                    out.insert(min(max(i, 0), len(out)), w)
            _set_fields(card, {"workdirs": out})
            return
        d = norm(args.path)
        if args.action == "add":
            if not os.path.isdir(d):
                die(f"{args.path}: no such folder")
            if not ok_workdir(d):
                die(f"{args.path}: /, the home folder and the HQ root are never a task's folder")
            if d in (norm(w) for w in have):
                return
            fields = {"workdirs": have + [d]}
            if not meta.get("project") and project_for_path(d):
                fields["project"] = project_for_path(d)
            _set_fields(card, fields)
        else:
            gone = [{"i": i, "path": w} for i, w in enumerate(have) if norm(w) == d]
            if not gone:
                die(f"{args.path} is not one of {meta.get('id', args.task)}'s folders")
            _set_fields(card, {"workdirs": [w for w in have if norm(w) != d]})
            print(json.dumps({"removed": gone}, ensure_ascii=False))


def cmd_ref(args):
    card = find_card(args.task)
    with card_lock(card):
        _cmd_ref(args, card)


def _cmd_ref(args, card):
    meta = parse_card(card)
    refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
    if args.action in ("add", "pin"):
        # add: a process link (a build, a comment) goes on to HISTORY.md with the card's next write.
        # pin: a key link — kept on the card whatever it points to (the key mark when it needs one),
        # and taken out of HISTORY.md if it was there.
        ref = unmarked(args.ref) if args.action == "pin" else args.ref.strip()
        if not ref or "\n" in ref:
            die("empty ref")
        if args.action == "pin" and process_ref(ref):
            ref = KEY_MARK + ref
        merged = merge_refs(refs, [ref])
        if args.action == "pin":
            history_drop_links(card, {ref_key(ref)})
        if merged != refs:
            set_fields(card, {"refs": merged})
    elif args.action == "remove":
        # Removing a link removes every entry pointing at it, on the card and in HISTORY.md, so no
        # older duplicate shows up again. What went off the card is printed as JSON —
        # {"removed": [{"i": index, "ref": text}, …]}, plus "history": [text, …] when any went from there — and `hq ref restore`
        # takes it back, which is how the board's Undo puts every entry back.
        key = ref_key(args.ref)
        gone = [{"i": i, "ref": r} for i, r in enumerate(refs) if ref_key(r) == key]
        hist = history_drop_links(card, {key})
        if not gone and not hist:
            die(f"{args.task} has no ref {args.ref!r}")
        if gone:
            set_fields(card, {"refs": [r for r in refs if ref_key(r) != key]})
        print(json.dumps(dict({"removed": gone}, **({"history": hist} if hist else {})), ensure_ascii=False))
    else:
        # restore: undo a remove. Each entry goes back at its old index (in order, so the list is
        # as it was if nothing changed meanwhile). A link that is on the card again by now (re-added
        # since, or a second Undo) is left as it is.
        try:
            items = json.loads(args.ref)
            if isinstance(items, dict) and isinstance(items.get("history"), list):
                history_add(card, links=[str(x) for x in items["history"] if str(x).strip()])
            items = items.get("removed", items) if isinstance(items, dict) else items
            items = sorted(((int(x["i"]), str(x["ref"]).strip()) for x in items), key=lambda x: x[0])
        except (ValueError, TypeError, KeyError, AttributeError):
            die("restore takes the JSON `hq ref remove` printed")
        out = [str(r) for r in refs]
        there = {ref_key(r) for r in out}
        for i, r in items:
            if r and "\n" not in r and ref_key(r) not in there:
                out.insert(max(0, min(i, len(out))), r)
        if out != refs:
            set_fields(card, {"refs": out})


def cmd_addtodo(args):
    add_todo(find_card(args.task), args.text)

def cmd_ask(args):
    if args.action == "add":
        print(add_ask(find_card(args.target), " ".join(args.rest), session_id(None) or None))
    elif args.action == "delivered":
        # The board typed this answer straight into the session: don't inject it again next turn.
        card, a = find_ask(args.target)
        sid = args.session or a.get("session")
        append_event(os.path.dirname(card), {"type": "undelivered" if args.undo else "delivered",
                                             "id": args.target, "session": sid})
    elif args.action == "snooze":
        # The ask stays open; the board and the pet leave it out until then. --until "" clears it.
        if snooze_until(args.until) is None:
            die(f"--until must be a date or time like 2026-11-22 or 2026-11-22T09:00, not {args.until!r}")
        snooze_ask(args.target, args.until, args.note or "", via=args.via)
    elif args.action == "reopen":
        card, _ = find_ask(args.target)
        append_event(os.path.dirname(card), {"type": "reopen", "id": args.target, "via": args.via})
        await_answer(card, args.via)
    elif args.action == "resolve":
        if not args.rest:
            die("usage: hq ask resolve <ask-id> <do|drop|later [until DATE]|archive> [note…]")
        rest, until = args.rest[1:], args.until
        if args.rest[0] == "later" and rest[:1] == ["until"]:
            if len(rest) < 2:
                die("usage: hq ask resolve <ask-id> later until <date> [note…]")
            until, rest = rest[1], rest[2:]
        resolve_ask(args.target, args.rest[0], args.note or " ".join(rest), via=args.via, until=until)


def cmd_asks(args):
    paths = [find_card(args.task)] if args.task else card_paths()
    out = []
    for p in paths:
        m = parse_card(p)
        for a in read_asks(m["dir"]):
            if args.all or a["state"] == "open":
                a["title"] = m.get("title")
                out.append(a)
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return
    for a in out:
        st = "" if a["state"] == "open" else f"  [{a['state']}{': ' + a['note'] if a.get('note') else ''}]"
        if a["state"] == "open" and snoozed(a):
            st = f"  [later — until {a['snoozed_until'][:16].replace('T', ' ')}{': ' + a['later_note'] if a.get('later_note') else ''}]"
        print(f"{a['id']:<8} {a['text']}{st}")
