"""Task cards: reading and writing TASK.md, todos, retired categories, the Focus list, new cards."""
import datetime as dt
import json
import os
import re
import sys

from .core import (
    atomic_write, card_lock, CATEGORY_RE, DEFAULT_CATEGORIES, die, hq_root, is_placeholder, load_json,
    now_iso, tasks_dir, today, TODO_RE, TODO_TIME_RE,
)


# ---------------------------------------------------------------- task cards
def parse_frontmatter(text):
    """(fields, body) of a card or PROJECT.md: the `---` block's `key: value` lines, values
    unquoted, `[...]` read as JSON lists, template `# comments` dropped."""
    meta = {}
    m = re.match(r"^---\n(.*?)\n---\n?", text, re.S)
    body = text[m.end():] if m else text
    if m:
        for line in m.group(1).splitlines():
            if ":" not in line or line.lstrip().startswith("#"):
                continue
            k, v = line.split(":", 1)
            v = v.strip()
            if v.startswith('"'):
                v = v[1:v.rfind('"')] if v.count('"') >= 2 else v[1:]
            else:
                v = "" if v.startswith("#") else re.sub(r"\s{2,}#\s.*$", "", v).strip()  # template comments
                if v.startswith("[") and v.endswith("]"):
                    try:
                        v = json.loads(v)
                    except ValueError:
                        pass
            meta[k.strip()] = v
    return meta, body


def todo_fields(t):
    """A TODO_RE match as {"state", "owner", "text", "created"}."""
    txt = t.group(3).strip()
    created = None
    c = TODO_TIME_RE.search(txt)
    if c:
        created, txt = c.group(1), txt[:c.start()].rstrip()
    owner = None
    o = re.match(r"@(\S+)\s+(.*)$", txt)
    if o:
        owner, txt = o.group(1), o.group(2)
        if owner.casefold() in ("me", "claude"):   # @Claude is Claude's, @Me is yours
            owner = owner.casefold()
    return {"state": {"x": "done", "-": "dropped", " ": "open"}[t.group(2).lower()],
            "owner": owner, "text": txt, "created": created}


def parse_card(path):
    meta, body = parse_frontmatter(open(path, encoding="utf-8").read())
    todos = []
    n = 0                       # every todo line counts, as `hq todo <index>` counts them
    for line in body.splitlines():
        t = TODO_RE.match(line)
        if not t:
            continue
        n += 1
        # A template's placeholder ("- [ ] ...") is not a todo; keep its number, don't list it.
        if t.group(3).strip() in ("...", "…", ""):
            continue
        todos.append(dict({"i": n}, **todo_fields(t)))
    meta["todos"] = todos
    meta["body"] = body.strip()
    meta["path"] = path
    meta["dir"] = os.path.dirname(path)
    return meta


def card_paths():
    td = tasks_dir()
    out = []
    for d in sorted(os.listdir(td)):
        p = os.path.join(td, d, "TASK.md")
        if os.path.isfile(p):
            out.append(p)
    return out


def find_card(tid):
    tid = tid.upper() if re.match(r"^t-\d+$", tid, re.I) else tid
    for p in card_paths():
        d = os.path.basename(os.path.dirname(p))
        if d == tid or d.startswith(tid + "-"):
            return p
    die(f"no task {tid}")


def set_fields(path, fields):
    from .history import enforce_budget
    with card_lock(path):
        _set_fields(path, fields)
        if os.path.basename(path) == "TASK.md":
            enforce_budget(path)        # every writer ends here: the card stays within its budget


