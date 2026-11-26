"""The text a bound session is given: the task protocol, its open asks and todos."""
import os

from .core import HQ_BIN, snoozed
from .sessions import PET_SESSIONS, session_alive
from .projects import INTAKE_MANUAL_DONE, load_project
from .asks import read_asks


# ---------------------------------------------------------------- protocol text
def protocol(meta):
    text = _protocol(meta)
    if meta.get("intake") and str(meta.get("intake_done") or "manual") != "auto":
        p = load_project(meta.get("project") or "")
        text += "\n" + INTAKE_MANUAL_DONE[(p or {}).get("lang") or "en"]
    return text


def _protocol(meta):
    return f"""This Claude Code session is bound to HQ task {meta['id']}: {meta.get('title','')}.
Task card: {meta['path']}
The card, not this conversation, is the source of truth. Rules:
1. Read the card before acting. Keep it current by ending your reply with an hq-update block;
   the Stop hook writes it to the card. Don't run `hq log/set/ref/addtodo/todo` or edit the card
   for this: each tool call is one more round trip over the whole conversation. Write only the
   lines that changed; todo / done / drop / log / ref / workdir may repeat:
```hq-update
status: active | waiting-on-me | blocked | done | abandoned
next: <the next concrete action>
state: <where it stands — replaces the card's status section; one `state:` per line>
todo: @owner <text>
done: <text of an open todo>
drop: <text of an open todo>
change: <text of an open todo> => <its new text>
log: <a decision and why>
ref: <short title> <full URL>
workdir: <absolute path you started working in>
project: <an existing project's name — only to move the task to it>
```
   owner: me = the user, claude, or a person's name. Anything the user has to DO (send, review,
   decide offline) is an `@me` todo; anything you need the user to ANSWER goes in an hq-asks
   block (rule 2). An @me todo is one step the user can do in one go: PRs to review and merge are
   one todo, installing is another. When it moves on (another PR joins, the wording is stale),
   rewrite it with `change:` instead of adding a near-copy: a new @me todo that repeats an open one
   is refused. Tick any todo, the user's too, with `done:` as soon as you see it done. An @claude
   todo is only for work this turn won't finish (waiting on CI, a merge, the user), never for what
   you are doing now. A turn that did work but changed nothing worth recording: a block holding
   just `touch`. The board shows a ref's title, not its URL. A link to one build, run or comment
   goes to the task's HISTORY.md; write `ref!:` instead of `ref:` for one the card must keep.
   When nothing left can move until someone else acts (a review, a merge, another team) — @me
   todos for afterwards included — write `status: blocked` and say in `next:` who or what it
   waits on; the todos stay @me todos.
2. When you need the user to decide, confirm or answer something before you can go on, end
   your reply with one self-contained question per line in this block (tracked until answered).
   Something the user has to DO — now, or after something else ("once the PRs merge, send the
   draft to Ping") — is not a question: add it as an `@me` todo on the card instead.
```hq-asks
- <question or request>
```
3. When the user answers tracked asks in chat, record each one (an answer given on the board,
   "[HQ board] …", is already recorded: don't write it again):
```hq-resolved
- <ask id> <do|drop|later|archive>: <short note>
```
   do = will do / how; drop = won't do; later = not now: the ask stays open, out of sight until
   tomorrow (`later until YYYY-MM-DD: …` for another day); archive = no context, parked. Never
   treat an unanswered ask as declined.
4. If the work drifts into a different task, say so and suggest `/task` for a new card."""


def answer_text(state, note):
    """How an answer reads to the session: yes / no / the user's own answer, not do / drop."""
    if state == "do" and note and note.startswith("made an @me todo"):
        return "the user made it an @me todo and will do it themselves — don't ask again" + note[len("made an @me todo"):].replace(" — the user will do it", "", 1)
    if state == "do":
        return f"answer: {note}" if note else "yes — go ahead as you suggested"
    if state == "drop":
        return "no" + (f": {note}" if note else "")
    return state + (f": {note}" if note else "")


