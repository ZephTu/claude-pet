"""The asks ledger (asks.jsonl): adding, answering and snoozing asks, and the task status they move."""
import datetime as dt
import json
import os
import time

from .core import (
    card_lock, die, local_time, now_iso, OPEN_STATUSES, RESOLUTIONS, STATUSES, strip_hq_blocks, update_lines,
)
from .sessions import load_state, session_alive, update_session
from .cards import _set_fields, append_log, find_card, parse_card
from .projects import GRANT_SUGGEST_RE, intake_manual


# ---------------------------------------------------------------- asks ledger
def asks_path(task_dir):
    return os.path.join(task_dir, "asks.jsonl")


def read_asks(task_dir):
    """Fold the event log into current ask records, in creation order."""
    asks = {}
    p = asks_path(task_dir)
    if not os.path.exists(p):
        return []
    for line in open(p, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "open":
            asks[e["id"]] = dict(e, state="open")
        elif e.get("type") == "resolve" and e.get("id") in asks:
            a = asks[e["id"]]
            # An answer is news again: whatever was delivered before it (a "Later" typed into the
            # session) is not this answer. The board and the hook mark delivery after resolving.
            a.update(state=e["resolution"], note=e.get("note", ""), via=e.get("via"),
                     resolved_at=e.get("ts"), seq=e.get("seq"), delivered=None)
        elif e.get("type") == "reopen" and e.get("id") in asks:
            asks[e["id"]].update(state="open", note="", via=None, resolved_at=None, delivered=None, snoozed_until=None,
                                 later_note=None)
        elif e.get("type") == "move" and e.get("id") in asks:
            # `hq continue` took it to the new card (`to` is its id there); no longer open here.
            asks[e["id"]].update(state="moved", moved_to=e.get("to"))
        elif e.get("type") == "snooze" and e.get("id") in asks:
            # "Later" on the board: the ask stays open, out of sight until `until` (local ISO).
            asks[e["id"]]["snoozed_until"] = e.get("until") or None
            # Why it was put off, when that was said (`later: <note>` from the chat).
            asks[e["id"]]["later_note"] = (e.get("note") or None) if e.get("until") else None
        elif e.get("type") in ("delivered", "undelivered") and e.get("id") in asks:
            # Which session has been told the answer. Kept on the ask, not on the session, so it
            # survives that session being unbound — a second session must not be told again.
            asks[e["id"]]["delivered"] = e.get("session") if e["type"] == "delivered" else None
    return list(asks.values())


def append_event(task_dir, event):
    event.setdefault("ts", now_iso())
    event.setdefault("seq", time.time_ns())
    with open(asks_path(task_dir), "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def add_ask(card, text, session=None, context=None):
    # Read the ledger, pick the next id and append under the card's lock: Stop hooks of several
    # sessions on one task ask at once, and two of them must not take the same id.
    with card_lock(card):
        return _add_ask(card, text, session, context)


def _add_ask(card, text, session, context):
    meta = parse_card(card)
    existing = read_asks(meta["dir"])
    # "… [grant: <wording>]": a session from when standing grants existed suggesting one. Not
    # part of the question.
    m = GRANT_SUGGEST_RE.search(text)
    if m and text[:m.start()].strip():
        text = text[:m.start()]
    # Sessions are reminded of their open asks every turn and tend to repeat them: the same
    # question still open on this task is the same ask, not a new one.
    key = " ".join(text.split()).casefold()
    for a in existing:
        if a.get("state") == "open" and " ".join(a.get("text", "").split()).casefold() == key:
            return a["id"]
    n = max([int(a["id"].rsplit(".", 1)[1]) for a in existing] or [0]) + 1
    aid = f"{meta['id']}.{n}"
    event = {"type": "open", "id": aid, "task": meta["id"], "text": text.strip(), "session": session}
    if context:
        # The reply that asked — so the board can show why, even after the session is gone.
        event["context"] = strip_hq_blocks(context)[:6000]
    append_event(meta["dir"], event)
    return aid


def find_ask(aid):
    tid = aid.rsplit(".", 1)[0]
    card = find_card(tid)
    for a in read_asks(os.path.dirname(card)):
        if a["id"] == aid:
            return card, a
    die(f"no ask {aid}")


def snooze_until(text):
    """When a put-off ask comes back: tomorrow 00:00 for None, "" for "" (back now), else `text` as
    local time — None when it isn't a date or time."""
    if text is None:
        return (dt.date.today() + dt.timedelta(days=1)).isoformat() + "T00:00:00"
    if text == "":
        return ""
    t = local_time(text)
    return t.strftime("%Y-%m-%dT%H:%M:%S") if t else None


def current_ask(aid):
    """(card, id) of the ask now: one asked on a card since continued (`hq continue`) is answered
    where it is now."""
    card, a = find_ask(aid)
    seen = {aid}
    # Continued again and again: follow it to the card it is on now.
    while a.get("state") == "moved" and a.get("moved_to") and a["moved_to"] not in seen:
        aid = a["moved_to"]
        seen.add(aid)
        card, a = find_ask(aid)
    return card, aid


def snooze_ask(aid, until=None, note="", via="cli"):
    """Later: the ask stays open, out of sight until `until` (snooze_until; "" brings it back)."""
    when = snooze_until(until)
    if when is None:
        die(f"until must be a date or time like 2026-11-22 or 2026-11-22T09:00, not {until!r}")
    card, aid = current_ask(aid)
    if when:
        state = next((a["state"] for a in read_asks(os.path.dirname(card)) if a["id"] == aid), None)
        if state != "open":
            die(f"{aid} is already answered ({state}): nothing to put off — `hq ask reopen {aid}` first")
    ev = {"type": "snooze", "id": aid, "until": when, "via": via}
    if note and when:
        ev["note"] = note
    append_event(os.path.dirname(card), ev)
    return card


def answered_as(a):
    """An answered ask's answer in a few words, for refusing a second one: `do: go with v2`."""
    note = " ".join((a.get("note") or "").split())
    return a["state"] + (f": {note[:60]}{'…' if len(note) > 60 else ''}" if note else "")


def resolve_ask(aid, resolution, note="", via="cli", settle=True, until=None):
    """Answer an ask. `settle`: let the answer take the task out of waiting-on-me (settle_status).
    `later` is no answer: the ask is put off (snooze_ask) until `until`, tomorrow by default — what
    the board's Later does, so the question comes back instead of being closed for good."""
    if resolution not in RESOLUTIONS:
        die(f"resolution must be one of {', '.join(RESOLUTIONS)}")
    if resolution == "later":
        snooze_ask(aid, until, note, via)
        return
    card, aid = current_ask(aid)
    # Checked and written under the card's lock: a board answer landing in between is not overwritten.
    with card_lock(card):
        if via != "board":
            # Only the board changes an answer in place (the user editing it). A session or the CLI
            # answering again would quietly replace the user's own answer — often a session echoing
            # a board answer back as an hq-resolved line. To change one, reopen it first.
            a = next((a for a in read_asks(os.path.dirname(card)) if a["id"] == aid), None)
            if a and a["state"] != "open":
                die(f"{aid} is already answered ({answered_as(a)}): that answer stands — "
                    f"`hq ask reopen {aid}` first to change it")
        append_event(os.path.dirname(card), {"type": "resolve", "id": aid, "resolution": resolution, "note": note, "via": via})
    if settle:
        settle_status(card, via)
        # A close held over this question: a No needs nothing done, so with the holding session
        # gone (nothing to tell, no turn to wait for) it closes now — unless a Yes given since is
        # still waiting for that session. A running one closes it at the end of its next turn.
        if resolution in ("drop", "archive") and parse_card(card).get("closing"):
            hsid, held = close_holder(parse_card(card)["id"])
            if session_alive(hsid) is not True and close_ready(card, hsid, held or {}, None):
                if release_close(card, via) and hsid:
                    update_session(hsid, lambda e: e.pop("held", None))


# Automatic status moves. A status is otherwise only what a session's hq-update, `hq set` or the
# board wrote — and "waiting-on-me" stayed on after the user had answered everything, until the
# session happened to write `status: active`. Only these moves are made: waiting-on-me ↔ active,
# and blocked → waiting-on-me when a session opens a new ask on a blocked task (its open asks and
# @me todos don't keep it out of the board's Blocked lane, but a new question is the user's turn).
# Done and abandoned are never changed by anything but an explicit status, or a session's own close
# held until its questions were answered (hold_close).
def on_user(meta):
    """What the card has waiting on the user: open asks (a snoozed one is still open), open @me
    todos, and the legacy `waiting_on_me` field the board still counts."""
    return (any(a.get("state") == "open" for a in read_asks(meta["dir"]))
            or any(t["state"] == "open" and t["owner"] == "me" for t in meta["todos"])
            or bool(str(meta.get("waiting_on_me") or "").strip()))


def open_me_todos(card):
    return sum(1 for t in parse_card(card)["todos"] if t["state"] == "open" and t["owner"] == "me")


def settle_status(card, via):
    """waiting-on-me → active once nothing is left on the user. Called after an answer, or an
    @me todo ticked off or dropped — not after other todos: a card waiting on something it never
    wrote down as an ask or a todo keeps waiting until someone says otherwise."""
    with card_lock(card):
        meta = parse_card(card)
        if meta.get("status") != "waiting-on-me" or on_user(meta):
            return False
        _set_fields(card, {"status": "active"})
        append_log(card, f"status waiting-on-me → active (auto, {via}): no open ask or @me todo left", touch=False)
        return True


def await_answer(card, via, new_ask=False):
    """active → waiting-on-me: an ask was opened, or an answer or an @me todo taken back, and
    nothing said otherwise; with new_ask (a session asked something new), blocked → waiting-on-me
    too. Checked under the lock: an ask answered in the meantime leaves the task as it is."""
    with card_lock(card):
        meta = parse_card(card)
        old = meta.get("status")
        if old not in (("active", "blocked") if new_ask else ("active",)) or not on_user(meta):
            return False
        _set_fields(card, {"status": "waiting-on-me"})
        why = "a new question for you" if old == "blocked" else "something is open on you"
        append_log(card, f"status {old} → waiting-on-me (auto, {via}): {why}", touch=False)
        return True


# A reply that closes its task while questions on it are still open (often a last one, asked in
# that same reply: "delete the old worktrees?") doesn't close it yet. Closing would stop its session
# (the board's "Finishing a task" setting), and the answer would reach no one. The task waits on the
# user instead: the card gets `closing: <status>`, and the session that wrote it a `held` mark on its
# entry ({task, status, at, seq}). Only that session releases it, at the end of a turn that began with
# every answer given since in hand (answered in its own reply, or delivered to it before the turn
# started) — so a turn on something else, or another session on the task, never closes it under an
# answer still on its way. A No (or No context) needs no work: when the holding session isn't
# running, it closes at once. A status written outright (hq-update, `hq set`, the board) replaces it.
CLOSED_STATUSES = ("done", "abandoned")


def open_ask_count(card):
    return sum(1 for a in read_asks(os.path.dirname(card)) if a.get("state") == "open")


def hold_close(card, block):
    """An hq-update block that would close an open card with asks still open, rewritten to keep it
    waiting on the user: (block, the held status) — or (block, None) when there is nothing to hold.
    Called under the card lock, so an answer can't slip in between the count and the write."""
    st = None
    for k, v in update_lines(block):
        if k == "status" and v and v.lower() in STATUSES:
            st = v.lower()
    # A task that came in by itself and waits for the user to close it isn't closed by a session at
    # all: the block goes on to apply_update, which turns the close away.
    if (st not in CLOSED_STATUSES or parse_card(card).get("status") not in OPEN_STATUSES
            or not open_ask_count(card) or intake_manual(card)):
        return block, None

    def closing(line):
        kv = update_lines(line)
        return bool(kv) and kv[0][0] == "status" and kv[0][1].lower() in CLOSED_STATUSES
    return "\n".join("status: waiting-on-me" if closing(l) else l for l in block.splitlines()), st


def close_ready(card, sid, held, turn_start):
    """A held close may happen at the end of this turn of the holding session: no ask is open, and
    every answer since the hold reached this session before the turn began (or needs nothing done)."""
    since = held.get("seq") or 0          # time_ns, like the asks log's seq: seconds can tie
    for a in read_asks(os.path.dirname(card)):
        if a.get("state") == "open":
            return False
        if a.get("state") == "moved" or a.get("via") == "session" or (a.get("seq") or 0) < since:
            continue
        if a.get("state") in ("drop", "archive"):
            continue
        if a.get("delivered") != sid or not turn_start or a["seq"] / 1e9 > turn_start:
            return False
    return True


def close_holder(tid):
    """The session holding a close on task `tid`, and its mark: (sid, held) or (None, None)."""
    for sid, e in load_state().items():
        h = e.get("held") if isinstance(e, dict) else None
        if isinstance(h, dict) and h.get("task") == tid:
            return sid, h
    return None, None


def release_close(card, via):
    """Close a card whose close was held: the held status, else None (nothing held, or an ask is
    open again). The caller has checked that the answers are in."""
    with card_lock(card):
        meta = parse_card(card)
        st = meta.get("closing")
        if st not in CLOSED_STATUSES or open_ask_count(card):
            return None
        _set_fields(card, {"status": st, "closing": None})
        append_log(card, f"status → {st} (auto, {via}): closed as the session said, now that its open questions are answered", touch=False)
        return st
