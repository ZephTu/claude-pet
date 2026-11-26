"""The Claude Code hooks: SessionStart, UserPromptSubmit and Stop."""
import contextlib
import io
import json
import os
import re
import sys
import time

from .core import (
    block_items, gist, hq_blocks, now_iso, OPEN_STATUSES, resolved_items, RESOLVED_RE,
    WRITEBACK_MIN_TURN_SECONDS,
)
from .sessions import load_state, save_reply, update_session


# ---------------------------------------------------------------- hooks
def last_assistant_text(payload):
    t = payload.get("last_assistant_message")
    if isinstance(t, str) and t.strip():
        return t
    path = payload.get("transcript_path")
    if not path or not os.path.exists(path):
        return ""
    # Read the tail only; transcripts can be large.
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 400_000))
        tail = f.read().decode("utf-8", "ignore").splitlines()
    for line in reversed(tail):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("type") == "user" and not o.get("isMeta") and not o.get("isSidechain"):
            c = o.get("message", {}).get("content")
            if isinstance(c, str) or (isinstance(c, list) and any(
                    isinstance(x, dict) and x.get("type") == "text" for x in c)):
                return ""  # reached the user's prompt without finding a reply
        if o.get("type") == "assistant" and not o.get("isSidechain"):
            parts = [x.get("text", "") for x in o.get("message", {}).get("content", [])
                     if isinstance(x, dict) and x.get("type") == "text"]
            if any(p.strip() for p in parts):
                return "\n".join(parts)
    return ""


def update_problems_text(meta, problems):
    return (f"HQ: your hq-update block was NOT applied to {meta['id']} — nothing in it was written:\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\nReply with just the whole hq-update block again, corrected.")


def resolved_problems_text(problems):
    return ("HQ: these lines of your hq-resolved block were NOT recorded (the others were):\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\nReply with an hq-resolved block holding just those, corrected — each line "
              "`<ask id> <do|drop|later|archive>: <short note>` (`later until YYYY-MM-DD: …` for another day). "
              "Leave out any ask already answered: there is nothing to correct.")


# ---------------------------------------------------------------- the Stop hook's echo
# One line to the user after each turn of a bound session (a systemMessage: the session doesn't
# see it): what HQ wrote on the card, and what it refused or dropped — which used to reach only the
# session, or nobody.
ECHO_WORDS = {
    "zh": {"next": "next", "state": "state", "todo": "+{n} todo", "done": "{n} 条 todo 完成",
           "drop": "{n} 条 todo 不做", "change": "{n} 条 todo 改写", "log": "+{n} log", "ref": "+{n} ref",
           "ref_updated": "{n} 条 ref 更新", "workdir": "+{n} workdir", "project": "换了项目", "sep": "，", "status": "状态 {a} → {b}",
           "asked": "ask {ids}", "answered": "记下回答 {ids}", "touch": "卡片没有新内容",
           "held": "{s} 暂缓：等 {n} 个问题答完", "refused": "hq-update 没写进卡片：{why}", "more": "（共 {n} 处）",
           "unresolved": "{n} 条回答没记上：{why}", "stale": "这轮做了事但卡片没更新",
           "back": "（已让 session 重写）", "later": "（下一轮告诉 session）", "nudged": "（已提醒 session）",
           "not_end": "hq-update 块不在回复末尾，当成了示例", "lead": "HQ {id}："},
    "en": {"next": "next", "state": "state", "todo": "+{n} todo", "done": "{n} todo done",
           "drop": "{n} todo dropped", "change": "{n} todo reworded", "log": "+{n} log", "ref": "+{n} ref",
           "ref_updated": "{n} ref updated", "workdir": "+{n} workdir", "project": "moved project", "sep": ", ", "status": "status {a} → {b}",
           "asked": "ask {ids}", "answered": "answer {ids} recorded", "touch": "nothing new on the card",
           "held": "{s} held: waiting on {n} question(s)", "refused": "hq-update NOT applied: {why}", "more": " ({n} problems)",
           "unresolved": "{n} answer(s) NOT recorded: {why}", "stale": "this turn did work but the card wasn't updated",
           "back": " (sent back to the session)", "later": " (the session hears at its next prompt)",
           "nudged": " (the session was nudged)",
           "not_end": "the hq-update block isn't at the end of the reply, so it was taken for an example",
           "lead": "HQ {id}: "},
}
ECHO_ORDER = ("next", "state", "todo", "done", "drop", "change", "log", "ref", "ref_updated", "workdir", "project")


