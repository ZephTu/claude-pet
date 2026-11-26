"""The inbox: quick notes, and sorting them into the board with claude."""
import collections
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

from .core import (
    atomic_write, card_lock, die, find_claude, hq_root, is_placeholder, load_json, LOCK_DIR, now_iso,
    ok_workdir, one_line, OPEN_STATUSES, STATUSES, today, TODO_RE, TODO_TIME_RE, ts_seconds,
)
from .cards import (
    add_todo, append_log, card_paths, card_state_lines, card_todos, LOG_ENTRY_RE, parse_card,
    root_config_path, secretary_task_id, set_fields, STATUS_HEADING_RE, todo_owner, todo_plain,
)
from .refs import merge_refs, ref_key, REF_URL_RE, URL_TAIL
from .history import history_drop_links, HISTORY_FILE, log_tick, read_history
from .projects import load_projects, project_info
from .asks import settle_status
from .focus import load_focus, new_card, save_focus


# ---------------------------------------------------------------- inbox: quick notes, sorted by a cheap model
# <root>/inbox.json: {"items": [...]}, one item per note jotted from the pet's shortcut or the board:
#   {id: "N-007", at, text, images: [paths], via, state: sorting|sorted|unsorted|dropped,
#    dest: where it went (sorted) or the best guess (unsorted), alts: other guesses,
#    undo: what applying `dest` wrote (so a move takes exactly that back out), reason, confidence, by}
# A dest: {kind: task|todo|note|update|me, task, owner, text, title, project, workdir, refs,
#          next, state, status, done}.
#   task    a new task card: `title`, `text` its goal, project / workdir / refs
#   todo    a todo on an open task: `owner` (me, claude or a name) and `text`
#   note    information for an open task: `text` goes in its Log, links in its refs
#   update  how an open task stands now: `text` goes in its Log as for a note, and the card's
#           `next`, `state` (its status section, lines joined by \n) and `status` are replaced;
#           `done` lists open todos it ticks ("@owner text", as the card has them). A move puts
#           back what was there before, as far as nothing else changed it since.
#   me      an @me todo that belongs to no task: it goes on the secretary's card
INBOX_KINDS = ("task", "todo", "note", "update", "me")
INBOX_ASK_STATUSES = ("done", "abandoned")    # an update closing its task only ever waits for a click
INBOX_MAX_ALTS = 6             # other places kept on a note, each a button (an update's come first)
INBOX_CONFIDENT = 0.7          # below this the guess is shown, not applied
INBOX_KEEP_DAYS = 30           # sorted and dropped notes are kept this long (for moving them)
INBOX_SORT_TIMEOUT = 120
INBOX_RECENT_HOURS = 48        # how far back the board's "recently sorted" list goes
INBOX_DEFAULT_MODEL = "haiku"
INBOX_CLOSED_DAYS = 14         # a note (not a todo) may still go to a task closed this recently


class InboxError(Exception):
    pass


def inbox_path():
    return os.path.join(hq_root(), "inbox.json")


