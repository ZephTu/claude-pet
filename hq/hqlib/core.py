"""hq core: paths and constants, small utilities, the card lock, and the hq-* blocks of a reply."""
import contextlib
import datetime as dt
from .compat import fcntl
import json
import os
import re
import sys
import time


HOME_DIR = os.path.expanduser("~/.claude/hq")
CONFIG = os.path.join(HOME_DIR, "config.json")
STATE = os.path.join(HOME_DIR, "state", "sessions.json")
HQ_BIN = os.path.join(HOME_DIR, "bin", "hq")
# This copy's own hq: bin/ sits next to hqlib/ (a checkout, or the installed copy).
HQ_EXE = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "hq")
if os.name == "nt":   # C:/Users/…/bin/hq: what Git Bash (Claude Code's shell) and python both take
    HQ_EXE = HQ_EXE.replace("\\", "/")

STATUSES = ["waiting-on-me", "blocked", "active", "done", "abandoned"]
OPEN_STATUSES = ["waiting-on-me", "blocked", "active"]
# The board names a status after the Focus column it puts a task in; `hq set` takes those names too.
STATUS_ALIASES = {"ready": "active", "needs-you": "waiting-on-me"}
RESOLUTIONS = {
    "do": "will do / here is how",
    "drop": "won't do",
    "later": "put off: the ask stays open, out of sight until tomorrow (or `later until <date>`)",
    "archive": "no context to answer — parked",
}
DEFAULT_CATEGORIES = ["feature", "bug", "investigation", "review", "ops", "docs", "other"]
# A category is written unquoted into card frontmatter, so keep it to a plain label.
CATEGORY_RE = re.compile(r"^[^\s#\"'\n:,\[\]][^#\"'\n:,\[\]]{0,39}$")
TODO_TIME_RE = re.compile(r"\s*<!--\s*t:([^>]+?)\s*-->\s*$")   # hidden creation time on a todo line
TODO_RE = re.compile(r"^(\s*)- \[([ xX\-])\] (.*)$")
HQ_KINDS = ("hq-asks", "hq-resolved", "hq-update")
# A template placeholder such as `<the next concrete action>` or `@owner <text>`: the protocol's own
# example, echoed back. Never a real value.
PLACEHOLDER_RE = re.compile(r"<[^<>\n]{1,80}>")
UPDATE_KEYS = ("status", "next", "state", "todo", "todo!", "done", "drop", "change", "log", "ref", "ref!", "workdir", "project", "touch")
WRITEBACK_MIN_TURN_SECONDS = 120
LOCK_DIR = os.path.join(HOME_DIR, "state", "locks")


# ---------------------------------------------------------------- hq blocks in a reply
def hq_blocks(text):
    """The hq-* fenced blocks of a reply: [{kind, body, start, end, trailing}].

    Read the way Markdown reads fences, line by line — not with one regex over the text, which
    took ```hq-update mentioned mid-sentence, a block quoted inside a ````markdown example, or a
    value holding ``` as a block (or cut a block short). A block counts only at top level, with
    its opening fence at the start of a line and its info string exactly the kind. `trailing`:
    nothing but blank lines and other hq blocks follows it — the end of the reply, where the
    protocol says bookkeeping goes."""
    lines = str(text).split("\n")
    blocks, i, n = [], 0, len(lines)
    while i < n:
        m = re.match(r"^( {0,3})(`{3,}|~{3,})(.*)$", lines[i])
        if not m or (m.group(2)[0] == "`" and "`" in m.group(3)):
            i += 1                      # not a fence (backtick info strings can't hold a backtick)
            continue
        fence, info = m.group(2), m.group(3).strip()
        j = i + 1
        while j < n:
            c = re.match(r"^ {0,3}(`{3,}|~{3,})\s*$", lines[j])
            if c and c.group(1)[0] == fence[0] and len(c.group(1)) >= len(fence):
                break
            j += 1
        if j < n and info in HQ_KINDS and not m.group(1) and fence[0] == "`":
            blocks.append({"kind": info, "body": "\n".join(lines[i + 1:j]), "start": i, "end": j})
        i = j + 1
    covered = {k for b in blocks for k in range(b["start"], b["end"] + 1)}
    for b in blocks:
        b["trailing"] = all(not lines[k].strip() or k in covered for k in range(b["end"] + 1, n))
    return blocks