def echo_lang(meta):
    """The project's language (its PROJECT.md headings); for a task with none, the card's own."""
    from .projects import load_project
    p = load_project(meta.get("project") or "")
    if p:
        return p["lang"]
    return "zh" if re.search(r"^## .*[\u4e00-\u9fff]", meta.get("body") or "", re.M) else "en"


def safe_echo(meta, **kw):
    """turn_echo, never raising: it is only shown, and runs before the hook's real output."""
    try:
        return turn_echo(meta, echo_lang(meta), **kw)
    except Exception as e:  # noqa: BLE001
        print(f"hq hook: echo: {type(e).__name__}: {e}", file=sys.stderr)
        return ""


def echo_problem(p, w, n=100):
    """A problem as the user reads it: the not-at-the-end one in their words, any other cut short."""
    if p.startswith("the hq-update block is not at the end"):
        return w["not_end"]
    p = " ".join(p.split())
    return p if len(p) <= n else p[:n - 1] + "…"


def turn_echo(meta, lang, *, had_blocks, status=None, wrote=None, held=None, asked=(), answered=(),
              problems=(), unresolved=(), stale=False, sent_back=False):
    """The echo line, or "" when the turn wrote nothing and nothing went wrong."""
    from .asks import open_ask_count
    w = ECHO_WORDS.get(lang) or ECHO_WORDS["en"]
    fail = w["later"] if not sent_back else w["back"]
    parts = []
    if status and status[0] != status[1]:
        parts.append(w["status"].format(a=status[0] or "-", b=status[1] or "-"))
    if held:
        parts.append(w["held"].format(s=held, n=open_ask_count(meta["path"])))
    for k in ECHO_ORDER:
        if (wrote or {}).get(k):
            parts.append(w[k].format(n=wrote[k]))
    if asked:
        parts.append(w["asked"].format(ids=" ".join(asked)))
    if answered:
        parts.append(w["answered"].format(ids=" ".join(answered)))
    bad = []
    if problems:
        bad.append(w["refused"].format(why=echo_problem(problems[0], w))
                   + (w["more"].format(n=len(problems)) if len(problems) > 1 else "") + fail)
    if unresolved:
        bad.append(w["unresolved"].format(n=len(unresolved), why=echo_problem(unresolved[0], w)) + fail)
    if stale:
        bad.append(w["stale"] + w["nudged"])
    if not parts and not bad:
        if not had_blocks:
            return ""
        parts.append(w["touch"])
    return w["lead"].format(id=meta["id"]) + w["sep"].join(parts + bad)


def emit(event, context):
    if context:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                                                 "additionalContext": context}}, ensure_ascii=False))


def hook_main():
    # A hook that fails shows an error in every session bound to that task, each turn: never.
    try:
        _hook_main()
    except Exception as e:  # noqa: BLE001 — SystemExit (die) still passes
        print(f"hq hook: {type(e).__name__}: {e}", file=sys.stderr)


