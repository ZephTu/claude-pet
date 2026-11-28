"""focus"""
from .compat import fcntl
import json
import os
import re

from .core import (
    atomic_write, card_lock, HOME_DIR, hq_root, load_json, LOCK_DIR, OPEN_STATUSES, slugify, tasks_dir,
    today,
)
from .cards import card_paths, check_category, ensure_listed, parse_card, set_fields
from .projects import ensure_project, project_for_dirs


# ---------------------------------------------------------------- focus
# <root>/focus.json: {"focus": ["T-062", "T-003", ...]} — the tasks kept in view, in order.
def focus_path():
    return os.path.join(hq_root(), "focus.json")


def load_focus():
    """The Focus list: the tasks you keep in view, in your order, until you take them off.
    focus.json used to hold one list per day ({"days": {date: [ids]}}); that reads as the most
    recent day's list, and the next save writes the new form ({"focus": [ids]})."""
    f = load_json(focus_path(), {})
    if isinstance(f, dict) and isinstance(f.get("focus"), list):
        return [str(i) for i in f["focus"]]
    days = f.get("days") if isinstance(f, dict) else None
    if not isinstance(days, dict):
        return []
    # The latest day's list, then what the day before it still had (the old board offered to
    # carry those over, so they were meant to stay). Anything not a list of ids is skipped.
    lists = [days[d] for d in sorted(days, reverse=True) if isinstance(days[d], list) and days[d]]
    out = []
    for ids in lists[:2]:
        out += [str(i) for i in ids if isinstance(i, str) and str(i) not in out]
    return out


def save_focus(ids):
    atomic_write(focus_path(), json.dumps({"focus": list(dict.fromkeys(ids))}, ensure_ascii=False, indent=1) + "\n")


def focus_state():
    ids = load_focus()
    status = {}
    for p in card_paths():
        m = parse_card(p)
        status[m.get("id")] = m.get("status")
    # Only open tasks show: one marked done drops out (and comes back if it's reopened); a task
    # that no longer exists is dropped.
    ids = [i for i in ids if status.get(i) in OPEN_STATUSES]
    # "today" / "last_day" / "carry" are kept for older readers; there is no daily list any more.
    return {"ids": ids, "today": today(), "last_day": None, "carry": []}


def focus_add(ids):
    cur = load_focus()
    save_focus(cur + [i for i in ids if i not in cur])


def set_card_goal(card, text):
    """Replace what the Goal section of a card says (the template's placeholder, on a new card)."""
    with card_lock(card):
        lines = open(card, encoding="utf-8").read().split("\n")
        head = next((i for i, l in enumerate(lines) if re.match(r"^##\s+(Goal|目标)\b", l, re.I)), None)
        body = text.strip().split("\n")
        if head is None:
            m = next((i for i, l in enumerate(lines) if l.startswith("## ")), len(lines))
            lines[m:m] = ["## Goal"] + body + [""]
        else:
            end = next((i for i in range(head + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
            lines[head + 1:end] = body + [""]
        atomic_write(card, "\n".join(lines))


def task_template():
    tpl = os.path.join(hq_root(), "templates", "TASK.md")
    if not os.path.exists(tpl):
        tpl = os.path.join(HOME_DIR, "template", "TASK.md")
    return open(tpl, encoding="utf-8").read()


def new_card(title, slug=None, category=None, project=None, lead=None, workdirs=None, focus=True):
    # The board, feeds and `hq intake` make cards unattended: one at a time picks the next id.
    os.makedirs(LOCK_DIR, exist_ok=True)
    with open(os.path.join(LOCK_DIR, "new-card.lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            return _new_card(title, slug, category, project, lead, workdirs, focus)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _new_card(title, slug=None, category=None, project=None, lead=None, workdirs=None, focus=True):
    td = tasks_dir()
    nums = [int(m.group(1)) for d in os.listdir(td) for m in [re.match(r"T-(\d+)", d)] if m]
    tid = f"T-{(max(nums) + 1 if nums else 1):03d}"
    d = os.path.join(td, f"{tid}-{slugify(slug or title)}")
    text = task_template()
    # Categories are retired: projects and duties group tasks now. A card gets one only when asked
    # (`--category`, or carried over by `hq continue`); otherwise its template's line is dropped.
    fields = {"id": tid, "title": title}
    if category:
        fields["category"] = check_category(category)
        ensure_listed(fields["category"])
    else:
        m = re.match(r"^---\n(.*?)\n---\n?", text, re.S)
        if m:
            fm = re.sub(r"^category:[^\n]*\n?", "", m.group(1) + "\n", flags=re.M).rstrip("\n")
            text = "---\n" + fm + "\n---\n" + text[m.end():]
    workdirs = [os.path.abspath(os.path.expanduser(w)) for w in (workdirs or [])]
    project = check_category(project) if project else project_for_dirs(workdirs)
    ensure_project(project)
    os.makedirs(d)
    p = os.path.join(d, "TASK.md")
    atomic_write(p, text)
    set_fields(p, dict(fields, project=project, status="active", lead=lead or "-", updated=today(), workdirs=workdirs))
    if focus:
        focus_add([tid])            # a new task joins Focus
    return tid, p