def strip_hq_blocks(text, kinds=HQ_KINDS):
    """The reply without its hq blocks of these kinds — the gist a person reads."""
    lines = str(text).split("\n")
    drop = {k for b in hq_blocks(text) if b["kind"] in kinds for k in range(b["start"], b["end"] + 1)}
    return "\n".join(l for k, l in enumerate(lines) if k not in drop).strip()


def is_placeholder(value):
    """`<the next concrete action>`, `@owner <text>`, `<short title> <full URL>`: template, not data."""
    return bool(PLACEHOLDER_RE.search(value)) and not re.search(
        r"\w", re.sub(r"@\S+", "", PLACEHOLDER_RE.sub("", value)))


LIST_ITEM_RE = re.compile(r"^(?:[-*+]|\d+[.)])\s+")


def block_items(body):
    """The items of an hq-asks or hq-resolved block. With list items in it, each top-level `- ` /
    `* ` / `1.` line starts one, and every other line (options a) b) under a question, an indented
    second line) belongs to the item above it. With none, each line is an item. Placeholders out."""
    lines = [l.rstrip() for l in body.splitlines() if l.strip()]
    listed = any(LIST_ITEM_RE.match(l) for l in lines)
    items = []
    for l in lines:
        if listed and items and not LIST_ITEM_RE.match(l):
            items[-1] += "\n" + l
        elif listed:
            items.append(LIST_ITEM_RE.sub("", l, count=1).strip())
        else:
            items.append(re.sub(r"^\s*(?:[-*+]|\d+[.)]|[a-z][.)])\s*", "", l).strip())
    return [i for i in items if i and not is_placeholder(i)]


ASK_ID_RE = re.compile(r"T-\d+\.\d+\b")
# `until` takes a date only when one follows it: "drop until the API settles" is a note.
RESOLVED_RE = re.compile(r"(T-\d+\.\d+)\s+(do|drop|later|archive)\b(?:\s+until\s+(\d{4}-\d\d-\d\d"
                         r"(?:[T ]\d\d?:\d\d(?::\d\d)?)?(?:Z|[+-]\d\d:?\d\d)?)(?=[\s:]|$))?[:\s]*(.*)$", re.S)


def resolved_items(body):
    """The answers of an hq-resolved block: one a line — a line joins the one above only when it is
    indented and names no ask (a note's second line), never one that starts another answer."""
    items = []
    for l in (l.rstrip() for l in body.splitlines()):
        line = re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+", "", l).strip()
        if not line or is_placeholder(line):
            continue
        if items and l[:1].isspace() and not ASK_ID_RE.match(line):
            items[-1] += "\n" + line
        else:
            items.append(line)
    return items


# ---------------------------------------------------------------- card lock
_held = set()