def _hook_main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if os.environ.get("HQ_HOOK_CHILD"):
        return
    sid = payload.get("session_id", "")
    event = payload.get("hook_event_name", "")
    state = load_state()
    s = state.get(sid)
    if not s:
        return  # unbound sessions cost one small JSON read and nothing else
    # Only a bound session's hook loads the rest of hq.
    from .cards import find_card, parse_card
    from .history import history_text
    from .projects import brief_hash, session_context_text
    from .asks import (
        add_ask, answered_as, append_event, await_answer, close_ready, CLOSED_STATUSES, current_ask, read_asks, release_close,
        resolve_ask, settle_status, snooze_until,
    )
    from .protocol import answer_text, claude_todos_text, me_todos_text, open_asks_text, owned_elsewhere, protocol
    from .update import apply_update
    try:
        card = find_card(s["task"])
    except SystemExit:
        return
    meta = parse_card(card)

    if event == "SessionStart":
        # Every source — startup, resume, clear, compact — gets the open @claude todos: after a
        # compaction or /clear the session no longer remembers them.
        brief = session_context_text(meta)

        def note_start(e):
            e.update(announced=True, brief=brief_hash(brief))
            for k in ("grants", "grants_task"):     # what retired standing grants kept
                e.pop(k, None)
        update_session(sid, note_start)
        parts = [protocol(meta), brief, history_text(meta), open_asks_text(meta, sid=sid, state=state),
                 me_todos_text(meta), claude_todos_text(meta, payload.get("source") or "")]
        emit(event, "\n\n".join(p for p in parts if p))

    elif event == "UserPromptSubmit":
        turn_start = time.time()
        lines = []
        brief = session_context_text(meta)
        if not s.get("announced", True):
            # Once, in place of the SessionStart this session had before it was bound.
            moved = s.get("continued_from")
            lines.append((f"The task this session was on, {moved}, was continued in {meta['id']}: this session is now "
                          f"bound to {meta['id']}. Its card carries {moved}'s open todos, state and key links"
                          + (lambda m: f"; its open asks moved too ({m})." if m else ".")(", ".join(
                              f"{a['moved_from']} is now {a['id']}" for a in read_asks(meta["dir"])
                              if a.get("moved_from") and a["state"] == "open"))
                          if moved else "The user bound this session to an HQ task from the board.") + "\n" + protocol(meta))
            if brief:
                lines.append(brief)
            h = history_text(meta)
            if h:
                lines.append(h)
            for todos in (me_todos_text(meta), claude_todos_text(meta)):
                if todos:
                    lines.append(todos)
        elif brief_hash(brief) != (s.get("brief") or "") and (brief or s.get("brief")):
            # The project's brief or the user's preferences changed, or the task moved to another
            # project (or none): once.
            lines.append(f"Context for {meta['id']}, new or changed since you last saw it:\n{brief}" if brief else
                         f"{meta['id']} no longer has a project brief or user preferences: what the earlier ones said "
                         "no longer applies.")
        if s.get("update_problems"):
            lines.append(update_problems_text(meta, s["update_problems"]))
        if s.get("resolved_problems"):
            lines.append(resolved_problems_text(s["resolved_problems"]))
        # An answer goes to the session that asked, once. Another session on the same task
        # doesn't get it — it would act on it too. Only when the asker has left the task (or
        # ended) does the next session on it take the answer over.
        # (`delivered` in sessions.json is the older record; still honoured.)
        legacy = set().union(*(set(e.get("delivered", [])) for e in state.values() if isinstance(e, dict)))
        fresh = [a for a in read_asks(meta["dir"])
                 if a["state"] != "open" and a.get("via") == "board" and not a.get("delivered")
                 and a["id"] not in legacy and not owned_elsewhere(a, sid, meta, state)]
        for a in fresh:
            append_event(meta["dir"], {"type": "delivered", "id": a["id"], "session": sid})
        if fresh:
            lines.append("The user answered these asks on the HQ board since your last turn:")
            for a in fresh:
                lines.append(f"- {a['id']} \"{gist(a['text'])}\" → {answer_text(a['state'], a.get('note'))}")
        told = {a["id"] for a in fresh}

        def note_turn(entry):
            entry.update(turn_start=turn_start, announced=True, brief=brief_hash(brief))
            for k in ("update_problems", "resolved_problems", "grants", "grants_task"):  # the last two: retired standing grants
                entry.pop(k, None)
            entry.pop("continued_from", None)
            entry.pop("finished", None)   # talked to again after finishing its task: not to be stopped
            entry["delivered"] = sorted(set(entry.get("delivered", [])) | told)
        update_session(sid, note_turn)
        t = open_asks_text(meta, sid=sid, state=state)
        if t:
            lines.append(t)
        emit(event, "\n".join(lines))

    elif event == "Stop":
        text = last_assistant_text(payload)
        try:
            save_reply(sid, text)
        except OSError as e:   # a full disk must not cost the reply its hq-update and asks
            print(f"hq hook: saving the reply: {e}", file=sys.stderr)
        problems, unresolved = [], []   # the hq-update's problems; hq-resolved lines not recorded
        blocks = hq_blocks(text)
        updates = [b for b in blocks if b["kind"] == "hq-update"]
        if len(updates) == 1 and not updates[0]["trailing"]:
            # A block with text after it reads as an example — but the reply's only one was more
            # likely its bookkeeping put in the wrong place. Say so rather than drop it.
            problems.append("the hq-update block is not at the end of the reply (text follows it), so it was "
                            "taken for an example; bookkeeping goes last, after everything else. If it was only "
                            "an example, reply with an hq-update block holding just `touch`")
        # A status the reply wrote itself (and that was applied) wins over the automatic moves,
        # which are made once, after all its blocks.
        status_said = me_ticked = False
        asked_before = {a["id"] for a in read_asks(meta["dir"])}
        asked, resolved = False, set()   # resolved: the cards whose asks this reply answered
        new_asks, answered, wrote, held_now = [], [], {}, None   # for the echo
        status_before = meta.get("status")

        def finished(after):
            # This session finished its task: say so on its entry, for the board to treat like a
            # task finished there (its "Finishing a task" setting: ask, stop, keep). The next
            # prompt to it takes the mark away: you are still talking to it.
            update_session(sid, lambda e: e.update(finished={"task": meta["id"], "status": after, "at": now_iso()}))

        # Questions and answers first, the hq-update after: whether the reply may close its task
        # depends on what is still open once its own asks and answers are in.
        for b in sorted(blocks, key=lambda b: b["kind"] == "hq-update"):
            if b["kind"] == "hq-update":
                # Only at the end of the reply: one quoted or shown mid-reply is an example.
                if b["trailing"]:
                    change = {}
                    bad = apply_update(card, b["body"], change=change, settle=False, hold=True)
                    problems += bad
                    for k, n in (change.get("wrote") or {}).items():
                        wrote[k] = wrote.get(k, 0) + n
                    status_said |= bool(change.get("status"))
                    me_ticked |= bool(change.get("me_ticked"))
                    after, held = change.get("to"), change.get("held")
                    if held:
                        held_now = held
                        hold = {"task": meta["id"], "status": held, "at": now_iso(), "seq": time.time_ns()}
                        update_session(sid, lambda e: e.update(held=hold))
                    elif not bad and change.get("status"):
                        update_session(sid, lambda e: e.pop("held", None))   # said outright: nothing held
                    if not bad and change.get("from") in OPEN_STATUSES and after in CLOSED_STATUSES:
                        finished(after)
                continue
            for item in (block_items if b["kind"] == "hq-asks" else resolved_items)(b["body"]):
                if b["kind"] == "hq-asks":
                    aid = add_ask(card, item, sid, context=text)
                    if aid not in asked_before and aid not in new_asks:
                        asked = True
                        new_asks.append(aid)
                    continue
                m = RESOLVED_RE.match(item)
                first = item.split("\n", 1)[0]
                if not m:
                    unresolved.append(f"`{first}` — not `<ask id> <do|drop|later|archive>: <short note>`")
                    continue
                aid, res, until, note = m.groups()
                if until and res != "later":
                    unresolved.append(f"`{first}` — only later takes `until <date>`")
                    continue
                if res == "later" and not until and re.match(r"until\b", note):
                    # Meant as a date: put off till tomorrow instead, it would come back on the wrong day.
                    unresolved.append(f"`{first}` — `{note.split(':')[0].strip()}` is not a date like 2026-11-22 or 2026-11-22T09:00")
                    continue
                if until and snooze_until(until) is None:
                    unresolved.append(f"`{first}` — `until {until}` is not a date like 2026-11-22")
                    continue
                try:
                    with contextlib.redirect_stderr(io.StringIO()):
                        acard = find_card(aid.rsplit(".", 1)[0])
                except SystemExit:
                    acard = None
                ask = next((a for a in read_asks(os.path.dirname(acard)) if a["id"] == aid), None) if acard else None
                if not ask:
                    unresolved.append(f"`{first}` — there is no ask {aid}")
                    continue
                if ask["state"] == "moved":
                    # Continued to another card: the ask as it is there now (current_ask).
                    try:
                        with contextlib.redirect_stderr(io.StringIO()):
                            ncard, nid = current_ask(aid)
                        ask = next((a for a in read_asks(os.path.dirname(ncard)) if a["id"] == nid), ask)
                    except SystemExit:
                        pass
                    shown = f"{aid} (now {ask['id']})" if ask["id"] != aid else aid
                else:
                    shown = aid
                if res == "later" and ask["state"] not in ("open", "moved"):
                    unresolved.append(f"`{first}` — {shown} is already answered ({ask['state']}); nothing to put off")
                    continue
                if ask["state"] not in ("open", "moved"):
                    unresolved.append(f"`{first}` — {shown} is already answered ({answered_as(ask)}), "
                                      "on the board or earlier: that answer stands, leave this line out")
                    continue
                try:
                    with contextlib.redirect_stderr(io.StringIO()) as err:
                        resolve_ask(aid, res, note.strip(), via="session", settle=False, until=until)
                        resolved.add(current_ask(aid)[0])
                        answered.append(f"{aid} ({res})")
                except SystemExit:
                    unresolved.append(f"`{first}` — {err.getvalue().strip().removeprefix('hq: ') or 'could not be recorded'}")
        # A new question with no status written: the task now waits on the user. Answers recorded
        # with no status written: it stops waiting once nothing is left on the user.
        released = False
        held = (load_state().get(sid) or {}).get("held")
        if not status_said and isinstance(held, dict) and held.get("task") == meta["id"]:
            # Its close was held for questions: released once their answers reached this session.
            if not parse_card(card).get("closing"):
                released = None      # a status was set outright since: the hold is gone
            elif close_ready(card, sid, held, s.get("turn_start")):
                released = release_close(card, "session")
            if released is not False:
                update_session(sid, lambda e: e.pop("held", None))
            if released:
                finished(released)
        if not released and not status_said:
            if asked:
                await_answer(card, "session", new_ask=True)
            elif me_ticked or card in resolved:
                settle_status(card, "session")
        for c in resolved - {card}:
            settle_status(c, "session")
        echo = dict(had_blocks=any(b["kind"] != "hq-update" or b["trailing"] for b in blocks), status=(status_before, parse_card(card).get("status")), wrote=wrote,
                    held=held_now, asked=new_asks, answered=answered, problems=problems, unresolved=unresolved)
        if payload.get("stop_hook_active"):
            # One nudge per turn, never a loop. Another Stop hook may have sent the turn back
            # before this one could: tell the session at its next prompt instead of never.
            if problems:
                update_session(sid, lambda e: e.update(update_problems=problems))
            if unresolved:
                update_session(sid, lambda e: e.update(resolved_problems=unresolved))
            line = safe_echo(meta, **echo)
            if line:
                print(json.dumps({"systemMessage": line}, ensure_ascii=False))
            return
        reasons = []
        if problems:
            reasons.append(update_problems_text(meta, problems))
        if unresolved:
            reasons.append(resolved_problems_text(unresolved))
        # Write-back guard: a long turn that never touched the card gets one nudge.
        start = s.get("turn_start")
        stale = (not problems and start and time.time() - start > WRITEBACK_MIN_TURN_SECONDS
                 and os.path.getmtime(card) < start)
        if stale:
            reasons.append(f"HQ: this turn did work on {meta['id']} but the task card was not updated. "
                           "Reply with just an hq-update block (status / next / state / todo / done / log …; "
                           "a block holding only `touch` if nothing changed), then finish.")
        out = {}
        line = safe_echo(meta, stale=bool(stale), sent_back=True, **echo)
        if line:
            out["systemMessage"] = line
        if reasons:
            out.update(decision="block", reason="\n\n".join(reasons))
        if out:
            print(json.dumps(out, ensure_ascii=False))


def cmd_hook(args):
    hook_main()