def owned_elsewhere(a, sid, meta, state):
    """An ask raised by another session that is still on this task: its answer is that
    session's to act on. Several sessions can share a task; each must act only on its own
    answers, or two of them do the same work."""
    asker = a.get("session")
    if not asker or asker == sid:
        return False
    if (state.get(asker) or {}).get("task") != meta["id"]:
        return False          # it left the task — whoever is on it now takes the answer
    alive = session_alive(asker)
    if alive is None:
        # No record of it. With the pet installed that means it ended (the pet drops a dead
        # session's record); without the pet there is no telling, so it keeps its asks.
        return not os.path.isdir(PET_SESSIONS)
    return alive


def open_asks_text(meta, limit=10, sid=None, state=None):
    asks = [a for a in read_asks(meta["dir"]) if a["state"] == "open"]
    if not asks:
        return ""
    lines = [f"Open asks on {meta['id']} still waiting for the user ({len(asks)}):"]
    for a in asks[:limit]:
        theirs = sid is not None and owned_elsewhere(a, sid, meta, state or {})
        why = f": {a['later_note']}" if a.get("later_note") else ""
        later = f" (the user will answer this later{why} — carry on with what doesn't depend on it)" if snoozed(a) else ""
        lines.append(f"- {a['id']}{' (asked by another session on this task)' if theirs else ''}{later}: {a['text']}")
    if len(asks) > limit:
        lines.append(f"- … {len(asks) - limit} more (`{HQ_BIN} asks {meta['id']}`)")
    return "\n".join(lines)


CLAUDE_TODOS_MAX = 20          # items, and characters of todo text, a SessionStart list shows
CLAUDE_TODOS_CHARS = 2000


def claude_todos_text(meta, source=""):
    """The card's open @claude todos, for a session starting on it (fresh, resumed, cleared or just
    compacted): a session reads the card once, and after a compaction it forgets the list — so
    stale todos ("comment on PR X" after X merged) were never ticked. Each shows its text exactly
    as on the card, since `done:` / `drop:` match by that text. The newest CLAUDE_TODOS_MAX that
    fit in CLAUDE_TODOS_CHARS are shown, in card order; the rest are counted. Not repeated on every
    prompt: that would cost every turn."""
    items = [t for t in meta.get("todos", [])
             if t["state"] == "open" and (t.get("owner") or "").casefold() == "claude"]
    if not items:
        return ""
    shown, used = [], 0
    for t in reversed(items):
        if len(shown) >= CLAUDE_TODOS_MAX or (shown and used + len(t["text"]) > CLAUDE_TODOS_CHARS):
            break
        shown.append(t)
        used += len(t["text"])
    shown.reverse()
    why = " The conversation was just compacted: this list is the card's, not your memory of it." if source == "compact" else ""
    lines = [f"Open @claude todos on {meta['id']} ({len(items)}).{why} Check each against how things stand now "
             "(PR merged? cluster deleted? run finished?). In your next hq-update, tick finished ones with "
             "`done: <text>` and drop obsolete ones with `drop: <text>`, the text copied exactly as below:"]
    lines += [f"- {t['text']}" for t in shown]
    if len(shown) < len(items):
        lines.append(f"- … {len(items) - len(shown)} older ones not shown — see the card's todo section")
    return "\n".join(lines)


def me_todos_text(meta):
    """The card's open @me todos, for a session starting on it — so it updates one (`change:`)
    rather than writing a near-copy after a compaction, and ticks one it sees done. Same cap and
    order as the @claude list."""
    items = [t for t in meta.get("todos", []) if t["state"] == "open" and (t.get("owner") or "").casefold() == "me"]
    if not items:
        return ""
    shown, used = [], 0
    for t in reversed(items):
        if len(shown) >= CLAUDE_TODOS_MAX or (shown and used + len(t["text"]) > CLAUDE_TODOS_CHARS):
            break
        shown.append(t)
        used += len(t["text"])
    shown.reverse()
    lines = [f"Open @me todos on {meta['id']} ({len(items)}) — the user's. When one moves on, rewrite it with "
             "`change: <text> => <new text>` instead of adding another; tick one you see done with `done: <text>`, "
             "the text copied exactly as below:"]
    lines += [f"- {t['text']}" for t in shown]
    if len(shown) < len(items):
        lines.append(f"- … {len(items) - len(shown)} older ones not shown — see the card's todo section")
    return "\n".join(lines)