@contextlib.contextmanager
def inbox_lock():
    os.makedirs(LOCK_DIR, exist_ok=True)
    with open(os.path.join(LOCK_DIR, "inbox.lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def load_inbox():
    d = load_json(inbox_path(), {})
    items = d.get("items") if isinstance(d, dict) else None
    return [x for x in items if isinstance(x, dict) and isinstance(x.get("id"), str)] if isinstance(items, list) else []


def save_inbox(items, last=None):
    """`last`: the highest number handed out, kept so numbers go on counting past pruned notes."""
    if last is None:
        d = load_json(inbox_path(), {})
        last = d.get("last", 0) if isinstance(d, dict) and isinstance(d.get("last"), int) else 0
    cutoff = time.time() - INBOX_KEEP_DAYS * 86400
    # By the last change, not by when it was jotted: an old note filed or dropped today must stay
    # long enough to be moved or restored.
    # A scanned message the sorter would skip waits unsorted, but ages out like a dropped one.
    keep = [x for x in items if (x.get("state") in ("unsorted", "sorting") and not x.get("skip")) or
            max(ts_seconds(x.get(k)) or 0 for k in ("at", "sorted_at", "moved_at")) >= cutoff]
    atomic_write(inbox_path(), json.dumps({"last": last, "items": keep}, ensure_ascii=False, indent=1) + "\n")


def inbox_state(x):
    """An item's state as shown: a sort that never finished (the pet quit mid-run) is unsorted."""
    st = x.get("state")
    if st == "sorting" and time.time() - (ts_seconds(x.get("sort_started") or x.get("at")) or 0) > INBOX_SORT_TIMEOUT + 60:
        return "unsorted"
    return st


def inbox_item(items, nid):
    nid = nid.upper() if re.match(r"^n-\d+$", nid, re.I) else nid
    x = next((x for x in items if x["id"] == nid), None)
    if not x:
        die(f"no note {nid} in the inbox")
    return x


def inbox_update(nid, fn):
    """Read-change-write one item under the inbox lock; returns the item as saved."""
    with inbox_lock():
        items = load_inbox()
        x = inbox_item(items, nid)
        fn(x)
        save_inbox(items)
        return dict(x, state=inbox_state(x))


def inbox_add(text, images=(), via="cli", extra=None):
    text = str(text or "").strip()
    images = [os.path.abspath(os.path.expanduser(i)) for i in images if i]
    if not text and not images:
        die("nothing to note")
    for i in images:
        if not os.path.isfile(i):
            die(f"no such image: {i}")
    with inbox_lock():
        items = load_inbox()
        nums = [int(m.group(1)) for x in items for m in [re.match(r"N-(\d+)$", x["id"])] if m]
        d = load_json(inbox_path(), {})
        last = d.get("last", 0) if isinstance(d, dict) and isinstance(d.get("last"), int) else 0
        n = max(nums + [last]) + 1
        x = {"id": f"N-{n:03d}", "at": now_iso(), "text": text, "images": images, "via": via, "state": "unsorted"}
        x.update(extra or {})
        items.append(x)
        save_inbox(items, last=n)
    return x


def recently_closed(m):
    """Closed (done / abandoned) within INBOX_CLOSED_DAYS: a note about it still belongs there."""
    if m.get("status") in OPEN_STATUSES:
        return False
    try:
        day = dt.date.fromisoformat(str(m.get("closed") or m.get("updated") or ""))
    except ValueError:
        return False
    return (dt.date.today() - day).days <= INBOX_CLOSED_DAYS


def _card_of(tid, open_only=True, recent=False):
    """The card of task `tid`; with open_only, only while it is open (or, with recent, closed lately)."""
    if not isinstance(tid, str) or not re.match(r"^T-\d+$", tid.strip(), re.I):
        return None
    tid = tid.strip().upper()
    for p in card_paths():
        d = os.path.basename(os.path.dirname(p))
        if d == tid or d.startswith(tid + "-"):
            m = parse_card(p)
            if open_only and m.get("status") not in OPEN_STATUSES and not (recent and recently_closed(m)):
                return None
            return p
    return None


def _flat(s, n):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


def inbox_refs(refs, text):
    """The links to file with a note: the model's titled ones, but only for URLs and ticket keys
    that are in the note itself (it must not invent links), then any URL of the note it left out."""
    text = str(text or "")
    urls = [u.rstrip(URL_TAIL) for u in REF_URL_RE.findall(text)]
    out = []
    for r in refs if isinstance(refs, list) else []:
        r = _flat(r, 300)
        if not r or is_placeholder(r):
            continue
        ru = [u.rstrip(URL_TAIL) for u in REF_URL_RE.findall(r)]
        if ru and all(u in urls for u in ru):
            out.append(r)
        elif not ru and r in text:      # a ticket key or a name the note itself gave
            out.append(r)
    have = {ref_key(r) for r in out}
    out += [u for u in urls if ref_key(u) not in have]
    return out


def inbox_dest(d, item, undo=None):
    """A destination checked against the board: None when it can't be applied (no such open task,
    an unknown kind). A project must already exist; a guess that doesn't is dropped. `undo`: the
    record of what the note wrote where it is now, about to be taken back — an update is checked
    against the card as it will be then."""
    from .feeds import FEED_SOURCES
    if not isinstance(d, dict) or d.get("kind") not in INBOX_KINDS:
        return None
    k = d["kind"]
    text = _flat(d.get("text"), 500) or _flat(item.get("text"), 500)
    out = {"kind": k, "text": text}
    if k in ("todo", "note", "update"):
        tid = str(d.get("task") or "").strip().upper()
        undo = undo if (undo or {}).get("task") == tid else None
        # A task this note's own update closed is open again once that is taken back.
        if not _card_of(tid, open_only=not _undo_reopens(undo), recent=k == "note"):
            if k == "update" and _card_of(tid, recent=True):
                k = out["kind"] = "note"    # closed lately: what it says still goes in its log
            else:
                return None
        out["task"] = tid
    if k == "update":
        _update_fields(out, d, undo)
        if not any(f in out for f in UPDATE_DEST_FIELDS + ("maybe",)):
            out["kind"] = "note"    # nothing left to change: what it says is a log line
    if k == "todo":
        owner = str(d.get("owner") or "me").strip().lstrip("@").split()
        owner = owner[0] if owner else "me"
        out["owner"] = owner.casefold() if owner.casefold() in ("me", "claude") else owner
    if k == "me":
        if not secretary_task_id():
            return None
        out["owner"] = "me"
    if k == "task":
        out["title"] = _flat(d.get("title"), 80) or _flat(item.get("text"), 60)
        if not out["title"]:
            return None
        names = [p["name"] for p in load_projects()]
        if d.get("project") in names:
            out["project"] = d["project"]
        w = inbox_workdir(d.get("workdir"), out.get("project"))
        if w:
            out["workdir"] = w
    if k != "me":
        # A feed note's body is other people's text: only its first line (the conversation's or
        # issue's own link) may give refs, so a link someone pasted never lands on a card.
        text = str(item.get("text") or "")
        refs = inbox_refs(d.get("refs"), text.split("\n", 1)[0] if item.get("via") in FEED_SOURCES else text)
        if refs:
            out["refs"] = refs
    return out


UPDATE_DEST_FIELDS = ("next", "state", "status", "done")


def todo_label(t):
    """A todo line (a TODO_RE match) as an update's `done` names it: "@owner text"."""
    o = todo_owner(t.group(3))
    return (f"@{o} " if o else "") + todo_plain(t.group(3))


def _undo_reopens(u):
    """Whether taking back undo record `u` reopens its task: it closed it, and it is still so."""
    st = ((u or {}).get("fields") or {}).get("status")
    if not st or st[1] not in INBOX_ASK_STATUSES:
        return False
    card = _card_of(u.get("task"), open_only=False)
    return bool(card) and parse_card(card).get("status") == st[1]


def open_todo_hits(lines, want):
    """The open todos `want` ("@owner text", or the text alone) can mean: the ones with exactly that
    text, else those containing it. A model shortens a long todo with "…": that is cut off for the
    containing match only, so a todo that itself ends in "." or "…" still matches exactly."""
    owner = todo_owner(want)
    full = " ".join(todo_plain(want).split()).casefold()
    key = full.rstrip("…. ")
    if not key:
        return []
    mine = [x for x in card_todos(lines) if x[2].group(2) == " "
            and (owner is None or todo_owner(x[2].group(3)) == owner)]
    return [x for x in mine if x[3].casefold() == full] or [x for x in mine if key in x[3].casefold()]


def one_todo(hits):
    """The todo hits mean, when they mean one: a single hit, or identical lines (either will do)."""
    return hits[0] if hits and len({todo_label(x[2]) for x in hits}) == 1 else None


def _tick_line(lines, tick):
    """Where tick [old, new, i] is now: its own line when that is still as written, else the first
    identical one; None when it is gone."""
    i = tick[2] if len(tick) > 2 else None
    if isinstance(i, int) and 0 <= i < len(lines) and lines[i] == tick[1]:
        return i
    return lines.index(tick[1]) if tick[1] in lines else None


def _update_fields(out, d, undo=None):
    """An update's next / state / status / done, checked against its card: only what would change
    it, todos named as the card has them. A todo the note may mean more than one of goes in `maybe`
    (each a list of candidates) — inbox_split makes a button of each. With `undo`, the card is
    read as it will be once that is taken back (a move from one update to another)."""
    card = _card_of(out["task"], open_only=False)     # checked open (or reopened by `undo`) already
    meta = parse_card(card)
    lines = open(card, encoding="utf-8").read().split("\n")
    undo = undo or {}
    for f, (old, new) in (undo.get("fields") or {}).items():
        if meta.get(f) == new:
            meta[f] = old
    if undo.get("state"):
        m = STATUS_HEADING_RE.search(meta["body"] + "\n")
        if m and m.group(1).strip() == undo["state"][1].strip():
            meta["body"] = meta["body"][:m.start(1)] + undo["state"][0] + meta["body"][m.end(1):]
    for tick in undo.get("ticks") or []:
        i = _tick_line(lines, tick)
        if i is not None:
            lines[i] = tick[0]
    nxt = _flat(d.get("next"), 300)
    if nxt and not is_placeholder(nxt) and nxt != str(meta.get("next") or ""):
        out["next"] = nxt
    raw = d.get("state")
    raw = "\n".join(map(str, raw)) if isinstance(raw, list) else str(raw or "")
    # Plain lines: a heading would start a section of its own, a checkbox would become a todo.
    state = [_flat(re.sub(r"^(?:#+|-\s*\[[ xX\-]\])\s*", "", l.strip()), 300) for l in raw.splitlines()]
    state = [l for l in state if l and not is_placeholder(l)][:5]
    if state and STATUS_HEADING_RE.search(meta["body"] + "\n") and state != card_state_lines(meta["body"]):
        out["state"] = "\n".join(state)
    status = str(d.get("status") or "").strip().lower()
    if status in STATUSES and status != meta.get("status"):
        out["status"] = status
    done, maybe = [], []
    for want in d.get("done") if isinstance(d.get("done"), list) else []:
        hits = list(dict.fromkeys(todo_label(x[2]) for x in open_todo_hits(lines, str(want))))
        if len(hits) == 1:
            done.append(hits[0])
        elif hits:
            maybe.append(hits[:3])
    done = list(dict.fromkeys(done))
    if done:
        out["done"] = done
    maybe = [m for m in maybe if not set(m) & set(done)]
    if maybe:
        out["maybe"] = maybe


def inbox_clean(d):
    """A destination as it is filed: an update without its `maybe`, and one with nothing left to
    change is a log line."""
    if not d or d.get("kind") != "update":
        return d
    d = {k: v for k, v in d.items() if k != "maybe"}
    return d if any(f in d for f in UPDATE_DEST_FIELDS) else dict(d, kind="note")


def inbox_split(d):
    """What of an update the sorter may write by itself, and the buttons for the rest: closing the
    task (done / abandoned) and a todo it may mean more than one of wait for the user's click."""
    if not d or d.get("kind") != "update":
        return d, []
    base = {k: v for k, v in d.items() if not (k == "status" and v in INBOX_ASK_STATUSES)}
    extra = [inbox_clean(dict(base, status=d["status"]))] if d.get("status") in INBOX_ASK_STATUSES else []
    for cands in d.get("maybe") or []:
        extra += [inbox_clean(dict(base, done=list(base.get("done") or []) + [c])) for c in cands]
    return inbox_clean(base), extra


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def inbox_workdir(guess, project):
    """A new task's folder, so New session has somewhere to start: the path the sorter gave, or one
    it named by its last part only; else the project's own folder; else the one the project's
    tasks work in most. "" when none of these exists."""
    seen = collections.Counter()
    for m in (parse_card(p) for p in card_paths()):
        for w in m.get("workdirs") or []:
            if isinstance(w, str):
                seen[(m.get("project") or "", os.path.normpath(os.path.expanduser(w)))] += 1
    used = collections.Counter()
    for (_, w), n in seen.items():
        used[w] += n
    g = str(guess or "").strip()
    if g:
        w = os.path.normpath(os.path.expanduser(g))
        if os.path.isabs(w):
            if ok_workdir(w):
                return w
        else:
            base = os.path.basename(g.rstrip("/"))
            # The project's own folders first: two projects may each have a "docs".
            for pool in ([(n, w) for (pj, w), n in seen.items() if project and pj == project], [(n, w) for w, n in used.items()]):
                hits = [(n, w) for n, w in pool if os.path.basename(w) == base and ok_workdir(w)]
                if hits:
                    return max(hits)[1]
    if project:
        pr = next((p for p in load_projects() if p["name"] == project), {})
        for p in pr.get("paths") or []:
            if ok_workdir(p):
                return os.path.normpath(p)
        mine = sorted(((n, w) for (pj, w), n in seen.items() if pj == project and ok_workdir(w)), reverse=True)
        if mine:
            return mine[0][1]
    return ""


def inbox_label(d):
    """One line saying where a note went, for the CLI and the pet's bubble."""
    if not d:
        return "unsorted"
    k = d["kind"]
    if k == "task":
        return f"new task \"{d.get('title')}\"" + (f" ({d['project']})" if d.get("project") else "")
    if k == "todo":
        return f"{d['task']} todo @{d.get('owner', 'me')}: {d['text']}"
    if k == "note":
        return f"{d['task']} log: {d['text']}"
    if k == "update":
        bits = [f"status → {d['status']}"] if d.get("status") else []
        bits += [f"next → {d['next']}"] if d.get("next") else []
        bits += ["state"] if d.get("state") else []
        bits += [f"✓ {t}" for t in d.get("done") or []]
        return f"{d['task']} update: " + "; ".join(bits + [f"log: {d['text']}"])
    return f"@me todo: {d['text']}"


def _add_refs(card, refs):
    """Adds refs; returns the ones that were not there (the ones a move takes back out)."""
    if not refs:
        return []
    with card_lock(card):
        meta = parse_card(card)
        have = meta.get("refs") if isinstance(meta.get("refs"), list) else []
        # Only links the card doesn't have (nor its HISTORY.md): one it has keeps its own title, and
        # stays on a move.
        keys = {ref_key(r) for r in have} | {ref_key(x[2:]) for x in read_history(card)["Links"]}
        new = [r for r in merge_refs([], refs) if ref_key(r) not in keys]
        if not new:
            return []
        set_fields(card, {"refs": have + new})
        return new


def inbox_apply(item, d):
    """Writes a note to the board as `d` says. Returns the undo record: the lines and refs it added
    (or the card it made, with a hash of what it wrote) so a move can take exactly those back out."""
    k = d["kind"]
    shots = item.get("images") or []
    shot_text = " ".join(shots)
    if k == "task":
        tid, card = new_card(d["title"], project=d.get("project"),
                             workdirs=[d["workdir"]] if d.get("workdir") else None)
        goal = d.get("text") or item.get("text") or d["title"]
        orig = _flat(item.get("text"), 500)
        if orig and orig != goal:
            goal += f"\n\n> {orig}"
        if shots:
            goal += "\n\n" + "\n".join(f"- {s}" for s in shots)
        with card_lock(card):
            text = open(card, encoding="utf-8").read()
            text = re.sub(r"(?m)^(##[ \t]*(?:Goal|目标)[^\n]*\n)<[^\n]*>$", lambda m: m.group(1) + goal, text, count=1)
            atomic_write(card, text)
        _add_refs(card, d.get("refs"))
        append_log(card, f"Created from quick note {item['id']}")
        return {"card": card, "task": tid, "created": hashlib.sha256(open(card, "rb").read()).hexdigest()}
    if k in ("todo", "me"):
        tid = d["task"] if k == "todo" else secretary_task_id()
        card = _card_of(tid, open_only=False)
        if not card:
            raise InboxError(f"no task {tid}")
        u = {"card": card, "task": tid, "todos": [add_todo(card, f"@{d.get('owner', 'me')} {d['text']}")], "logs": []}
        if shots:
            u["logs"].append(append_log(card, f"Quick note {item['id']} came with: {shot_text}"))
        u["refs"] = _add_refs(card, d.get("refs")) if k == "todo" else []
        return u
    if k == "update":
        return inbox_apply_update(item, d)
    card = _card_of(d["task"], open_only=False)
    if not card:
        raise InboxError(f"no task {d['task']}")
    line = d["text"] + (f" ({shot_text})" if shots else "")
    return {"card": card, "task": d["task"], "logs": [append_log(card, line)], "todos": [],
            "refs": _add_refs(card, d.get("refs"))}


UPDATE_UNDO_FIELDS = ("next", "status", "closed", "closed_at", "closing")


def inbox_apply_update(item, d):
    """An update: ticks its todos, replaces the status section, next and status, and logs the note.
    The undo record keeps each todo line, the section and every field as they were and as written
    (`ticks`, `state`, `fields`: [before, after]), so a move puts back only what is still as written."""
    card = _card_of(d["task"])
    if not card:
        raise InboxError(f"no open task {d['task']}")
    via = f"quick note {item['id']}"
    shots = item.get("images") or []
    u = {"card": card, "task": d["task"], "logs": [], "todos": [], "ticks": [], "fields": {}, "state": None}
    with card_lock(card):
        before = parse_card(card)
        lines = open(card, encoding="utf-8").read().split("\n")
        ticked = []
        for want in d.get("done") or []:
            hit = one_todo(open_todo_hits(lines, want))
            if not hit:
                continue        # ticked or changed since the note was sorted: leave it
            i, num, t, _ = hit
            new = f"{t.group(1)}- [x] {t.group(3)}"
            u["ticks"].append([lines[i], new, i])
            lines[i] = new
            ticked.append((num, t))
        if ticked:
            atomic_write(card, "\n".join(lines))
            for num, t in ticked:
                log_tick(card, f"todo #{num} → done ({via}): {TODO_TIME_RE.sub('', t.group(3))}")
        if d.get("state"):
            text = open(card, encoding="utf-8").read()
            m = STATUS_HEADING_RE.search(text)
            if m:
                atomic_write(card, text[:m.start(1)] + d["state"] + "\n\n" + text[m.end(1):])
                after = STATUS_HEADING_RE.search(open(card, encoding="utf-8").read())
                u["state"] = [m.group(1), after.group(1)]
        fields = {f: d[f] for f in ("next", "status") if d.get(f)}
        if "status" in fields:
            fields["closing"] = None     # a status set outright replaces a held close
        set_fields(card, fields)
        if "status" not in fields and any(todo_owner(t.group(3)) == "me" for _, t in ticked) and settle_status(card, via):
            u["logs"].append(_last_log(card))
        line = d["text"] + (f" ({' '.join(shots)})" if shots else "")
        u["logs"].append(append_log(card, line))
        u["refs"] = _add_refs(card, d.get("refs"))
        now = parse_card(card)
        u["fields"] = {f: [before.get(f), now.get(f)] for f in UPDATE_UNDO_FIELDS if before.get(f) != now.get(f)}
    return u


def _last_log(card):
    lines = [l for l in open(card, encoding="utf-8").read().split("\n") if LOG_ENTRY_RE.match(l.strip())]
    return lines[-1] if lines else ""


def inbox_undo_update(u, card):
    """inbox_undo for an update: each tick, the status section and each field it wrote go back to
    what they were, where they are still as it left them. Returns what it left in place."""
    kept = []
    with card_lock(card):
        lines = open(card, encoding="utf-8").read().split("\n")
        unticked = []
        for tick in u.get("ticks") or []:
            i = _tick_line(lines, tick)
            if i is None:
                kept.append(tick[1])
            else:
                lines[i] = tick[0]
                unticked.append(tick[0])
        if unticked:
            atomic_write(card, "\n".join(lines))
            for old in unticked:
                t = TODO_RE.match(old)
                log_tick(card, f"todo → open (quick note taken back): {TODO_TIME_RE.sub('', t.group(3)) if t else old}")
        if u.get("state"):
            old, new = u["state"]
            text = open(card, encoding="utf-8").read()
            m = STATUS_HEADING_RE.search(text)
            if m and m.group(1) == new:
                atomic_write(card, text[:m.start(1)] + old + text[m.end(1):])
            else:
                kept.append("the status section")
        meta = parse_card(card)
        back = {}
        for f, (old, new) in (u.get("fields") or {}).items():
            if meta.get(f) == new:
                back[f] = old
            elif f in ("next", "status"):
                kept.append(f"{f}: {meta.get(f)}")
        if "status" not in back:
            # The dates it was closed on and a held close belong to the status: they go back with
            # it, never alone (a card closed again since keeps its own).
            back = {f: v for f, v in back.items() if f not in ("closed", "closed_at", "closing")}
        set_fields(card, back)
    return kept


def inbox_undo(u):
    """Takes back what inbox_apply wrote, as far as it is still there untouched. A card it made is
    removed only while nothing else has written to it; otherwise it is closed as abandoned.
    Returns a note on anything left in place."""
    card = (u or {}).get("card")
    if not card or not os.path.isfile(card):
        return ""
    kept = inbox_undo_update(u, card) if u.get("ticks") or u.get("state") or u.get("fields") else []
    if u.get("created"):
        d = os.path.dirname(card)
        same = hashlib.sha256(open(card, "rb").read()).hexdigest() == u["created"]
        # HISTORY.md may be there too: a process link in the note went there (the card budget).
        if same and set(os.listdir(d)) <= {"TASK.md", HISTORY_FILE}:
            shutil.rmtree(d)
            save_focus([i for i in load_focus() if i != u.get("task")])
            return ""
        set_fields(card, {"status": "abandoned"})
        append_log(card, "Abandoned: the quick note it was made from was moved elsewhere")
        return f"{u.get('task')} had changed since, so it was closed as abandoned rather than removed"
    with card_lock(card):
        lines = open(card, encoding="utf-8").read().split("\n")
        for want in list(u.get("todos") or []) + list(u.get("logs") or []):
            if want in lines:
                lines.remove(want)
            else:
                kept.append(want)
        atomic_write(card, "\n".join(lines))
        if u.get("refs"):
            meta = parse_card(card)
            refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
            set_fields(card, {"refs": [r for r in refs if r not in u["refs"]]})
            history_drop_links(card, {ref_key(r) for r in u["refs"]})    # the process links it added
        else:
            set_fields(card, {})
    if kept:
        return f"left on {u.get('task')} (changed since): " + "; ".join(_flat(TODO_TIME_RE.sub("", k), 60) for k in kept)
    return ""


INBOX_SCHEMA_DEST = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": list(INBOX_KINDS) + ["unsorted"]},
        "task": {"type": "string", "description": "T-nnn, for todo, note and update"},
        "owner": {"type": "string", "description": "todo: me, claude, or a person's first name"},
        "text": {"type": "string", "description": "todo text / log line / new task's goal"},
        "title": {"type": "string", "description": "new task: a short title"},
        "project": {"type": "string"},
        "workdir": {"type": "string"},
        "refs": {"type": "array", "items": {"type": "string"}, "description": "\"<short title> <url>\" for links in the note"},
        "next": {"type": "string", "description": "update: the task's next concrete action, replacing its next"},
        "state": {"type": "string", "description": "update: where the task stands now, 1-3 short lines, replacing its state"},
        "status": {"type": "string", "enum": STATUSES, "description": "update: the task's new status, only when the note says it changed"},
        "done": {"type": "array", "items": {"type": "string"}, "description": "update: open todos of that task the note says are finished, copied as listed"},
    },
    "required": ["kind"],
}
INBOX_SCHEMA = {
    "type": "object",
    "properties": dict(INBOX_SCHEMA_DEST["properties"], **{
        "confidence": {"type": "number", "description": "0..1: how sure you are of kind and task"},
        "reason": {"type": "string", "description": "one short sentence, in the note's language"},
        "alternatives": {"type": "array", "maxItems": 2, "items": INBOX_SCHEMA_DEST,
                         "description": "the next most likely destinations, most likely first"},
    }),
    "required": ["kind", "confidence", "reason", "alternatives"],
}

