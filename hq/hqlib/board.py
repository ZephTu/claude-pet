"""`hq board` and `hq show`."""
import json
import os

from .core import (
    atomic_write, HOME_DIR, hq_root, load_json, now_iso, OPEN_STATUSES, snoozed, STATUSES, TODO_RE,
)
from .cards import (
    age_days, card_paths, find_card, last_active, parse_card, root_config_path, secretary_task_id,
    todo_fields,
)
from .history import history_info, read_history
from .projects import load_projects, project_info, project_stats, task_repo
from .asks import read_asks
from .protocol import open_asks_text
from .focus import focus_state
from .inbox import inbox_view
from .reports import closed_time, todo_closed_times


# ---------------------------------------------------------------- commands
def stamp_todos(metas):
    """Give every open todo a creation time: its hidden <!--t:…--> stamp if it has one, else the
    first time HQ saw it (kept in HQ's state, so the card itself is not rewritten)."""
    path = os.path.join(HOME_DIR, "state", "todo-seen.json")
    seen = load_json(path, {})
    changed = False
    now = now_iso()
    for m in metas:
        items = [t for t in m["todos"] if t["state"] == "open"]
        if m.get("waiting_on_me"):
            items.append({"text": m["waiting_on_me"], "_legacy": True})
        for t in items:
            key = f"{m.get('id')}|{t['text']}"
            if not t.get("created"):
                if key not in seen:
                    seen[key] = now
                    changed = True
                if t.get("_legacy"):
                    m["waiting_since"] = seen[key]
                else:
                    t["created"] = seen[key]
    if changed:
        atomic_write(path, json.dumps(seen, ensure_ascii=False))


def cmd_board(args):
    metas = [parse_card(p) for p in card_paths()]
    for m in metas:
        m["age_days"] = age_days(m)
        m["asks"] = read_asks(m["dir"])
    stamp_todos(metas)
    if args.json:
        out = []
        for m in metas:
            d = {k: v for k, v in m.items() if k not in ("dir",)}
            # The reply that raised an ask is shown while it is open; once answered it is only
            # history (`hq asks <task> --all --json` still has it), and across every card it was
            # most of the board — re-read every few seconds, and over a slow link by a phone.
            d["asks"] = [a if a.get("state") == "open" else {k: v for k, v in a.items() if k != "context"}
                         for a in m["asks"]]
            d["repo"] = task_repo(m)        # for the board's By repo view: a worktree counts as its repo
            # What the card budget moved to HISTORY.md: the board shows it with the card's own.
            h = read_history(m["path"])
            d["history"] = {"log": h["Log"], "links": [x[2:] for x in h["Links"]],
                            "todos": [todo_fields(x) for x in (TODO_RE.match(i.split("\n", 1)[0]) for i in h["Todos"]) if x]}
            # When each closed todo was closed, so the board lists the latest first.
            closed = todo_closed_times(m, h["Log"])
            for x in reversed(d["history"]["todos"] + d["todos"]):
                if x["state"] != "open":
                    x["closed"] = closed_time(closed, x["text"])
            d["historyInfo"] = history_info(m["path"])
            d["lastActive"] = last_active(m, h)
            out.append(d)
        cfg = load_json(root_config_path(), {})
        links = cfg.get("links", []) if isinstance(cfg, dict) else []
        projects = [dict(project_info(pr), stats=project_stats(pr["name"], metas)) for pr in load_projects()]
        print(json.dumps({"root": hq_root(), "focus": focus_state(), "projects": projects,
                          "links": links, "secretary": secretary_task_id(), "inbox": inbox_view(), "tasks": out},
                         ensure_ascii=False, separators=(",", ":")))
        return
    open_asks = [(m, a) for m in metas for a in m["asks"] if a["state"] == "open" and not snoozed(a)]
    my_todos = [(m, t) for m in metas if m.get("status") in OPEN_STATUSES
                for t in m["todos"] if t["state"] == "open" and t["owner"] == "me"]
    my_todos += [(m, {"i": "-", "text": m["waiting_on_me"]}) for m in metas
                 if m.get("status") in OPEN_STATUSES and m.get("waiting_on_me")]
    if open_asks:
        print(f"\n❓ 待你回应 asks ({len(open_asks)})")
        for m, a in open_asks:
            print(f"  {a['id']:<8} {a['text']}")
    if my_todos:
        print(f"\n📝 你的待办 @me ({len(my_todos)})")
        for m, t in my_todos:
            print(f"  {m['id']}#{t['i']:<3} {t['text']}")
    labels = {"waiting-on-me": "🔴 等你处理", "blocked": "🟠 阻塞", "active": "🟢 进行中",
              "done": "✅ 已完成", "abandoned": "⚪ 已放弃"}
    for st in STATUSES:
        if st in ("done", "abandoned") and not args.all:
            continue
        group = sorted([m for m in metas if m.get("status") == st],
                       key=lambda m: str(m.get("updated", "")), reverse=True)
        if not group:
            continue
        print(f"\n{labels[st]} ({len(group)})")
        for m in group:
            age = f"{m['age_days']}d" if m["age_days"] is not None else "?"
            print(f"  {m.get('id','?'):<6} [{(m.get('project') or '-'):<13}] {m.get('title','')}  ({m.get('lead','-')}, {age})")
            mine = [t["text"] for t in m["todos"] if t["state"] == "open" and t["owner"] == "me"]
            if m.get("waiting_on_me"):           # legacy field; @me todos replaced it
                mine.insert(0, m["waiting_on_me"])
            if mine and st not in ("done", "abandoned"):
                print(f"         ⮑ 你: {mine[0]}" + (f"（+{len(mine) - 1}）" if len(mine) > 1 else ""))
            elif m.get("next") and st not in ("done", "abandoned"):
                print(f"         ⮑ 下一步: {m['next']}")
    hidden = sum(1 for m in metas if m.get("status") in ("done", "abandoned"))
    if hidden and not args.all:
        print(f"\n（另有 {hidden} 个已完成/已放弃，用 --all 查看）")


def cmd_show(args):
    card = find_card(args.task)
    print(open(card, encoding="utf-8").read())
    t = open_asks_text(parse_card(card), limit=100)
    if t:
        print(t)
