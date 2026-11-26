"""The secretary and its daily and weekly reports."""
import datetime as dt
import hashlib
import json
import os
import re

from .core import (
    atomic_write, clip, die, HOME_DIR, hq_root, iso, load_json, local_dt, now_iso, one_line, OPEN_STATUSES,
    snoozed,
)
from .sessions import load_state
from .cards import (
    card_paths, card_state_lines, find_card, LOG_HEADING_RE, LOG_LINE_RE, parse_card, root_config_path,
    secretary_task_id, todo_plain,
)
from .history import read_history, TICK_RE
from .projects import load_projects, project_info
from .asks import read_asks
from .focus import new_card
from .autoclose import pr_states
from .garden import garden_text, gather_garden


# ---------------------------------------------------------------- secretary
SECRETARY_FILES = ("profile.md", "people.md", "playbooks.md")
# Made by init and by `hq report` when missing, but not needed to be set up: a secretary set up
# before reports existed is still ready.
SECRETARY_EXTRA_FILES = ("reports.md",)
# sha256 of agent definitions earlier versions of hq wrote. One still exactly that was never edited
# by the user, so init (and the board, before a run) replaces it with the current template.
SECRETARY_AGENT_OLD = {
    "181d12d48a0806ae0fb0dc516c9c802bb82d0795e45c50e1eb54eac812f42a7f",
    "8168fa81c75679b9d001019b67b36537324724597067d5ca991e16c86f1a8358",
    "fb7a51439cc544950e65d74564fcc51f7fc48fed40857cbdb7565dc73c84f8e9",
    "99304f170efe63aa90ea716ec6fb015fc00b570d7533ec003a40665ee4c0549d",
    "7d51000eeb7e6a3ed3b36d56781080e82a020ed0e0fd66d56c440133d8fc2842",
    "a14b021ecad90565a410302362f48252f5e3d28bd9910bdd95048afdf893080c",
}
SECRETARY_TITLE = {"zh": "秘书", "en": "Secretary"}
SECRETARY_GOAL = {
    "zh": "秘书自己的卡片：秘书的 hq-update 写在这里（它在替你盯什么），它的建议作为这张卡的 ask 出现在 Needs you。"
          "秘书的定义在 `.claude/agents/secretary.md`，记忆在 `secretary/`。",
    "en": "The secretary's own card: its hq-update blocks land here (what it is keeping an eye on), and its "
          "proposals show up in Needs you as this card's asks. Its definition is `.claude/agents/secretary.md`, "
          "its memory `secretary/`.",
}


def template_dir():
    """The templates next to hqlib/ (a checkout, or the installed copy), else the installed ones."""
    here = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "template")
    return here if os.path.isdir(here) else os.path.join(HOME_DIR, "template")