INBOX_SYSTEM = """You sort quick notes the user jotted down into their HQ task board. The user hit a \
shortcut, typed a line (maybe pasted a link or a screenshot) and went back to work; you decide where \
it belongs. You see the open tasks, the projects and what the secretary knows about the user and \
their colleagues.

Pick exactly one kind:
- "todo": something to do that belongs to one open task. Set task (its id) and owner: "me" when \
the user has to do it (send, review, decide, ask someone), "claude" when it is work for the \
Claude session on that task (code, a run, an investigation), or a colleague's first name when the \
note says they will do it. text: the todo itself, short and imperative, without the task's name.
- "note": information for one task: a finding, a decision, a number, a link, what someone \
said. Set task (an open one, or one of the recently closed); text: the fact as one log line.
- "update": the note changes how an open task stands: a PR merged, a run finished, it waits on \
someone now, it is done, or it asks to update the task's next or status. Set task and text (the \
fact as one log line, as for "note"), and only what the note supports: next (the next concrete \
action now, replacing the task's), state (where it stands now, 1-3 short lines, replacing its \
state), status (active, blocked, waiting-on-me, or done / abandoned when the note says the task \
is finished or dropped — those two are only offered to the user, never written by themselves), \
done (the task's open todos the note says are finished, each copied exactly as listed). Prefer \
"update" over "note" when the note finishes one of the task's listed todos or moves it on.
- "task": new work that fits no open task. title: short (≤ 60 chars); text: the goal, one or two \
sentences; project only from the list given, when one clearly fits; workdir: a path the \
note names, else the folder of the open task or project the work is closest to (copied in full \
from the dirs listed), else leave it out.
- "me": a personal reminder for the user that belongs to no task (call the dentist, renew the \
badge). text: the reminder.
- "unsorted": you can't tell, or the note is too short to act on.

Matching a note to a task: names of tasks, tickets (ABC-123), PR numbers, repos, people (who owns \
what: see People), projects. When two tasks fit about equally, say so with a low confidence and \
give the other one as an alternative. Never invent task ids: use only those listed.

Links: put each link of the note in refs as "<short title> <url>" (the url exactly as in the \
note). Screenshots: if the note lists image paths, look at them with Read first.

Write text, title and reason in the note's language. confidence: 0.9+ when the note names the \
task or the match is unambiguous, 0.7-0.9 when it is a clear but indirect match, below 0.7 when \
you are guessing. Always give up to two alternatives (other plausible destinations), each a \
complete destination."""


