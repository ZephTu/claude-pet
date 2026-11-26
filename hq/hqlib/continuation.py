"""`hq continue`: carrying an open task over to a new card."""
import datetime as dt
import json
import os
import re

from .core import atomic_write, card_lock, die, now_iso, OPEN_STATUSES, TODO_RE
from .sessions import load_state, save_state, state_lock
from .cards import append_log, find_card, parse_card, parse_frontmatter, set_fields
from .asks import append_event, read_asks
from .focus import focus_add, load_focus, new_card, save_focus


# ---------------------------------------------------------------- continue
# `hq continue T-072`: a long-running task picks up on a fresh card — same project, category, lead,
# folders and key links; its goal, status, open todos (with their original times) and next
# step — and the old card is closed, its log pointing at the new one. Sessions bound to the old card
# move to the new one and hear about it on their next prompt, and so do the open asks (new ids, so
# an answer reaches the sessions now bound to the new card).
SECTION_WORDS = {
    "goal": ("goal", "目标"),
    "status": ("status", "current state", "当前状态", "状态"),
    "todo": ("todo", "待办"),
}
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
# A month name or its abbreviation as a whole word — "Decide 2 options" or "Junit 5" is not a date.
MON_RE = (r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?"
          r"|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)(?:\.|\b)")


def section_span(lines, kind):
    """(heading index, end index) of a card section by its heading words in either language
    (`## 目标`, `## Status (…)`, `## 当前状态 / Status`), or None. Headings in ``` fences don't count."""
    words = SECTION_WORDS[kind]
    head, fence = None, False
    for i, l in enumerate(lines):
        if re.match(r"^\s*(```|~~~)", l):
            fence = not fence
        elif fence or not l.startswith("## "):
            continue
        elif head is not None:
            return head, i
        else:
            name = re.sub(r"[ \t]*[(（].*$", "", l[3:])
            if any(w.strip().casefold() in words for w in name.split("/")):
                head = i
    return (head, len(lines)) if head is not None else None


def continued_title(title, day=None):
    """The title of a task continued on `day`: a date in it becomes that day, in the same form
    (2026-11-22, 2026/11/22, 2026 Nov 22, Nov 22, 11月22日); a title without one gets
    "（续 11-23）" — " (cont. 11-23)" when it has no CJK."""
    d = day or dt.date.today()
    mon = MONTHS[d.month - 1]
    subs = [
        (r"\b\d{4}-\d\d-\d\d\b", lambda m: d.isoformat()),
        (r"\b\d{4}/\d\d?/\d\d?\b", lambda m: f"{d.year}/{d.month:02d}/{d.day:02d}"),
        (rf"\b\d{{4}} {MON_RE} \d\d?\b", lambda m: f"{d.year} {mon} {d.day}"),
        # A year that was there stays there, as the new one.
        (rf"\b{MON_RE} \d\d?\b(,? )?(\d{{4}}\b)?",
         lambda m: f"{mon} {d.day}" + (f"{m.group(1) or ''}{d.year}" if m.group(2) else (m.group(1) or ""))),
        (r"(\d{4}年)?\d\d?月\d\d?日", lambda m: (f"{d.year}年" if m.group(1) else "") + f"{d.month}月{d.day}日"),
    ]
    for pat, rep in subs:
        new, n = re.subn(pat, rep, title, count=1)
        if n:
            return new
    if re.search(r"[　-鿿＀-￯]", title):
        return f"{title}（续 {d.month:02d}-{d.day:02d}）"
    return f"{title} (cont. {d.month:02d}-{d.day:02d})"


def open_todo_lines(src):
    """The open todos of a card's lines, as written (owner, text, creation time), for a continued
    card. Checklists in Goal / Status (copied with their section) and in ``` fences are not
    todos to carry. An open sub-todo comes with its parent if that comes too, else unindented."""
    skip = set()
    for kind in ("goal", "status"):
        sp = section_span(src, kind)
        if sp:
            skip.update(range(sp[0], sp[1]))
    out, stack, fence = [], [], False      # stack: (indent, carried, indent written)
    for i, l in enumerate(src):
        if re.match(r"^\s*(```|~~~)", l):
            fence = not fence
            continue
        t = TODO_RE.match(l)
        if fence or i in skip or not t:
            continue
        n = len(t.group(1).expandtabs(4))
        while stack and stack[-1][0] >= n:
            stack.pop()
        parent = stack[-1] if stack else None
        carry = t.group(2) == " " and t.group(3).strip() not in ("...", "…", "")
        at = parent[2] + (n - parent[0]) if carry and parent and parent[1] else 0
        if carry:
            out.append(" " * at + l.lstrip())
        stack.append((n, carry, at))
    return out


