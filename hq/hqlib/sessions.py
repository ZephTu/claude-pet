"""Session bindings (state/sessions.json), the pet's live-session files, and the replies saved for asks."""
import contextlib
from .compat import fcntl, win_pid_alive
import json
import os
import time

from .core import atomic_write, HOME_DIR, load_json, now_iso, STATE, strip_hq_blocks


# ---------------------------------------------------------------- session state
def load_state():
    return load_json(STATE, {})


def save_state(state):
    atomic_write(STATE, json.dumps(state, ensure_ascii=False, indent=1))


@contextlib.contextmanager
def state_lock():
    """Every session's hooks and the board write sessions.json; each read-change-write holds
    this lock so one writer can't put back an old copy over another's change."""
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def update_session(sid, change):
    """Apply change(entry) to this session's entry as it is now on disk (skipped if unbound)."""
    with state_lock():
        state = load_state()
        if sid in state:
            change(state[sid])
            save_state(state)


def bound_task(session):
    s = load_state().get(session or "")
    return s.get("task") if s else None


def session_id(arg=None):
    return arg or os.environ.get("CLAUDE_CODE_SESSION_ID") or ""


def session_alive(sid):
    """True / False from the pet's record of that session, None when there is no record to go by
    (the pet isn't installed, or never saw it)."""
    d = load_json(os.path.join(PET_SESSIONS, f"{sid}.json"), None) if sid else None
    if not isinstance(d, dict):
        return None
    return pid_alive(d.get("pid"))


# Claude Pet's file per live session: its pid, and what it is doing.
PET_SESSIONS = os.path.expanduser("~/.claude/pet/sessions")


def pid_alive(pid):
    if win_pid_alive:
        return win_pid_alive(pid)
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (TypeError, ValueError):
        return False
    return True


LAST_REPLY_MAX = 6000   # as much as an ask keeps of the reply that raised it
REPLIES = os.path.join(HOME_DIR, "state", "replies")   # <session id>.json: its last turn's reply
REPLIES_KEEP_DAYS = 14


def save_reply(sid, text):
    """At a bound session's Stop: what its turn ended on, for the board to show while the next turn
    runs — by then the reply may sit megabytes back in the transcript, under the turn's screenshots
    and tool output, too far for a poll every few seconds to read. A reply holding only HQ's blocks
    keeps the one before it. Files untouched for REPLIES_KEEP_DAYS go (their sessions are long over)."""
    t = strip_hq_blocks(text or "").strip()
    if not sid or not t or "/" in sid:
        return
    os.makedirs(REPLIES, exist_ok=True)
    old = time.time() - REPLIES_KEEP_DAYS * 86400
    for name in os.listdir(REPLIES):
        try:
            if os.path.getmtime(os.path.join(REPLIES, name)) < old:
                os.remove(os.path.join(REPLIES, name))
        except OSError:
            pass
    atomic_write(os.path.join(REPLIES, sid + ".json"),
                 json.dumps({"text": t[:LAST_REPLY_MAX], "ts": now_iso()}, ensure_ascii=False))


def saved_reply(sid):
    d = load_json(os.path.join(REPLIES, sid + ".json"), None) if sid and "/" not in sid else None
    return d if isinstance(d, dict) and d.get("text") else None