def inbox_context():
    """What the sorter sees: the open tasks, projects and the secretary's memory."""
    sec = secretary_task_id()
    out = [f"Today: {today()}", "", "## Open tasks"]
    metas = [parse_card(p) for p in card_paths()]
    closed = [m for m in metas if recently_closed(m) and m.get("id") != sec]
    for m in [m for m in metas if m.get("status") in OPEN_STATUSES and m.get("id") != sec] + [None] + closed:
        if m is None:
            out += ["", f"## Closed in the last {INBOX_CLOSED_DAYS} days (a note may still go here; never a todo)"]
            continue
        bits = [m.get("id", "?"), _flat(m.get("title"), 90)]
        if m.get("project"):
            bits.append(f"project {m['project']}")
        bits.append(m.get("status", ""))
        if m.get("next") and not is_placeholder(str(m["next"])):
            bits.append("next: " + _flat(m["next"], 100))
        dirs = [tilde(w) for w in (m.get("workdirs") or []) if isinstance(w, str)]
        if dirs:
            bits.append("dirs: " + ", ".join(dict.fromkeys(dirs)))
        refs = [_flat(r, 70) for r in (m.get("refs") or []) if isinstance(r, str)][:4]
        if refs:
            bits.append("refs: " + "; ".join(refs))
        state = card_state_lines(m["body"])[:2]
        if state:
            bits.append("state: " + _flat(" ".join(state), 160))
        todos = [(f"@{t['owner']} " if t.get("owner") else "") + _flat(t["text"], 100)
                 for t in m.get("todos") or [] if t["state"] == "open"][:8]
        if todos and m.get("status") in OPEN_STATUSES:
            bits.append("open todos: " + "; ".join(todos))
        out.append("- " + " | ".join(bits))
    out += ["", "## Projects"]
    for pr in load_projects():
        info = project_info(pr)
        out.append(f"- {pr['name']}" + (f": {_flat(info.get('title') or info.get('goal'), 120)}"
                                         if info.get("title") or info.get("goal") else "")
                   + (" | dirs: " + ", ".join(tilde(p) for p in pr["paths"]) if pr.get("paths") else ""))
    mem = os.path.join(hq_root(), "secretary")
    for f, head in (("profile.md", "The user"), ("people.md", "People")):
        p = os.path.join(mem, f)
        if os.path.isfile(p):
            t = open(p, encoding="utf-8").read().strip()
            if t:
                out += ["", f"## {head} (secretary/{f})", t[:4000]]
    return "\n".join(out)