def agent_stale(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest() in SECRETARY_AGENT_OLD
    except OSError:
        return False


def secretary_info():
    root = hq_root()
    agent = os.path.join(root, ".claude", "agents", "secretary.md")
    memory = os.path.join(root, "secretary")
    files = {f: os.path.isfile(os.path.join(memory, f)) for f in SECRETARY_FILES + SECRETARY_EXTRA_FILES}
    tid = secretary_task_id()
    # The sessions bound to its card: the board checks its session is among them before a run.
    sessions = sorted(s for s, e in load_state().items() if tid and isinstance(e, dict) and e.get("task") == tid)
    card = find_card(tid) if tid else None
    # What it is keeping an eye on for the user: its card's state lines, which its hq-update writes.
    state = card_state_lines(parse_card(card)["body"]) if card else []
    return {"root": root, "task": tid, "card": card, "sessions": sessions,
            "state": [one_line(l, 200) for l in state[:6]],
            "agent": agent, "agentExists": os.path.isfile(agent), "agentStale": agent_stale(agent),
            "memory": memory, "files": files,
            # The newest reports, for the secretary's window (`hq report list` has them all).
            "reports": [{k: r[k] for k in ("name", "path", "date", "kind")} for r in report_list()[:4]],
            "ready": bool(tid) and os.path.isfile(agent) and all(files[f] for f in SECRETARY_FILES)}


def secretary_init(lang):
    """Scaffold what is missing (the agent definition, the memory files, the secretary's own card)
    and never overwrite what is there: those files are the user's, and the secretary's memory. The one
    exception is an agent definition an older hq wrote and nobody changed: it gets the current one."""
    lang = lang if lang in SECRETARY_TITLE else "en"
    tpl = template_dir()
    info = secretary_info()
    made = []
    if not info["agentExists"] or info["agentStale"]:
        os.makedirs(os.path.dirname(info["agent"]), exist_ok=True)
        atomic_write(info["agent"], open(os.path.join(tpl, "agents", "secretary.md"), encoding="utf-8").read())
        made.append(info["agent"])
    os.makedirs(info["memory"], exist_ok=True)
    for f, exists in info["files"].items():
        if exists:
            continue
        if f == "reports.md":
            made.append(ensure_report_format())    # in the language the memory is in
            continue
        src = os.path.join(tpl, "secretary", lang, f)
        if not os.path.isfile(src):
            src = os.path.join(tpl, "secretary", "en", f)
        atomic_write(os.path.join(info["memory"], f), open(src, encoding="utf-8").read())
        made.append(os.path.join(info["memory"], f))
    if not info["task"]:
        # Its asks are what Needs you shows; the card itself stays off Focus.
        tid, card = new_card(SECRETARY_TITLE[lang], slug="secretary", lead="secretary", focus=False)
        text = open(card, encoding="utf-8").read()
        # The goal's placeholder, whatever its wording (the root may have its own TASK.md template).
        text = re.sub(r"(?m)^(##[ \t]*(?:Goal|目标)[^\n]*\n)<[^\n]*>$", lambda m: m.group(1) + SECRETARY_GOAL[lang],
                      text, count=1)
        atomic_write(card, text)
        cfg = load_json(root_config_path(), {})
        if not isinstance(cfg, dict):
            cfg = {}
        cfg["secretary"] = {"task": tid}
        atomic_write(root_config_path(), json.dumps(cfg, ensure_ascii=False, indent=1) + "\n")
        made.append(card)
    return dict(secretary_info(), made=made)


def cmd_secretary(args):
    info = secretary_init(args.lang) if args.action == "init" else secretary_info()
    if args.json:
        print(json.dumps(info, ensure_ascii=False, indent=1))
        return
    print(f"task:   {info['task'] or '(none: run hq secretary init)'}")
    print(f"agent:  {info['agent']}{'' if info['agentExists'] else '  (missing)'}")
    for f, ok in info["files"].items():
        print(f"memory: {os.path.join(info['memory'], f)}{'' if ok else '  (missing)'}")
    for m in info.get("made", []):
        print(f"created {m}")


# ---------------------------------------------------------------- reports
# The secretary's daily and weekly reports. `hq report` gathers what happened on the board in a
# window, by project — the facts; the secretary writes the prose, in the format
# `secretary/reports.md` sets, into `secretary/reports/`. `hq report keep` snapshots what it wrote,
# so the next `hq report` can show the user's edits to it: what the secretary learns its format from.
REPORT_KINDS = ("daily", "weekly")
REPORT_NAME_RE = re.compile(r"^(\d{4}-\d\d-\d\d)-(daily|weekly)\.md$")
GH_PR_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")
OWED_AFTER_DAYS = 2          # an @me todo or an ask open longer than this is "owed"
EDITS_LOOKBACK = 5           # how many recent reports are checked for the user's edits


def reports_dir():
    return os.path.join(hq_root(), "secretary", "reports")


def reports_index_path():
    return os.path.join(reports_dir(), ".reports.json")


def reports_pending_path():
    return os.path.join(reports_dir(), ".pending.json")


def load_reports_index():
    idx = load_json(reports_index_path(), {})
    return idx if isinstance(idx, dict) else {}


def report_lang():
    """The memory's language: zh when profile.md's headings are Chinese (the Chinese template's)."""
    try:
        text = open(os.path.join(hq_root(), "secretary", "profile.md"), encoding="utf-8").read()
    except OSError:
        return "en"
    return "zh" if re.search(r"^#+.*[\u4e00-\u9fff]", text, re.M) else "en"


def ensure_report_format():
    """`secretary/reports.md`, the report format, made from the template when missing (a secretary
    set up before reports existed). Never overwritten: it is the user's, and what the secretary learned."""
    path = os.path.join(hq_root(), "secretary", "reports.md")
    if not os.path.exists(path):
        lang = report_lang()
        src = os.path.join(template_dir(), "secretary", lang, "reports.md")
        if not os.path.isfile(src):
            src = os.path.join(template_dir(), "secretary", "en", "reports.md")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        atomic_write(path, open(src, encoding="utf-8").read())
    return path


def report_window(kind, since, now, name=None):
    """(start, end, prev) as naive local datetimes, prev the index entry the window starts at.
    Weekly: this week from Monday 00:00. Daily: from where the last kept report's facts ended (at
    most 7 days back; not `name` itself, a report being written again), else from today 00:00."""
    if since:
        s = local_dt(since)
        if not s:
            die(f"--since: not a date or time: {since}")
        return s.replace(tzinfo=None), now, None
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if kind == "weekly":
        return midnight - dt.timedelta(days=now.weekday()), now, None
    # `to`: the end of the facts it was written from; reports kept before that was recorded, `kept`.
    ends = [(naive(e.get("to") or e.get("kept")), e) for n, e in load_reports_index().items()
            if isinstance(e, dict) and n != name]
    ends = [(t, e) for t, e in ends if t and t <= now]
    if ends:
        last, e = max(ends, key=lambda x: x[0])
        if now - last <= dt.timedelta(days=7):
            return last, now, e
    return midnight, now, None


def naive(ts):
    t = local_dt(ts)
    return t.replace(tzinfo=None) if t else None


def log_entries(body):
    """Every Log line of a card: (time, text)."""
    m = LOG_HEADING_RE.search(body + "\n")
    out = []
    for line in (m.group(1) if m else "").splitlines():
        x = LOG_LINE_RE.match(line.strip())
        if x:
            t = naive(x.group(1))
            if t:
                out.append((t, x.group(2).strip()))
    return out


def history_log_entries(card, items=None):
    """The Log lines of a card's HISTORY.md, as log_entries gives them: ticks and older entries.
    items: that Log, when the caller has read HISTORY.md already."""
    out = []
    for item in read_history(card)["Log"] if items is None else items:
        x = LOG_LINE_RE.match(item.split("\n", 1)[0].strip())
        t = naive(x.group(1)) if x else None
        if t:
            out.append((t, x.group(2).strip()))
    return out
CHANGED_TICK_RE = re.compile(r"^todo #\d+ → changed \(")


def todo_closed_times(meta, hist_log=None):
    """When closed todos were closed: plain text → the times of its done or drop ticks still
    standing, oldest first, from the Log of the card and of HISTORY.md (the card's lines carry no
    such time). A reopen takes back the latest one; a todo closed by hand on the card has none.
    Several todos with one text each take one of that text's times (see closed_time)."""
    out = {}
    for t, text in sorted(log_entries(meta["body"]) + history_log_entries(meta["path"], hist_log),
                          key=lambda e: e[0]):
        tick = TICK_RE.match(text)
        if tick:
            times = out.setdefault(todo_plain(tick.group(3)), [])
            if tick.group(1) == "open":
                times[-1:] = []
            else:
                times.append(t.astimezone().isoformat(timespec="seconds"))   # with its offset: a phone may be elsewhere
    return out


def closed_time(times, text):
    """The closing time of a todo with this text, newest first: the board asks for the card's own
    todos, last first, before HISTORY.md's (closed earliest). None once that text's times are used
    up (more todos of that text than ticks: the rest were closed by hand)."""
    left = times.get(todo_plain(text))
    return left.pop() if left else None


def task_activity(meta, start, end, reported_closed=()):
    """What happened on one card in [start, end]. `closed` holds a date only: a card closed on the
    window's first day counts unless the report the window starts at already said so."""
    inw = lambda t: t is not None and start <= t <= end
    notes, done, dropped = [], [], []
    for t, text in sorted(log_entries(meta["body"]) + history_log_entries(meta["path"]), key=lambda e: e[0]):
        if not inw(t):
            continue
        tick = TICK_RE.match(text)
        if CHANGED_TICK_RE.match(text):
            continue                    # a todo reworded: neither news nor a closing
        if tick:
            (done if tick.group(1) == "done" else dropped if tick.group(1) == "drop" else []).append(
                {"at": iso(t), "text": todo_plain(tick.group(3)), "via": tick.group(2)})
        else:
            notes.append({"at": iso(t), "text": text})
    added = [{"at": iso(naive(x["created"])), "owner": x["owner"], "text": x["text"]}
             for x in meta["todos"] if inw(naive(x["created"]))]
    asks = read_asks(meta["dir"])
    answered = [{"id": a["id"], "text": a.get("text", ""), "answer": a["state"], "note": a.get("note") or "",
                 "at": iso(naive(a.get("resolved_at")))}
                for a in asks if a["state"] != "open" and inw(naive(a.get("resolved_at")))]
    asked = [{"id": a["id"], "text": a.get("text", ""), "at": iso(naive(a.get("ts")))}
             for a in asks if inw(naive(a.get("ts"))) and a["state"] != "moved"]   # counted where it went
    norm = lambda t: " ".join(str(t).split())
    settled = {norm(x["text"]) for x in done + dropped}
    added = [x for x in added if norm(x["text"]) not in settled]
    answered_ids = {a["id"] for a in answered}
    asked = [a for a in asked if a["id"] not in answered_ids]
    day, first = str(meta.get("closed") or ""), start.date().isoformat()
    closed = meta.get("status") in ("done", "abandoned") and (
        day > first or (day == first and meta.get("id") not in reported_closed))
    return {"notes": notes, "done": done, "dropped": dropped, "added": added, "answered": answered,
            "asked": asked, "closed": closed, "asks": asks}


def report_edits():
    """The user's edits to recent reports since the secretary wrote (or last saw) them: unified
    diffs against the snapshot `hq report keep` took."""
    import difflib
    idx, out = load_reports_index(), []
    for name in sorted(idx, reverse=True)[:EDITS_LOOKBACK]:
        cur, base = os.path.join(reports_dir(), name), os.path.join(reports_dir(), ".drafts", name)
        try:
            a, b = open(base, encoding="utf-8").read(), open(cur, encoding="utf-8").read()
        except OSError:
            continue
        if a != b:
            diff = "".join(difflib.unified_diff(a.splitlines(True), b.splitlines(True),
                                                f"{name} (as written)", f"{name} (as edited)", n=1))
            out.append({"report": name, "path": cur, "diff": diff})
    return out


def gather_report(kind, since=None, gh=True, now=None):
    now = (now or dt.datetime.now()).replace(microsecond=0)
    name = f"{now.date().isoformat()}-{kind}.md"
    start, end, prev = report_window(kind, since, now, name)
    reported_closed = set(prev.get("closed") or []) if prev else set()
    sec = secretary_task_id()
    metas = [parse_card(p) for p in card_paths()]
    metas = [m for m in metas if m.get("id") != sec]
    names = [p["name"] for p in load_projects()]
    tasks, owed = [], []
    for m in metas:
        act = task_activity(m, start, end, reported_closed)
        is_open = m.get("status") in OPEN_STATUSES
        # Claude's own new todos are its working plan, not news (the text leaves them out too).
        moved = any(act[k] for k in ("notes", "done", "dropped", "answered", "asked")) or act["closed"] \
            or any(x["owner"] != "claude" for x in act["added"])
        refs = m.get("refs") if isinstance(m.get("refs"), list) else []
        prs = list(dict.fromkeys(u for r in refs for u in GH_PR_RE.findall(str(r))))
        # A card closed in the last week may still have a PR merging now.
        recent = str(m.get("closed") or "") >= (start - dt.timedelta(days=7)).date().isoformat()
        if not (moved or is_open or (prs and recent)):
            continue
        tasks.append({"id": m.get("id"), "title": m.get("title", ""), "project": m.get("project") or "",
                      "status": m.get("status"), "open": is_open, "updated": m.get("updated", ""), "next": m.get("next", ""),
                      "state": card_state_lines(m["body"])[:4], "moved": moved, "prs": prs,
                      **{k: v for k, v in act.items() if k != "asks"}})
        if is_open:
            for x in m["todos"]:
                c = naive(x["created"])
                if x["state"] == "open" and x["owner"] == "me" and c and (now - c).days >= OWED_AFTER_DAYS:
                    owed.append({"task": m.get("id"), "kind": "todo", "text": x["text"], "since": iso(c),
                                 "days": (now - c).days})
            for a in act["asks"]:
                c = naive(a.get("ts"))
                if a["state"] == "open" and c and (now - c).days >= OWED_AFTER_DAYS and not snoozed(a):
                    owed.append({"task": m.get("id"), "kind": "ask", "id": a["id"], "text": a.get("text", ""),
                                 "since": iso(c), "days": (now - c).days})
    owed.sort(key=lambda o: -o["days"])
    # PRs of the cards above: a PR merged on a quiet or recently closed card is still news.
    states = pr_states(sorted({u for t in tasks for u in t["prs"]})) if gh else {}
    for t in tasks:
        t["prs"] = [dict(url=u, **{k: states[u].get(k) for k in ("number", "title", "state", "mergedAt", "isDraft")},
                         mergedInWindow=bool(states[u].get("mergedAt")) and start <= naive(states[u]["mergedAt"]) <= end)
                    if u in states else {"url": u, "state": None} for u in t["prs"]]
        if any(p.get("mergedInWindow") for p in t["prs"]) and not t["moved"]:
            t["moved"] = True
    tasks = [t for t in tasks if t.pop("open") or t["moved"]]
    projects = []
    for pname in names + sorted({t["project"] for t in tasks} - set(names)):
        mine = [t for t in tasks if t["project"] == pname]
        if not mine:
            continue
        info = project_info({"name": pname, "paths": []}) if pname else {}
        projects.append({"name": pname, "title": info.get("title", ""), "kind": info.get("kind", ""),
                         "due": info.get("due", ""), "goal": info.get("goal", ""),
                         "moved": [t for t in mine if t["moved"]],
                         "quiet": [{"id": t["id"], "title": t["title"], "status": t["status"], "updated": t["updated"]}
                                   for t in mine if not t["moved"]]})
    os.makedirs(reports_dir(), exist_ok=True)
    # What `hq report keep` records for this report: where its facts end (the next daily report
    # starts there, so what happens while it is written isn't lost) and the cards it saw closed.
    closed_ids = sorted({t["id"] for t in tasks if t.get("closed")} | (reported_closed if start.date() == end.date() else set()))
    pending = load_json(reports_pending_path(), {})
    pending = pending if isinstance(pending, dict) else {}
    pending[name] = {"from": iso(start), "to": iso(end), "closed": closed_ids}
    atomic_write(reports_pending_path(), json.dumps(pending, ensure_ascii=False, indent=1) + "\n")
    path = os.path.join(reports_dir(), name)
    # Today's report may be written again (Write one now, then the evening run): it's then among
    # the edits checked, and the secretary must keep what the user changed in it.
    r = {"kind": kind, "from": iso(start), "to": iso(end), "lang": report_lang(),
         "file": path, "exists": os.path.isfile(path), "format": ensure_report_format(),
         "projects": projects, "owed": owed, "edits": report_edits(), "gh": bool(gh and states)}
    if kind == "weekly":
        # The weekly look over the board (`hq garden`): proposals for the reply, not the report.
        try:
            r["garden"] = gather_garden(now.astimezone())
        except Exception as e:  # noqa: BLE001 — the report matters more than the tidying
            r["garden"] = {"error": f"{type(e).__name__}: {e}", "findings": [], "duplicates": []}
    return r


def capped(items, what, line, n=6):
    """The newest n items as lines, with a note of how many more there are."""
    more = [f"  ({len(items) - n} more {what}: hq report --json)"] if len(items) > n else []
    return more + [line(x) for x in items[-n:]]


def report_text(r):
    hm = lambda s: s[5:16].replace("T", " ") if s else "?"
    out = [f"# {r['kind']} report data · {r['from'][:16].replace('T', ' ')} → {r['to'][:16].replace('T', ' ')}",
           f"write it to: {r['file']}",
           f"then run:    hq report keep {os.path.basename(r['file'])}",
           f"format:      {r['format']} (read it first; its rules win)", ""]
    if r.get("exists"):
        out[2:2] = ["NOTE: this file exists already (written earlier today). Read it and rewrite it from the facts",
                    "below, keeping what the user changed in it (see the edits at the end)."]
    if not r["projects"]:
        out += ["(nothing on the board)", ""]
    for p in r["projects"]:
        head = p["name"] or "(no project)"
        bits = [x for x in (p["kind"], f"due {p['due']}" if p["due"] else "") if x]
        out.append(f"## {head}{' — ' + p['title'] if p['title'] else ''}{' [' + ' · '.join(bits) + ']' if bits else ''}")
        if p["goal"]:
            out.append(f"goal: {clip(p['goal'], 200)}")
        for t in p["moved"]:
            out.append(f"### {t['id']} {t['title']} — {t['status']}{' (closed in window)' if t['closed'] else ''}")
            for s in t["state"]:
                out.append(f"  state: {clip(s, 200)}")
            if t["next"]:
                out.append(f"  next: {clip(t['next'], 200)}")
            out += capped(t["notes"], "log lines", lambda n: f"  log {hm(n['at'])}: {clip(n['text'], 200)}")
            out += capped(t["done"], "done", lambda n: f"  done {hm(n['at'])}: {clip(n['text'], 120)}")
            if t["dropped"]:
                out.append(f"  dropped {len(t['dropped'])} todo(s)")
            # New todos the user or a colleague owns; Claude's own are its working plan, not news.
            mine = [n for n in t["added"] if n["owner"] != "claude"]
            out += capped(mine, "new todos", lambda n: f"  new todo {hm(n['at'])}: "
                          f"{'@' + n['owner'] + ' ' if n['owner'] else ''}{clip(n['text'], 120)}")
            out += capped(t["answered"], "answers", lambda a: f"  answered {hm(a['at'])} {a['id']} \"{clip(a['text'], 80)}\""
                          f" → {a['answer']}{': ' + clip(a['note'], 100) if a['note'] else ''}")
            out += capped(t["asked"], "asks", lambda a: f"  asked {hm(a['at'])} {a['id']}: {clip(a['text'], 100)}")
            for pr in t["prs"]:
                if pr.get("state") == "MERGED" and pr.get("mergedInWindow"):
                    out.append(f"  PR merged {hm(iso(naive(pr['mergedAt'])))}: #{pr['number']} {clip(pr['title'], 100)}")
                elif pr.get("state") == "OPEN":
                    out.append(f"  PR open{' (draft)' if pr.get('isDraft') else ''}: #{pr['number']} {clip(pr['title'], 100)}")
        if p["quiet"]:
            out.append("no movement: " + ", ".join(f"{q['id']} {clip(q['title'], 40)} ({q['status']}, updated {q['updated']})"
                                                for q in p["quiet"]))
        out.append("")
    out.append("## Owed: waiting on the user for %d days or more" % OWED_AFTER_DAYS)
    out += [f"- {o['task']} {'ask ' + o['id'] if o['kind'] == 'ask' else '@me todo'}: {clip(o['text'], 140)} — {o['days']}d"
            for o in r["owed"]] or ["(nothing)"]
    out.append("")
    if r["edits"]:
        out.append("## The user's edits to earlier reports (learn the format from these)")
        for e in r["edits"]:
            out += ["```diff", e["diff"].rstrip("\n"), "```"]
        out.append("")
    if r.get("garden"):
        out.append("## Tidying the board (weekly; hq garden) — not for the report file")
        out.append("Propose the cleanups worth doing as asks in your reply's hq-asks block "
                   "(Tidying the board in your instructions).")
        out.append(f"(hq garden failed: {r['garden']['error']})" if r["garden"].get("error") else garden_text(r["garden"]))
        out.append("")
    if not r["gh"]:
        out.append("(PR states unknown: gh is not available or not logged in)")
    return "\n".join(out).rstrip("\n")


def report_list():
    idx, out = load_reports_index(), []
    for name in sorted(idx, reverse=True):
        e = idx[name] if isinstance(idx[name], dict) else {}
        path = os.path.join(reports_dir(), name)
        if not os.path.isfile(path):
            continue
        m = REPORT_NAME_RE.match(name)
        out.append({"name": name, "path": path, "date": m.group(1) if m else "", "kind": m.group(2) if m else "",
                    "kept": e.get("kept"), "from": e.get("from"), "to": e.get("to")})
    return out


def report_keep(name):
    """Snapshot a report the secretary just wrote; earlier reports' edits are now seen (the report
    that follows them has dealt with them), so their snapshots move up to what the user left."""
    name = os.path.basename(name)
    if not REPORT_NAME_RE.match(name):
        die(f"not a report file name (YYYY-MM-DD-daily.md or -weekly.md): {name}")
    path = os.path.join(reports_dir(), name)
    if not os.path.isfile(path):
        die(f"no report {path}: write it first")
    drafts = os.path.join(reports_dir(), ".drafts")
    os.makedirs(drafts, exist_ok=True)
    idx = load_reports_index()
    for other in list(idx):
        p = os.path.join(reports_dir(), other)
        if other != name and os.path.isfile(p):
            atomic_write(os.path.join(drafts, other), open(p, encoding="utf-8").read())
    atomic_write(os.path.join(drafts, name), open(path, encoding="utf-8").read())
    pending = load_json(reports_pending_path(), {})
    pending = pending if isinstance(pending, dict) else {}
    got = pending.pop(name, None)
    idx[name] = {"kept": now_iso(), **(got if isinstance(got, dict) else {})}
    atomic_write(reports_index_path(), json.dumps(idx, ensure_ascii=False, indent=1) + "\n")
    atomic_write(reports_pending_path(), json.dumps(pending, ensure_ascii=False, indent=1) + "\n")
    return path


def cmd_report(args):
    if args.action == "keep":
        if not args.name:
            die("usage: hq report keep YYYY-MM-DD-daily.md")
        print(report_keep(args.name))
        return
    if args.action == "list":
        rows = report_list()
        if args.json:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
        else:
            for x in rows:
                print(f"{x['date']}  {x['kind']:<6}  {x['path']}")
        return
    kind = args.action
    if kind in (None, "auto"):
        kind = "weekly" if dt.date.today().weekday() == 4 else "daily"   # Friday: the week's report
    r = gather_report(kind, since=args.since, gh=not args.no_gh)
    print(json.dumps(r, ensure_ascii=False, indent=1) if args.json else report_text(r))