def continue_task(card, title=None):
    """Continues the task on a new card; returns {"from", "to", "path", "title", "todos", "sessions", "asks"}."""
    old = parse_card(card)
    if old.get("status") not in OPEN_STATUSES:
        die(f"{old['id']} is {old.get('status')}: only an open task can be continued")
    title = (title or "").strip() or continued_title(old.get("title") or old["id"])
    workdirs = old.get("workdirs") if isinstance(old.get("workdirs"), list) else []
    tid, path = new_card(title, category=old.get("category") or None, project=old.get("project") or None,
                         lead=old.get("lead") if old.get("lead") not in (None, "", "-") else None,
                         workdirs=workdirs, focus=False)
    src = old["body"].split("\n")
    with card_lock(path):
        text = open(path, encoding="utf-8").read()
        meta, body = parse_frontmatter(text)
        head = text[:len(text) - len(body)]
        lines = body.split("\n")
        # Goal and status: the old card's text in place of the template's placeholder.
        for kind in ("goal", "status"):
            s, d = section_span(src, kind), section_span(lines, kind)
            if s and d:
                content = src[s[0] + 1:s[1]]
                while content and not content[-1].strip():
                    content.pop()
                lines[d[0] + 1:d[1]] = content + [""]
        todos = open_todo_lines(src)
        if todos:
            d = section_span(lines, "todo")
            if d:
                j = d[0] + 1
                while j < d[1] and lines[j].strip().startswith("<!--"):
                    j += 1
                lines[j:j] = todos
            else:
                lines += ["", "## Todo"] + todos
        atomic_write(path, head + "\n".join(lines))
        fields = {}
        refs = old.get("refs") if isinstance(old.get("refs"), list) else []
        if refs:
            fields["refs"] = list(refs)
        if old.get("next"):
            fields["next"] = old["next"]
        for k in ("intake", "intake_key", "intake_done"):    # still the same piece of work that came in
            if old.get(k):
                fields[k] = old[k]
        if old.get("status") != "active":
            fields["status"] = old["status"]         # blocked / waiting-on-me carries on too
        if str(old.get("waiting_on_me") or "").strip():
            fields["waiting_on_me"] = old["waiting_on_me"]
        if fields:
            set_fields(path, fields)
    append_log(path, f"continued from {old['id']} ({old.get('title') or ''})")
    # Open asks move to the new card, so an answer reaches the sessions bound there and the ask
    # goes on with the work. Each gets the new card's next id; the old one is marked moved.
    asks = move_open_asks(old, path)
    # The old card: closed, pointing at the new one.
    append_log(card, f"continued in {tid} ({title})", touch=False)
    set_fields(card, {"status": "done", "next": f"continued in {tid}", "closing": None})
    # Focus: the new card takes the old one's place.
    f = load_focus()
    if old["id"] in f:
        save_focus([tid if i == old["id"] else i for i in f])
    else:
        focus_add([tid])
    # Live sessions on the old card move to the new one; their next prompt tells them.
    moved = []
    with state_lock():
        state = load_state()
        for sid, s in state.items():
            if isinstance(s, dict) and s.get("task") == old["id"]:
                s.update(task=tid, bound_at=now_iso(), announced=False, continued_from=old["id"])
                moved.append(sid)
        if moved:
            save_state(state)
    if moved:
        sessions = parse_card(path).get("sessions") or []
        set_fields(path, {"sessions": list(sessions) + [s[:8] for s in moved if s[:8] not in sessions]})
    return {"from": old["id"], "to": tid, "path": path, "title": title, "todos": len(todos),
            "sessions": moved, "asks": asks}


def move_open_asks(old, path):
    """Moves the old card's open asks (snoozed ones too) to the card at `path`; returns
    [{"from": old id, "to": new id}, …]."""
    # The old card's lock too: a Stop hook asking or answering there mid-move would leave an ask
    # open on a card about to close, or move one already answered.
    with card_lock(os.path.join(old["dir"], "TASK.md")), card_lock(path):
        return _move_open_asks(old, path)


def _move_open_asks(old, path):
    new = parse_card(path)
    out = []
    for a in read_asks(old["dir"]):
        if a.get("state") != "open":
            continue
        have = read_asks(new["dir"])
        nid = f"{new['id']}.{max([int(x['id'].rsplit('.', 1)[1]) for x in have] or [0]) + 1}"
        ev = {"type": "open", "id": nid, "task": new["id"], "moved_from": a["id"]}
        for k in ("text", "session", "context", "ts"):
            if a.get(k) is not None:
                ev[k] = a[k]
        append_event(new["dir"], ev)
        if a.get("snoozed_until"):
            append_event(new["dir"], {"type": "snooze", "id": nid, "until": a["snoozed_until"], "via": "continue",
                                      **({"note": a["later_note"]} if a.get("later_note") else {})})
        append_event(old["dir"], {"type": "move", "id": a["id"], "to": nid})
        out.append({"from": a["id"], "to": nid})
    return out


def cmd_continue(args):
    r = continue_task(find_card(args.task), args.title)
    if args.json:
        print(json.dumps(r, ensure_ascii=False))
        return
    print(f"{r['from']} → {r['to']}: {r['title']}")
    print(r["path"])
    print(f"{r['todos']} open todo(s) carried over; {r['from']} is done.")
    if r["sessions"]:
        print(f"{len(r['sessions'])} session(s) moved to {r['to']}: {', '.join(s[:8] for s in r['sessions'])}")
    if r["asks"]:
        print(f"{len(r['asks'])} open ask(s) moved: " + ", ".join(f"{a['from']} → {a['to']}" for a in r["asks"]))