def inbox_model():
    cfg = load_json(root_config_path(), {})
    m = (cfg.get("inbox") or {}).get("model") if isinstance(cfg, dict) and isinstance(cfg.get("inbox"), dict) else None
    return os.environ.get("HQ_INBOX_MODEL") or (m if isinstance(m, str) and m else INBOX_DEFAULT_MODEL)


def run_sorter(item, claude):
    """One headless run of a cheap model: no settings (so no hooks, plugins or MCP servers), no
    tools but Read for the note's screenshots, nothing saved. Returns its structured answer."""
    from .feeds import FEED_INTRO, FEED_NAMES, FEED_SCHEMA, FEED_SECRET_ENV, FEED_SOURCES, FEED_SYSTEM
    feed = item.get("via") in FEED_SOURCES
    prompt = inbox_context() + ("\n\n## The messages\n" if feed else "\n\n## The note\n") + (item.get("text") or "(no text)")
    if item.get("images"):
        prompt += "\n\nScreenshots attached to the note (Read them):\n" + "\n".join(item["images"])
    cmd = [claude, "-p", "--model", inbox_model(), "--setting-sources", "", "--strict-mcp-config",
           "--no-session-persistence", "--output-format", "json",
           "--json-schema", json.dumps(FEED_SCHEMA if feed else INBOX_SCHEMA),
           "--system-prompt", FEED_SYSTEM.replace("{source}", FEED_NAMES[item["via"]]).replace("{intro}", FEED_INTRO[item["via"]]) if feed else INBOX_SYSTEM]
    dirs = sorted({os.path.dirname(i) for i in item.get("images") or []})
    if dirs:
        cmd += ["--tools", "Read", "--allowedTools", "Read"] + [a for d in dirs for a in ("--add-dir", d)]
    else:
        cmd += ["--tools", ""]
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE_CODE_SESSION") and k not in FEED_SECRET_ENV}
    env["HQ_HOOK_CHILD"] = "1"
    try:
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=INBOX_SORT_TIMEOUT,
                           cwd=dirs[0] if dirs else tempfile.gettempdir(), env=env)
    except subprocess.TimeoutExpired:
        raise InboxError(f"the sorter took longer than {INBOX_SORT_TIMEOUT}s")
    except OSError as e:
        raise InboxError(f"could not run claude: {e}")
    try:
        out = json.loads(r.stdout)
    except ValueError:
        raise InboxError(one_line((r.stderr or r.stdout or f"claude exited {r.returncode}").strip(), 200))
    if out.get("is_error") or not isinstance(out.get("structured_output"), dict):
        raise InboxError(one_line(str(out.get("result") or out.get("subtype") or "no answer"), 200))
    return out["structured_output"], out.get("total_cost_usd")


