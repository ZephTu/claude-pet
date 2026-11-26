"""`hq garden`: what a look over the board would tidy."""
import datetime as dt
import json
import os
import re

from .core import HOME_DIR, is_placeholder, iso, load_json, local_dt, one_line, OPEN_STATUSES
from .sessions import load_state, pid_alive
from .cards import card_paths, find_card, parse_card, secretary_task_id
from .refs import REF_URL_RE, URL_TAIL
from .history import process_ref
from .asks import read_asks
from .continuation import section_span
from .peek import pet_session
from .status import STATUS_STALE_DAYS, task_status


# ---------------------------------------------------------------- garden: tidying the board
# `hq garden` lists what a weekly look over the board would tidy, without a model: zombie tasks
# (open, card and sessions quiet for a week), finished tasks with a session still running, cards
# over budget, and pairs of tasks that look like the same work. The secretary turns the ones worth
# doing into asks; each finding names the secretary's earlier asks about that task, so a proposal
# still open isn't made twice and one the user said no to isn't made again while nothing changed.
GARDEN_DUP_SCORE = 0.5          # how alike two tasks must read (garden_score) to be a candidate pair
GARDEN_DUP_CLOSED_DAYS = 14     # an open task is also compared with ones closed this recently
GARDEN_DUP_SHOWN = 8
GARDEN_STOP = set("""the a an and or of to for in on at by with from into via is are be as it its this that
not no new add fix fixes use using make run runs test tests task tasks card cards board hq claude pet
的 了 和 与 及 在 把 让 给 用 做 一个 还 也 就 要""".split())
TICKET_RE = re.compile(r"^(?:!\s*)?([A-Z][A-Z0-9]+-\d+)\b")   # a ref that starts with a ticket key


def garden_words(text):
    """Words of a title or goal: Latin words of 3+ letters and CJK pairs, minus filler and task ids."""
    text = re.sub(r"\bT-\d+(?:\.\d+)?\b", " ", str(text or "")).lower()
    out = {w for w in re.findall(r"[a-z][a-z0-9_.+-]{2,}", text) if w.strip(".-") not in GARDEN_STOP}
    for run in re.findall(r"[㐀-鿿]+", text):
        out |= {run[i:i + 2] for i in range(len(run) - 1)} - GARDEN_STOP
        if len(run) == 1 and run not in GARDEN_STOP:
            out.add(run)
    return {w.strip(".-") for w in out if w.strip(".-")}


def garden_goal(meta):
    lines = meta["body"].splitlines()
    sp = section_span(lines, "goal")
    text = "\n".join(lines[sp[0] + 1:sp[1]]) if sp else ""
    # The goal's opening, not the general constraints a project pastes into every card.
    text = "\n".join(l for l in re.sub(r"<!--.*?-->", "", text, flags=re.S).splitlines()
                     if not is_placeholder(l.strip()))
    text = re.split(r"\n\s*\n", text.strip(), maxsplit=1)[0]
    return one_line(text, 400)


def garden_links(meta):
    """Links and ticket keys on a card that say which work it is (not one build or comment)."""
    refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
    out = set()
    for r in refs:
        r = str(r)
        if process_ref(r):
            continue
        out |= {u.rstrip(URL_TAIL) for u in REF_URL_RE.findall(r)}
        out |= set(TICKET_RE.findall(r.strip()))
    return out


def garden_score(ta, tb, fa, fb):
    """How alike two tasks read, 0–1: their titles' words in common (Jaccard, or the share of the
    shorter title when it has 3+ words, a little discounted), or their titles and goals together.
    One word in common ("Docs" and "p2 docs") says nothing: 2+ for titles, 3+ with goals."""
    jac = lambda x, y, k=2: len(x & y) / len(x | y) if len(x & y) >= k else 0.0
    short = min(len(ta), len(tb))
    within = 0.8 * len(ta & tb) / short if short >= 3 else 0.0
    within = within if len(ta & tb) >= 2 else 0.0
    return max(jac(ta, tb), within, jac(fa, fb, 3))