def _set_fields(path, fields):
    """Set frontmatter fields — only inside the `---` block (one is added when the file has
    none), so a body line that happens to start with `status:` is never touched. Values are one
    line: a newline in one could otherwise write new lines, even a section, into the file."""
    text = open(path, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n?", text, re.S)
    fm, body = (m.group(1), text[m.end():]) if m else ("", text)
    fields = dict(fields)
    if fields.get("status") in ("done", "abandoned") and "closed" not in fields:
        # When it was closed — `updated` moves with every later log line or edit.
        old = re.search(r"^status:[ \t]*(\S*)", fm, re.M)
        if not old or old.group(1) != fields["status"]:
            fields["closed"] = today()
            # The moment too, for ordering finished tasks (last_active); `closed` stays a date
            # for everything that reads it as one.
            fields["closed_at"] = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    for k, v in fields.items():
        if v is None:
            # None takes the field out.
            fm = re.sub(rf"^{re.escape(k)}:.*(?:\n|$)", "", fm, flags=re.M).rstrip("\n")
            continue
        if isinstance(v, list):
            val = json.dumps(v, ensure_ascii=False)
        else:
            val = re.sub(r"[ \t]*[\r\n]+[ \t]*", " ", str(v)).strip()
            if k in ("waiting_on_me", "next", "title"):
                val = '"' + val.replace('"', "'") + '"'
        if re.search(rf"^{re.escape(k)}:", fm, re.M):
            fm = re.sub(rf"^{re.escape(k)}:.*$", lambda _: f"{k}: {val}", fm, count=1, flags=re.M)
        else:
            fm = (fm + "\n" if fm else "") + f"{k}: {val}"
    if "updated" not in fields:
        fm = re.sub(r"^updated:.*$", f"updated: {today()}", fm, count=1, flags=re.M)
    atomic_write(path, f"---\n{fm}\n---\n" + body)


def append_log(path, msg, touch=True):
    with card_lock(path):
        text = open(path, encoding="utf-8").read().rstrip("\n")
        if os.path.basename(path) == "PROJECT.md":
            text = with_log_heading(text)
        # Local date and time to the second: a task's log often has many entries in one day.
        line = f"- {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}: {msg}"
        text += "\n" + line + "\n"
        atomic_write(path, text)
        if touch:
            set_fields(path, {})
        return line


def with_log_heading(text):
    """A PROJECT.md whose last section is not its Log gets one (in the file's language) before a
    log line is added at the end — else the line would land in its Done when, Templates or an old
    Grants section."""
    from .projects import is_grants_heading, project_spans
    lines = text.split("\n")
    spans = project_spans(lines)
    last = max((a, k) for k, ss in spans.items() for a, _ in ss) if spans else None
    if last and last[1] == "" and not is_grants_heading(lines[last[0]]):
        return text
    zh = any(re.search(r"[\u4e00-\u9fff]", l) for l in lines if l.startswith("## "))
    return text + "\n\n## " + ("决策记录" if zh else "Log")


# ---------------------------------------------------------------- categories
def root_config_path():
    return os.path.join(hq_root(), "hq.json")


def load_categories():
    cfg = load_json(root_config_path(), None)
    if not isinstance(cfg, dict) or not isinstance(cfg.get("categories"), list):
        return list(DEFAULT_CATEGORIES)
    return [c for c in cfg["categories"] if isinstance(c, str) and c]


def save_categories(cats):
    cfg = load_json(root_config_path(), {})
    if not isinstance(cfg, dict):
        cfg = {}
    cfg["categories"] = cats
    atomic_write(root_config_path(), json.dumps(cfg, ensure_ascii=False, indent=1) + "\n")


def check_category(name):
    name = (name or "").strip()
    if not CATEGORY_RE.match(name):
        die(f"invalid name {name!r}: 1-40 characters, no # quotes : , [ ]")
    return name


def safe_name(raw, fallback="project"):
    """A folder name made into a valid project/category name: bad characters become '-', at
    most 40 characters."""
    name = re.sub(r"[#\"'\n:,\[\]]+", "-", raw or "").strip(" -")[:40].rstrip(" -")
    return name if CATEGORY_RE.match(name) else fallback


def ensure_listed(name):
    """A category used on a card joins the list, so the board can offer it."""
    if name and name not in load_categories():
        save_categories(load_categories() + [name])
        print(f"hq: added category {name!r}", file=sys.stderr)


def recategorize(old, new):
    """Rewrite every card (open or closed) whose category is `old`. Returns how many."""
    n = 0
    for p in card_paths():
        meta = parse_card(p)
        if (meta.get("category") or "") == old:
            set_fields(p, {"category": new, "updated": meta.get("updated", today())})
            append_log(p, f"category {old!r} → {new or '(none)'!r} (category list changed)", touch=False)
            n += 1
    return n


def category_usage():
    usage = {}
    for p in card_paths():
        c = parse_card(p).get("category") or ""
        usage[c] = usage.get(c, 0) + 1
    return usage


def age_days(meta):
    try:
        return (dt.date.today() - dt.date.fromisoformat(str(meta.get("updated", "")))).days
    except ValueError:
        return None


def secretary_task_id():
    """The secretary's own task, as recorded in hq.json; None when there is none or its card is gone."""
    cfg = load_json(root_config_path(), {})
    sec = cfg.get("secretary") if isinstance(cfg, dict) else None
    tid = sec.get("task") if isinstance(sec, dict) else None
    if not isinstance(tid, str) or not re.match(r"^T-\d+$", tid):
        return None
    for p in card_paths():
        d = os.path.basename(os.path.dirname(p))
        if d == tid or d.startswith(tid + "-"):
            return tid
    return None


def card_todos(lines):
    """(line index, todo number, match, plain text) for every todo line, numbered as the board does."""
    out, n = [], 0
    for i, line in enumerate(lines):
        t = TODO_RE.match(line)
        if t:
            n += 1
            out.append((i, n, t, todo_plain(t.group(3))))
    return out


def mark_todo(card, lines, pick, state, via):
    with card_lock(card):
        _mark_todo(card, lines, pick, state, via)


def _mark_todo(card, lines, pick, state, via):
    from .history import log_tick
    i, num, t, _ = pick
    mark = {"done": "x", "drop": "-", "open": " "}[state]
    lines[i] = f"{t.group(1)}- [{mark}] {t.group(3)}"
    atomic_write(card, "\n".join(lines))
    log_tick(card, f"todo #{num} → {state} ({via}): {TODO_TIME_RE.sub('', t.group(3))}")
    set_fields(card, {})


def todo_plain(raw):
    """A todo line's text as the board shows it: no time stamp, no @owner, spaces collapsed."""
    txt = TODO_TIME_RE.sub("", raw.strip()).rstrip()
    o = re.match(r"@(\S+)\s+(.*)$", txt)
    return " ".join((o.group(2) if o else txt).split())
LOG_ENTRY_RE = re.compile(r"^- (\d{4}-\d\d-\d\d(?:[ T]\d\d:\d\d(?::\d\d)?)?): (.*)$")


def add_todo(card, text):
    """Appends the todo; returns the line written (`hq inbox` takes it out again on a move)."""
    with card_lock(card):
        return _add_todo(card, text)


def _add_todo(card, text):
    lines = open(card, encoding="utf-8").read().split("\n")
    item = f"- [ ] {text.strip()} <!--t:{now_iso()}-->"
    head = next((i for i, l in enumerate(lines) if re.match(r"^##\s+(Todo|待办)", l, re.I)), None)
    last_todo = None
    for i, l in enumerate(lines):
        if TODO_RE.match(l) and (head is None or i > head):
            last_todo = i
    if last_todo is not None:
        lines.insert(last_todo + 1, item)
    elif head is not None:
        j = head + 1
        while j < len(lines) and lines[j].strip().startswith("<!--"):
            j += 1
        lines.insert(j, item)
    else:
        lines += ["", "## Todo", item]
    atomic_write(card, "\n".join(lines))
    set_fields(card, {})
    return item


STATUS_HEADING_RE = re.compile(
    r"^##[ \t]*(?:Status|Current state|当前状态|状态)(?:[ \t]*[(（][^\n]*)?[ \t]*\n(.*?)(?=^##\s|\Z)",
    re.M | re.S | re.I)


def todo_owner(raw):
    o = re.match(r"@(\S+)\s", TODO_TIME_RE.sub("", raw.strip()) + " ")
    return o.group(1).casefold() if o else None
LOG_LINE_RE = re.compile(r"^- (\d{4}-\d\d-\d\d \d\d:\d\d(?::\d\d)?): (.*)$")
LOG_HEADING_RE = re.compile(r"^##[ \t]*(?:Log|决策记录)\b.*?\n(.*?)(?=^##\s|\Z)", re.M | re.S | re.I)


def last_active(meta, history):
    """When the task last moved, to the second: its newest timed log line (on the card or moved to
    HISTORY.md) or when it was closed (`closed_at`; `closed`, a date, on cards closed before that
    was kept), whichever is later; else its `updated` date. What the board's Finished list orders
    by. Log lines with a date alone (hq-onboard writes one) don't count: they would put a card
    onboarded today above one that really moved today."""
    m = LOG_HEADING_RE.search(meta.get("body", "") + "\n")
    lines = (m.group(1) if m else "").splitlines() + [x.split("\n", 1)[0] for x in history.get("Log", [])]
    stamps = [x.group(1).replace("T", " ") for x in (LOG_ENTRY_RE.match(l.strip()) for l in lines)
              if x and len(x.group(1)) > 10]
    closed = meta.get("closed_at") or meta.get("closed")
    stamps += [str(closed)] if closed else []
    return max(stamps) if stamps else str(meta.get("updated") or "")


def card_state_lines(body):
    m = STATUS_HEADING_RE.search(body + "\n")
    lines = [l.strip() for l in (m.group(1) if m else "").splitlines()]
    return [l for l in lines if l and not l.startswith("<!--") and not is_placeholder(l)]