def inbox_sort(nid, claude=None):
    """Asks the model where the note goes. A confident answer is applied at once; otherwise the note
    stays unsorted with the guess shown. Returns the item."""
    from .feeds import FEED_SOURCES
    def start(x):
        if x.get("state") not in ("unsorted", "sorting"):
            die(f"{x['id']} is already {x['state']}")
        x.update(state="sorting", sort_started=now_iso(), error=None, skip=False)
    item = inbox_update(nid, start)
    exe = find_claude(claude)
    try:
        if not exe:
            raise InboxError("claude not found (pass --claude PATH)")
        ans, cost = run_sorter(item, exe)
    except InboxError as e:
        # Only if nothing happened meanwhile: a move or drop made while it ran stands.
        err = str(e)
        return inbox_update(nid, lambda x: x.update(state="unsorted", error=err) if x.get("state") == "sorting" else None)
    # Closing the task, or a todo the note may mean more than one of, becomes a button of its own.
    pick, extra = inbox_split(inbox_dest(ans, item))
    alts = []
    for d in extra + [inbox_clean(inbox_dest(a, item)) for a in ans.get("alternatives") or []]:
        if d and d != pick and d not in alts:
            alts.append(d)
    conf = ans.get("confidence") if isinstance(ans.get("confidence"), (int, float)) else 0
    fields = {"dest": pick, "alts": alts[:INBOX_MAX_ALTS], "reason": _flat(ans.get("reason"), 300), "confidence": conf,
              "by": inbox_model(), "cost": cost, "sorted_at": now_iso()}
    if item.get("via") in FEED_SOURCES:
        # Messages from outside are never filed by themselves: the guess waits for the user's click
        # (take it, or drop the note). "skip" too: the board folds those away.
        skip = ans.get("kind") == "skip"
        return inbox_update(nid, lambda x: x.update(fields, state="unsorted", skip=skip)
                            if x.get("state") == "sorting" else None)
    if pick and conf >= INBOX_CONFIDENT:
        with inbox_lock():
            items = load_inbox()
            x = inbox_item(items, nid)
            if x.get("state") != "sorting":     # moved or dropped by hand meanwhile: leave it
                return dict(x, state=inbox_state(x))
            try:
                undo = inbox_apply(x, pick)
                x.update(fields, state="sorted", undo=undo)
            except (InboxError, SystemExit) as e:
                x.update(fields, state="unsorted", error=str(e) if isinstance(e, InboxError) else "could not apply")
            save_inbox(items)
            return dict(x, state=inbox_state(x))
    return inbox_update(nid, lambda x: x.update(fields, state="unsorted") if x.get("state") == "sorting" else None)


