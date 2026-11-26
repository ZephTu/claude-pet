"""The card budget: what a card sheds to HISTORY.md once it grows past its limits."""
import datetime as dt
import os
import re

from .core import atomic_write, card_lock, hq_root, load_json, today, TODO_RE
from .cards import _set_fields, LOG_ENTRY_RE, parse_frontmatter, root_config_path, todo_plain
from .refs import (
    GH_COMMENT_RE, GH_ITEM_RE, is_jenkins, JENKINS_BUILD_RE, JIRA_BROWSE_RE, JIRA_COMMENT_RE, JIRA_PATH_RE,
    JIRA_SELECTED_RE, key_marked, merge_refs, ref_key, REF_URL_RE, unmarked, URL_SPLIT_RE, URL_TAIL,
)


TICK_RE = re.compile(r"^todo #\d+ → (done|drop|open) \(([^)]*)\): (.*)$")


# ---------------------------------------------------------------- card budget
# Every session that starts on a task reads its card, so a card that grows like a diary costs every
# session on it. What no longer earns its place there moves to HISTORY.md next to the card —
# nothing is deleted, the board still shows all of it, and a session reads it only when it needs
# that history:
#   - closed todos past the CARD_KEEP_CLOSED most recently closed;
#   - todo ticks (`todo #3 → done (board): …`) — the todo list already says what is done; they are
#     written straight to HISTORY.md;
#   - log entries past the newest CARD_KEEP_LOG;
#   - process links (process_ref: a CI build, a run, a comment) unless written with the key mark.
# enforce_budget runs on every write to a card (set_fields), so a card stays within it.
HISTORY_FILE = "HISTORY.md"
HISTORY_SECTIONS = ("Links", "Todos", "Log")
CARD_KEEP_CLOSED = 5
CARD_KEEP_LOG = 20
LOG_SECTION_RE = re.compile(r"^##[ \t]*(?:Log|决策记录)\b", re.I)
GH_RUN_RE = re.compile(r"^/[^/?#]+/[^/?#]+/actions/runs/[0-9]+")


def process_patterns():
    """hq.json "process_links": more URL patterns (regexes) that count as process links."""
    cfg = load_json(root_config_path(), {}) if hq_root(required=False) else {}
    pats = cfg.get("process_links") if isinstance(cfg, dict) else None
    return [p for p in pats if isinstance(p, str) and p] if isinstance(pats, list) else []


def process_ref(ref, patterns=None):
    """A link to one step of the work rather than to the thing worked on: a Jenkins build, a GitHub
    Actions run, a comment on a PR or a Jira issue, or a URL matching hq.json "process_links". A
    ref with the key mark, without exactly one URL, or to anything else (a PR, an issue, a page) is
    a key link. Only hq decides this: the board shows the links where hq put them (card or HISTORY.md)."""
    if key_marked(ref):
        return False
    urls = REF_URL_RE.findall(str(ref))
    if len(urls) != 1:
        return False
    u = urls[0].rstrip(URL_TAIL)
    m = URL_SPLIT_RE.match(u)
    if not m:
        return False
    host, rest = m.group(2).lower(), m.group(3)
    if "github" in host and ((GH_ITEM_RE.match(rest) and GH_COMMENT_RE.search(rest)) or GH_RUN_RE.match(rest)):
        return True
    if JIRA_COMMENT_RE.search(rest) and (JIRA_BROWSE_RE.match(rest) or JIRA_PATH_RE.match(rest)
                                         or JIRA_SELECTED_RE.match(rest)):
        return True
    b = JENKINS_BUILD_RE.match(rest)
    if b and is_jenkins(host, b.group(2)):
        return True
    for p in process_patterns() if patterns is None else patterns:
        try:
            if re.search(p, u):
                return True
        except re.error:
            continue
    return False


def history_path(card):
    return os.path.join(os.path.dirname(card), HISTORY_FILE)


def read_history(card):
    """HISTORY.md as {section: [item, …]}: an item is a `- ` line with any lines under it. Under
    Todos every todo line is an item of its own, indented or not: a closed sub-todo moves alone."""
    out = {s: [] for s in HISTORY_SECTIONS}
    try:
        text = open(history_path(card), encoding="utf-8").read()
    except OSError:
        return out
    sec = None
    for line in text.split("\n"):
        h = re.match(r"^##\s+(\S+)", line)
        if h:
            sec = h.group(1) if h.group(1) in out else None
        elif sec and line.strip() and not line.lstrip().startswith("<!--"):
            if line.startswith("- ") or not out[sec] or (sec == "Todos" and TODO_RE.match(line)):
                out[sec].append(line)
            else:
                out[sec][-1] += "\n" + line
    return out


def _log_sort_key(item):
    x = LOG_ENTRY_RE.match(item.split("\n", 1)[0])
    return x.group(1).replace("T", " ") if x else ""


def write_history(card, h):
    tid = parse_frontmatter(open(card, encoding="utf-8").read())[0].get("id") or os.path.basename(os.path.dirname(card))
    parts = [f"# {tid} — history\n\n<!-- What no longer fits on TASK.md (the card budget): process links, closed "
             "todos, todo ticks, older log entries. hq moves them here; nothing is deleted. Oldest first. -->"]
    for s in HISTORY_SECTIONS:
        items = sorted(h.get(s, []), key=_log_sort_key) if s == "Log" else h.get(s, [])
        parts.append(f"## {s}\n" + "".join(i + "\n" for i in items))
    atomic_write(history_path(card), "\n\n".join(parts).rstrip("\n") + "\n")