def garden_dups(metas, sec):
    today_ = dt.date.today()
    recent = (today_ - dt.timedelta(days=GARDEN_DUP_CLOSED_DAYS)).isoformat()
    pool = [m for m in metas if m.get("id") and m.get("id") != sec
            and (m.get("status") in OPEN_STATUSES or str(m.get("closed") or "") >= recent)]
    info = {}
    for m in pool:
        title = garden_words(m.get("title"))
        info[m["id"]] = (title, title | garden_words(garden_goal(m)), garden_links(m),
                         f"{m.get('title', '')}\n{m['body']}")
    pairs = []
    for i, a in enumerate(pool):
        for b in pool[i + 1:]:
            if a.get("status") not in OPEN_STATUSES and b.get("status") not in OPEN_STATUSES:
                continue
            ta, fa, la, body_a = info[a["id"]]
            tb, fb, lb, body_b = info[b["id"]]
            score = garden_score(ta, tb, fa, fb)
            shared = sorted(la & lb)
            if score < GARDEN_DUP_SCORE and not shared:
                continue
            # `hq continue` made one from the other: the same work by design, not a duplicate.
            if any(re.search(rf"continued in {re.escape(y['id'])}\b", str(x.get("next") or ""))
                   for x, y in ((a, b), (b, a))):
                continue
            mention = bool(re.search(rf"\b{re.escape(b['id'])}\b(?!\.\d)", body_a)
                           or re.search(rf"\b{re.escape(a['id'])}\b(?!\.\d)", body_b))
            pairs.append({"tasks": [a["id"], b["id"]], "titles": [a.get("title") or "", b.get("title") or ""],
                          "statuses": [a.get("status"), b.get("status")],
                          "goals": [garden_goal(a), garden_goal(b)],
                          "score": round(score, 2), "sharedLinks": shared[:5],
                          "words": sorted(fa & fb)[:12], "mention": mention})
    # Shared links first, then the closest; a pair where one card names the other last (often a
    # part or a follow-up, though "same work as T-012" names it too).
    pairs.sort(key=lambda p: (p["mention"], not p["sharedLinks"], -p["score"]))
    return pairs[:GARDEN_DUP_SHOWN]


def garden_asked(sec_dir, ids):
    """The secretary's asks that name each of these tasks: {task id: [ask, …]}, oldest first."""
    out = {i: [] for i in ids}
    if not sec_dir:
        return out
    for a in read_asks(sec_dir):
        for i in ids:
            if re.search(rf"\b{re.escape(i)}\b(?!\.\d)", a.get("text") or ""):
                out[i].append({"id": a["id"], "state": a["state"], "at": a.get("ts"),
                               "answeredAt": a.get("resolved_at"), "note": a.get("note") or "",
                               "text": one_line(a.get("text"), 160)})
    return out


def garden_settled(asked, written):
    """Why a finding isn't to be proposed again, or None: an ask about its task is still open, or
    the user said no to the last one and the card hasn't been written since (nothing changed)."""
    for a in reversed(asked):
        if a["state"] == "open":
            return f"open ask {a['id']}"
        said = local_dt(a.get("answeredAt"))
        if a["state"] == "drop" and said and written and written <= said:
            return f"declined {str(a['answeredAt'])[:10]} ({a['id']}), card unchanged since"
        if a["state"] in ("do", "drop"):
            return None
    return None


def gather_garden(now=None):
    now = now or dt.datetime.now().astimezone()
    sec = secretary_task_id()
    state = load_state()
    seen = load_json(os.path.join(HOME_DIR, "state", "todo-seen.json"), {})
    seen = seen if isinstance(seen, dict) else {}
    metas = [parse_card(p) for p in card_paths()]
    live_on = {e.get("task") for sid, e in state.items() if isinstance(e, dict) and e.get("task")
               and isinstance(pet_session(sid), dict) and pid_alive(pet_session(sid).get("pid"))}
    findings = []
    for m in metas:
        if not m.get("id") or m.get("id") == sec or not (m.get("status") in OPEN_STATUSES or m.get("id") in live_on):
            continue
        s = task_status(m, state, now, seen)
        kinds = {f["kind"]: f for f in s["flags"]}
        last = max([local_dt(x["lastAt"]) for x in s["sessions"] if x.get("lastAt")] or [None],
                   key=lambda t: t or dt.datetime.min.replace(tzinfo=now.tzinfo))
        base = {"task": s["id"], "title": s["title"] or "", "status": s["status"], "project": s["project"],
                "updated": s["updated"], "cardWritten": s["cardWritten"], "next": s["next"], "state": s["state"][:3],
                "meTodos": s["todos"]["me"]["count"], "asks": s["asks"]["count"]}
        if "stale" in kinds:
            quiet_days = (now - last).days if last else None
            # A session still at it, card not written: that is `card-behind`, not a zombie.
            if quiet_days is None or quiet_days >= STATUS_STALE_DAYS:
                findings.append(dict(base, kind="zombie", days=kinds["stale"]["days"],
                                     lastSession=iso(last), live=any(x["live"] for x in s["sessions"]),
                                     log=s["log"][-2:]))
        if "done-live" in kinds:
            findings.append(dict(base, kind="done-live", sessions=kinds["done-live"]["sessions"],
                                 closed=m.get("closed") or ""))
        if "over-budget" in kinds:
            f = kinds["over-budget"]
            findings.append(dict(base, kind="over-budget", bytes=f["bytes"], refs=f["refs"], todos=f["todos"],
                                 text=f["text"]))
    sec_dir = os.path.dirname(find_card(sec)) if sec else None
    dups = garden_dups(metas, sec)
    asked = garden_asked(sec_dir, sorted({f["task"] for f in findings} | {t for p in dups for t in p["tasks"]}))
    by_id = {m.get("id"): m for m in metas}
    for f in findings:
        f["asked"] = asked.get(f["task"], [])
        f["settled"] = garden_settled(f["asked"], local_dt(f["cardWritten"]))
    for p in dups:
        both = [a for a in asked.get(p["tasks"][0], []) if a in asked.get(p["tasks"][1], [])]
        p["asked"] = both
        p["settled"] = garden_settled(both, max(local_dt(os.path.getmtime(by_id[t]["path"])) for t in p["tasks"]))
    order = {"done-live": 0, "zombie": 1, "over-budget": 2}
    findings.sort(key=lambda f: (order[f["kind"]], -(f.get("days") or 0)))
    return {"now": iso(now), "secretary": sec, "findings": findings, "duplicates": dups}