def inbox_move(nid, want):
    """Takes back what the note wrote (if anything) and files it as `want` says; kind "unsorted"
    just takes it back. Fields `want` leaves out come from a guess of the same kind (and task), else
    from where it is now."""
    with inbox_lock():
        items = load_inbox()
        x = inbox_item(items, nid)
        if want.get("kind") == "unsorted":
            d = None
        else:
            # A guess that would close the task comes last: it is only a seed for the other fields.
            guesses = sorted([a for a in [x.get("dest")] + list(x.get("alts") or []) if a],
                             key=lambda a: a.get("status") in INBOX_ASK_STATUSES)
            seed = next((a for a in guesses if a.get("kind") == want.get("kind")
                         and (not want.get("task") or a.get("task") == want["task"].strip().upper())), None) or {}
            base = dict(seed)
            if want.get("kind") == "update" and base.get("status") in INBOX_ASK_STATUSES:
                base.pop("status")     # closing the task takes an explicit --status, not a guess
            if want.get("kind") == "update" and any(want.get(f) for f in UPDATE_DEST_FIELDS):
                # A chip or the CLI said what to change: only that, not the guess's changes too.
                base = {k: v for k, v in base.items() if k not in UPDATE_DEST_FIELDS + ("maybe",)}
            if not base.get("text") and x.get("dest"):
                base["text"] = x["dest"].get("text")
            base.update({k: v for k, v in want.items() if v not in (None, "", [])})
            d = inbox_clean(inbox_dest(base, x, x.get("undo") if x.get("state") == "sorted" else None))
            if not d:
                die(f"can't file {x['id']} there: " + ("no such open task" if want.get("kind") in ("todo", "note", "update")
                                                       else "the secretary isn't set up" if want.get("kind") == "me"
                                                       else "it needs a title"))
            if want.get("kind") == "update" and d["kind"] != "update":
                die(f"nothing on {d['task']} to change — give --next, --state, --status or --done "
                    "(a todo that is ticked already, or a next that is the card's, changes nothing)")
        u = x.get("undo") or {}
        if d and x.get("state") == "sorted" and u.get("created") and d.get("task") == u.get("task"):
            # Taking the note back would remove the very card it is being filed on.
            die(f"{u.get('task')} was made from {x['id']} — edit that card, or move the note to unsorted first")
        left = inbox_undo(u) if x.get("state") == "sorted" else ""
        x.update(undo=None, error=None, skip=False)
        if d:
            # Where it was stays one click away: the old place joins the alternatives.
            alts = []
            for a in [x.get("dest")] + list(x.get("alts") or []):
                if a and a != d and a not in alts:
                    alts.append(a)
            try:
                x.update(state="sorted", undo=inbox_apply(x, d), dest=d, alts=alts[:INBOX_MAX_ALTS], by="user", moved_at=now_iso())
            except InboxError as e:
                # The old place is already taken back: say so on the note rather than leave it
                # pointing there.
                x.update(state="unsorted", error=str(e), alts=alts[:INBOX_MAX_ALTS], by="user", moved_at=now_iso())
        else:
            x.update(state="unsorted", by="user", moved_at=now_iso())
        save_inbox(items)
        return dict(x, state=inbox_state(x), left=left)