def history_add(card, links=(), todos=(), log=()):
    """Adds to the card's HISTORY.md: links merged as refs are (one entry per link), the rest appended."""
    if not (links or todos or log):
        return
    with card_lock(card):
        h = read_history(card)
        if links:
            h["Links"] = ["- " + r for r in merge_refs([unmarked(x[2:]) for x in h["Links"]], [unmarked(r) for r in links])]
        h["Todos"] += list(todos)
        h["Log"] += list(log)
        write_history(card, h)


def history_drop_links(card, keys):
    """Takes links (by ref_key) out of HISTORY.md — one that moved onto the card, or was removed.
    Returns the entries taken out."""
    with card_lock(card):
        h = read_history(card)
        gone = [x for x in h["Links"] if ref_key(x[2:]) in keys]
        if gone:
            h["Links"] = [x for x in h["Links"] if x not in gone]
            write_history(card, h)
        return [x[2:] for x in gone]


def log_tick(card, msg):
    """A todo tick goes to HISTORY.md, not the card's log: the todo list shows what is done."""
    history_add(card, log=[f"- {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}: {msg}"])


def history_info(card):
    """What HISTORY.md holds: {"path", "links", "todos", "log"} counts, or None when there is none."""
    if not os.path.isfile(history_path(card)):
        return None
    h = read_history(card)
    return {"path": history_path(card), "links": len(h["Links"]), "todos": len(h["Todos"]), "log": len(h["Log"])}


def history_text(meta):
    """For a session starting on the task: where the older history is, and that it need not read it."""
    h = history_info(meta["path"])
    if not h or not (h["links"] or h["todos"] or h["log"]):
        return ""
    what = ", ".join(x for x in (f"{h['log']} older log entries and todo ticks" if h["log"] else "",
                                 f"{h['todos']} closed todos" if h["todos"] else "",
                                 f"{h['links']} process links (builds, runs, comments)" if h["links"] else "") if x)
    return (f"{meta['id']}'s history is in {h['path']}: {what}. It is not the current state — read it only "
            "when you need something from it.")


def enforce_budget(card):
    """Moves what is past the card budget (see above) from TASK.md to HISTORY.md. Returns the number
    of items moved."""
    with card_lock(card):
        text = open(card, encoding="utf-8").read()
        meta, body = parse_frontmatter(text)
        head = text[:len(text) - len(body)]
        lines = body.split("\n")
        hist = read_history(card)
        gone = set()
        to_todos, to_log = [], []
        # When each todo was last closed, from the tick records (HISTORY.md, or the card's log on a
        # card from before the budget). A todo closed with no record counts as closed long ago.
        # Ticks carry whole seconds, so ties go by the order the ticks were written in.
        closed_at = {}
        for seq, item in enumerate(hist["Log"] + lines):
            x = LOG_ENTRY_RE.match(item.split("\n", 1)[0])
            tick = TICK_RE.match(x.group(2)) if x else None
            if tick and tick.group(1) != "open":
                k = todo_plain(tick.group(3)).casefold()
                closed_at[k] = max(closed_at.get(k, ("", -1)), (x.group(1).replace("T", " "), seq))
        closed = []
        for i, line in enumerate(lines):
            t = TODO_RE.match(line)
            if t and t.group(2) != " " and t.group(3).strip() not in ("...", "…", ""):
                closed.append((closed_at.get(todo_plain(t.group(3)).casefold(), ("", -1)), i))
        closed.sort()
        for _, i in closed[:max(0, len(closed) - CARD_KEEP_CLOSED)]:
            gone.add(i)
            to_todos.append(lines[i])
        # The log: every tick, and the entries past the newest CARD_KEEP_LOG. An entry is its line
        # and the indented lines right under it.
        start = next((i for i, l in enumerate(lines) if LOG_SECTION_RE.match(l)), None)
        if start is not None:
            end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
            entries = []
            for i in range(start + 1, end):
                if LOG_ENTRY_RE.match(lines[i]):
                    entries.append([i])
                elif entries and entries[-1][-1] == i - 1 and lines[i][:1] in (" ", "\t") and lines[i].strip():
                    entries[-1].append(i)
            ticks = [e for e in entries if TICK_RE.match(LOG_ENTRY_RE.match(lines[e[0]]).group(2))]
            notes = [e for e in entries if e not in ticks]
            for e in sorted(ticks + notes[:max(0, len(notes) - CARD_KEEP_LOG)]):
                gone.update(e)
                to_log.append("\n".join(lines[i] for i in e))
        refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
        pats = process_patterns()
        to_links = [r for r in refs if process_ref(r, pats)]
        if not (gone or to_links):
            return 0
        history_add(card, links=to_links, todos=to_todos, log=to_log)   # first: a crash leaves a copy, never a loss
        if gone:
            atomic_write(card, head + "\n".join(l for i, l in enumerate(lines) if i not in gone))
        if to_links:
            _set_fields(card, {"refs": [r for r in refs if r not in to_links], "updated": meta.get("updated") or today()})
        return len(gone) + len(to_links)