def garden_text(g):
    out = []
    todo = [f for f in g["findings"] if not f["settled"]] + [p for p in g["duplicates"] if not p["settled"]]
    done = [f for f in g["findings"] if f["settled"]] + [p for p in g["duplicates"] if p["settled"]]
    for f in [x for x in todo if "kind" in x]:
        head = f"{f['task']} {f['title']}  [{f['status']}{' · ' + f['project'] if f['project'] else ''}, updated {f['updated']}]"
        if f["kind"] == "zombie":
            out.append(f"zombie: {head}")
            out.append(f"  not updated for {f['days']} days; last session activity: "
                       f"{f['lastSession'][:10] if f['lastSession'] else 'none'}{' (a session is still open)' if f['live'] else ''}")
        elif f["kind"] == "done-live":
            out.append(f"done-live: {head}")
            out.append(f"  closed {f['closed'] or '?'}, still running: {', '.join(x[:8] for x in f['sessions'])}")
        else:
            out.append(f"over-budget: {head}")
            out.append(f"  {f['text']}")
        if f["next"]:
            out.append(f"  next: {one_line(f['next'], 200)}")
        out += [f"  state: {one_line(x, 200)}" for x in f["state"]]
        for x in f.get("log") or []:
            out.append(f"  last log {x['at'][:10]}: {one_line(x['text'], 160)}")
        if f["meTodos"] or f["asks"]:
            out.append(f"  on the user: {f['meTodos']} @me todo(s), {f['asks']} open ask(s)")
        out += [f"  earlier ask {a['id']} ({a['state']}): {a['text']}" for a in f["asked"]]
    for p in [x for x in todo if "tasks" in x]:
        a, b = p["tasks"]
        out.append(f"duplicate? {a} {p['titles'][0]} [{p['statuses'][0]}]  ~  {b} {p['titles'][1]} [{p['statuses'][1]}]")
        why = [f"word overlap {p['score']}"] + ([f"same links: {', '.join(p['sharedLinks'])}"] if p["sharedLinks"] else [])
        if p["mention"]:
            why.append("one card names the other (often a part or follow-up; read what it says)")
        out.append("  " + "; ".join(why) + (f"; shared words: {' '.join(p['words'])}" if p["words"] else ""))
        for t, goal in zip(p["tasks"], p["goals"]):
            if goal:
                out.append(f"  {t} goal: {one_line(goal, 200)}")
        out += [f"  earlier ask {x['id']} ({x['state']}): {x['text']}" for x in p["asked"]]
    if not todo:
        out.append("nothing to tidy")
    if done:
        out.append("")
        out.append("already proposed — don't propose again:")
        for x in done:
            what = f"{x['kind']} {x['task']}" if "kind" in x else f"duplicate {' ~ '.join(x['tasks'])}"
            out.append(f"  {what}: {x['settled']}")
    return "\n".join(out)


def cmd_garden(args):
    g = gather_garden()
    print(json.dumps(g, ensure_ascii=False) if args.json else garden_text(g))