def inbox_view(items=None, everything=False):
    """For the board: every unsorted note, and those sorted or dropped in the last INBOX_RECENT_HOURS."""
    items = load_inbox() if items is None else items
    cut = time.time() - INBOX_RECENT_HOURS * 3600
    out = []
    for x in items:
        st = inbox_state(x)
        if not everything and st == "dropped" and x.get("skipped"):
            continue        # messages the sorter found nothing in: `hq inbox --all` shows them
        if not everything and st == "unsorted" and x.get("skip") and \
                (ts_seconds(x.get("sorted_at") or x.get("at")) or 0) < cut:
            continue        # a likely skip nobody looked at in two days: `hq inbox --all` still has it
        if everything or st in ("unsorted", "sorting") or (ts_seconds(x.get("moved_at") or x.get("sorted_at") or x.get("at")) or 0) >= cut:
            out.append(dict({k: v for k, v in x.items() if k != "undo"}, state=st,
                            task=(x.get("undo") or {}).get("task")))
    return sorted(out, key=lambda x: int(re.sub(r"\D", "", x.get("id") or "") or 0), reverse=True)


def cmd_inbox(args):
    a = args.action
    if a == "add":
        text = " ".join(args.rest)
        x = inbox_add(text, args.image or [], via=args.via)
        if args.sort:
            x = inbox_sort(x["id"], args.claude)
    elif a == "sort":
        if not args.rest:
            die("usage: hq inbox sort N-001")
        x = inbox_sort(args.rest[0], args.claude)
    elif a in ("move", "drop"):
        if not args.rest:
            die(f"usage: hq inbox {a} N-001" + (" task|todo|note|update|me|unsorted [--task T-1] …" if a == "move" else ""))
        if a == "drop":
            def drop(x):
                if x.get("state") == "sorted":
                    die(f"{x['id']} is filed — move it to unsorted first")
                x.update(state="dropped", moved_at=now_iso())
            x = inbox_update(args.rest[0], drop)
        else:
            if len(args.rest) < 2 or args.rest[1] not in INBOX_KINDS + ("unsorted",):
                die("move to one of: " + ", ".join(INBOX_KINDS + ("unsorted",)))
            if args.status and args.status not in STATUSES:
                die(f"--status must be one of {', '.join(STATUSES)}")
            x = inbox_move(args.rest[0], {"kind": args.rest[1], "task": args.task, "owner": args.owner,
                                          "text": args.text, "title": args.title, "project": args.project,
                                          "workdir": args.workdir, "next": args.next, "state": args.state,
                                          "status": args.status, "done": args.done})
    elif a == "restore":
        # Undo of a drop: back to unsorted.
        x = inbox_update(args.rest[0] if args.rest else die("usage: hq inbox restore N-001"),
                         lambda x: x.update(state="unsorted", skipped=False) if x.get("state") == "dropped" else None)
    else:
        items = inbox_view(everything=args.all)
        if args.json:
            print(json.dumps({"items": items, "model": inbox_model()}, ensure_ascii=False, indent=1))
            return
        if not items:
            print("inbox is empty")
        for x in items:
            where = inbox_label(x.get("dest")) if x["state"] == "sorted" else x["state"] + (
                f" (guess: {inbox_label(x['dest'])})" if x.get("dest") else "") + (f" — {x['error']}" if x.get("error") else "")
            print(f"{x['id']}  {_flat(x.get('text'), 60)}\n        → {where}")
        return
    if args.json:
        print(json.dumps(dict({k: v for k, v in x.items() if k != "undo"}, task=(x.get("undo") or {}).get("task")),
                         ensure_ascii=False, indent=1))
        return
    print(f"{x['id']} → " + (inbox_label(x.get("dest")) if x.get("state") == "sorted" else x.get("state", "")))
    if x.get("error"):
        print(f"  ({x['error']})")
    if x.get("left"):
        print(f"  ({x['left']})")