@contextlib.contextmanager
def card_lock(card):
    """Hooks of several sessions and the board all rewrite TASK.md; each read-change-write holds
    this so one writer can't put back an old copy over another's change. Re-entrant within a
    process (apply_update holds it while calling the writers that take it too)."""
    key = os.path.basename(os.path.dirname(os.path.realpath(card))) or "card"
    if key in _held:
        yield
        return
    os.makedirs(LOCK_DIR, exist_ok=True)
    with open(os.path.join(LOCK_DIR, key + ".lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        _held.add(key)
        try:
            yield
        finally:
            _held.discard(key)
            fcntl.flock(f, fcntl.LOCK_UN)


def ok_workdir(path):
    """A directory a task may record as where its work happens: never /, home or the HQ root."""
    if os.name == "nt" and os.path.isdir(path) and os.path.dirname(os.path.realpath(path)) == os.path.realpath(path):
        return False   # a drive root, C:\ — Windows' /
    return (os.path.isdir(path) and os.path.realpath(path) not in
            ("/", os.path.realpath(hq_root()), os.path.realpath(os.path.expanduser("~"))))


# ---------------------------------------------------------------- utilities
def now_iso():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def gist(text, n=30):
    """The opening words of an ask — enough to match an answer to its question without
    repeating the whole question back into the session's prompt."""
    t = re.sub(r"\s+", " ", text or "").strip()
    return t if len(t) <= n else t[:n] + "…"


def today():
    return dt.date.today().isoformat()


def die(msg, code=1):
    print(f"hq: {msg}", file=sys.stderr)
    sys.exit(code)


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    # What tempfile.mkstemp does (a new file only this process opened, mode 0600), without
    # importing tempfile: that alone costs every hook several ms.
    while True:
        tmp = os.path.join(d, f".hq-{os.getpid()}-{time.time_ns()}")
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            continue
    # newline="\n": LF on Windows too, as every reader (the pet, the board, a Mac) expects.
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if os.name != "nt":
        os.replace(tmp, path)
        return
    # Windows refuses to replace a file another process has open (a hook or the board reading
    # it, a scanner): wait that out a while, as the pet's own writes do (Portable.replaceItem).
    for _ in range(100):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.02)
    try:
        os.replace(tmp, path)
    except OSError:
        os.remove(tmp)
        raise


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def hq_root(required=True):
    root = os.environ.get("HQ_ROOT") or load_json(CONFIG, {}).get("root")
    if root:
        root = os.path.expanduser(root)
    if required and (not root or not os.path.isdir(os.path.join(root, "tasks"))):
        die("no HQ configured — run hq/install.sh --root <dir> (or set HQ_ROOT)")
    return root


def tasks_dir():
    return os.path.join(hq_root(), "tasks")


def local_time(text):
    """A time as naive local datetime, from ISO with or without an offset (or a bare date); None
    if it isn't one. `snoozed_until` is kept in this form so Python, the board (JS) and the pet
    (Swift) all read it the same way."""
    try:
        t = dt.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.astimezone().replace(tzinfo=None) if t.tzinfo else t


def snoozed(a, now=None):
    """An open ask the user put off with "Later", still before the time it comes back."""
    until = local_time(a.get("snoozed_until")) if a.get("snoozed_until") else None
    return bool(until) and until > (now or dt.datetime.now())


def slugify(s):
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return s[:40] or "task"


def clip(s, n=160):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[:n] + "…"


SITE_SERVICES = ("jira", "jenkins")


def find_claude(given=None):
    """The claude CLI to run: the one given, else on PATH, else where its installers put it."""
    if given:
        return given
    import shutil
    home = os.path.expanduser("~")
    found = [shutil.which("claude"), f"{home}/.local/bin/claude", f"{home}/.claude/local/claude",
             "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if os.name == "nt":   # the native installer's claude.exe (os.access says yes to any file there)
        found = [shutil.which("claude"), os.path.join(home, ".local", "bin", "claude.exe")]
    for c in found:
        if c and os.access(c, os.X_OK):
            return c
    return None


def update_lines(block):
    """The lines of an hq-update block as (key, value), with list markers and blank lines dropped.
    Forgiving where a model writing in Chinese or quoting values would otherwise lose a round
    trip: a full-width colon, any case in the key, and one pair of quotes round the value."""
    out = []
    for raw in block.splitlines():
        line = re.sub(r"^\s*(?:[-*]|\d+[.)])\s+", "", raw).strip()
        if not line:
            continue
        m = re.match(r"^([A-Za-z]+[!！]?)\s*(?:[:：]\s*(.*))?$", line)
        if not m:
            out.append((None, line))
            continue
        v = (m.group(2) or "").strip()
        for a, b in ('""', "''", "“”", "‘’", "「」", "``"):
            if len(v) >= 2 and v[0] == a and v[-1] == b:
                v = v[1:-1].strip()
                break
        out.append((m.group(1).lower().replace("！", "!"), v))
    return out


def ts_seconds(ts):
    try:
        return dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def one_line(s, n=100):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[:n - 1] + "…"


def local_dt(ts):
    """A transcript / ask / todo time as an aware local datetime, or None."""
    if ts is None:
        return None
    if isinstance(ts, (int, float)):
        return dt.datetime.fromtimestamp(ts).astimezone()
    try:
        t = dt.datetime.fromisoformat(str(ts).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.astimezone() if t.tzinfo else t.astimezone()   # naive = local


def iso(t):
    return t.isoformat(timespec="seconds") if t else None
