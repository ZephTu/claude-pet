"""`hq status`: where tasks stand, with flags where card and sessions disagree."""
import datetime as dt
import json
import os
import re

from .core import HOME_DIR, iso, load_json, local_dt, one_line, OPEN_STATUSES, snoozed, strip_hq_blocks
from .sessions import load_state, pid_alive
from .cards import age_days, card_paths, card_state_lines, find_card, LOG_HEADING_RE, LOG_LINE_RE, parse_card
from .asks import read_asks
from .focus import load_focus
from .peek import (
    background_entries, compacted_since, entry_ts, find_transcript, peek_timeline, pet_activity, pet_session,
    reply_tokens, session_title, transcript_tail,
)


# ---------------------------------------------------------------- status
# `hq status`: where a task stands, put together by code instead of a session grepping cards and
# transcripts — the card's own account (status, next, Status section, latest log), what is still
# open and how long it has waited, its sessions (state, last activity, context, last words) — and
# flags where these disagree. Read-only. Kept to about 1k tokens a task: long lists are cut, with
# a count of what was left out.
STATUS_STALE_DAYS = 7          # an open card not updated for this long
STATUS_IDLE_MINUTES = 30       # nothing running this long while the card says it waits on a run
STATUS_BEHIND_MINUTES = 10     # a session worked this long after the card was last written
CARD_MAX_BYTES = 16_000        # a card past any of these is over budget: every session that
CARD_MAX_REFS = 30             # starts on the task reads all of it
CARD_MAX_TODOS = 30
STATUS_TODOS_SHOWN = 6         # per owner group, newest kept
STATUS_ASKS_SHOWN = 5
STATUS_SESSIONS_SHOWN = 3      # the live ones first, then the most recent
STATUS_MSGS = 3                # last words of the most recent session (one for the others)
# The card says it waits on something that runs by itself — a build, a watcher, a job — as
# opposed to a person. A clause needs both a cue and a machine word.
# ("a file watcher" or "测试等问题" is no wait; "to run the numbers" and "PR #1234" are a person's.)
WAIT_CUE_RE = re.compile(
    r"\bwait(?:ing|s)?\s+(?:on|for)\b|\b(?:watching|monitoring|polling)\b"
    r"|\b(?:when|once|after|until)\b[^.;\n]{0,80}?\b(?:fires?|finish(?:es|ed)?|completes?|pass(?:es)?|lands?|done|ends?)\b"
    r"|等(?!你|问题|方面|内容|情况|工作|事|文件|地方|等)|盯|完成后|结束后|出结果|跑完(?:后|再|就|之后|了再)", re.I)
WAIT_MACHINE_RE = re.compile(
    r"\b(?:builds?|jobs?|ci|jenkins|pipelines?|watcher|tests?|deploy(?:ment)?|workflow|cluster)\b"
    r"|(?<!\bto )\bruns?\b|(?<!PR )(?<!PR)#\d{3,}|构建|跑|流水线|部署|集群", re.I)
OLDER_200K = ("claude-3", "claude-haiku-4", "claude-sonnet-4", "claude-opus-4-0", "claude-opus-4-1",
              "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-2")


def context_budget(model):
    """Tokens at which a session on `model` compacts — the pet's ContextBudget: the model's window,
    lowered by /autocompact (settings.json modelSettings / env)."""
    m = (model or "").lower().strip()
    window = whole = 1_000_000 if "[1m]" in m or not m.startswith(OLDER_200K) else 200_000
    key = re.sub(r"-\d{8}$", "", m.split("[", 1)[0])
    s = load_json(os.path.expanduser("~/.claude/settings.json"), {})
    s = s if isinstance(s, dict) else {}
    env = s.get("env") if isinstance(s.get("env"), dict) else {}

    def num(v):
        try:
            return float(str(v).strip())
        except (TypeError, ValueError):
            return None
    models = {str(k).lower(): v for k, v in (s.get("modelSettings") or {}).items()} \
        if isinstance(s.get("modelSettings"), dict) else {}
    per = {k: num((v or {}).get("autoCompactWindow")) for k, v in models.items() if isinstance(v, dict)}
    by_key = {re.sub(r"-\d{8}$", "", k.split("[", 1)[0]): w for k, w in per.items() if w and w > 0}
    env_w = num(env.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
    if env_w and env_w > 0:
        window = min(int(env_w), whole)
    elif per.get(m) and per[m] > 0:
        window = min(int(per[m]), whole)
    elif by_key.get(key):
        window = min(int(by_key[key]), whole)
    pct = num(env.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"))
    if pct and 0 < pct <= 100:
        window = max(1, int(window * pct / 100))
    return window


def short_time(t, now):
    """11-23 09:53, or 09:53 for today."""
    if not t:
        return "?"
    return t.strftime("%H:%M") if t.date() == now.date() else t.strftime("%m-%d %H:%M")


def span(seconds):
    """How long, short: 45m, 3h, 2d."""
    if seconds is None:
        return "?"
    m = max(0, int(seconds // 60))
    if m < 60:
        return f"{m}m"
    if m < 48 * 60:
        return f"{m // 60}h"
    return f"{m // 1440}d"


def card_log(body, n=3):
    """The card's last n log entries, leaving out todo ticks (the todo lists show those)."""
    m = LOG_HEADING_RE.search(body + "\n")
    out = []
    for line in (m.group(1) if m else "").splitlines():
        x = LOG_LINE_RE.match(line.strip())
        if x and not re.match(r"todo #\d+ → ", x.group(2)):
            out.append({"at": x.group(1), "text": x.group(2)})
    return out[-n:]


def waiting_on_a_run(texts):
    """The first clause of the card's next / status that says it waits on a run, build, watcher …"""
    for t in texts:
        for clause in re.split(r"[;；。\n]|(?<=[a-z0-9)])\.\s", t or ""):
            if WAIT_CUE_RE.search(clause) and WAIT_MACHINE_RE.search(clause):
                return one_line(clause.strip(" ,:-"), 120)
    return None


def session_status(sid, path, now, n_msgs):
    """One session as `hq status` shows it."""
    rec = pet_session(sid)
    live = bool(isinstance(rec, dict) and pid_alive(rec.get("pid")))
    entries = transcript_tail(path, 600_000)
    items = peek_timeline(entries)
    acts = [local_dt(entry_ts(o)) for o in entries
            if o.get("type") in ("user", "assistant") and not o.get("isSidechain") and entry_ts(o)]
    last = max([a for a in acts if a], default=None) or local_dt(os.path.getmtime(path))
    tools = [it for it in items if it["kind"] == "tool"]
    # When a tool was called, not when it ended: a background job's end is its completion notice
    # arriving, which is not the session doing anything.
    last_tool = max([local_dt(it.get("ts")) for it in tools if it.get("ts")] or [None],
                    key=lambda t: t or dt.datetime.min.replace(tzinfo=dt.timezone.utc))
    # From the whole transcript, not the tail: a run launched long ago may still be going.
    background = [one_line(f"{it['title']}: {it['label']}", 80) for it in peek_timeline(background_entries(path))
                  if it["kind"] == "tool" and it["status"] == "background"] if live else []
    st = {"busy": "working", "waiting": "waiting-on-you", "idle": "idle"}.get(pet_activity(rec), "idle") \
        if live else "ended"
    # Context: the last real reply's request, as the pet counts it (an API error has no tokens),
    # unless a compaction came after it: then the size the boundary gives, until the next reply.
    at, reply = next(((i, o) for i, o in reversed(list(enumerate(entries)))
                      if o.get("type") == "assistant" and not o.get("isSidechain") and reply_tokens(o) > 0),
                     (-1, None))
    post = compacted_since(entries, at, path)
    tokens = post if post is not None else reply_tokens(reply) if reply else 0
    ctx = None
    if tokens > 0:
        b = context_budget(reply and (reply.get("requestedModel") or (reply.get("message") or {}).get("model")))
        ctx = {"tokens": tokens, "budget": b, "percent": min(999, round(tokens * 100 / b))}
    msgs = []
    for it in reversed(items):
        if len(msgs) >= n_msgs:
            break
        if it["kind"] != "msg":
            continue
        text = strip_hq_blocks(it["text"]) if it["role"] == "assistant" else it["text"]
        if text.strip():
            msgs.append({"role": it["role"], "ts": iso(local_dt(it["ts"])), "text": one_line(text, 200)})
    msgs.reverse()
    return {"sessionId": sid, "title": session_title(entries), "live": live, "state": st,
            "lastAt": iso(last), "lastToolAt": iso(last_tool),
            "idleFor": int((now - last).total_seconds()) if last and st in ("idle", "ended") else None,
            "context": ctx, "background": background if live else [], "messages": msgs}


def task_sessions(meta, state, now, written):
    """The task's sessions, live first, then most recent: the ones bound to it now and the ones its
    card lists, except a session since bound to another task (its work is that task's now).
    Returns (shown, checked, total): the first STATUS_SESSIONS_SHOWN; those plus every other one
    that could raise a flag (live, or written to after the card); and how many there are."""
    bound = {sid: e.get("task") for sid, e in state.items() if isinstance(e, dict)}
    ids = [sid for sid, t in bound.items() if t == meta.get("id")]
    ids += [str(s) for s in (meta.get("sessions") or []) if s]
    found, seen = [], set()
    for sid in ids:
        path, live = find_transcript(sid)
        if not path or path in seen:
            continue
        full = os.path.basename(path)[:-6]
        if bound.get(full) not in (None, meta.get("id")):
            continue
        seen.add(path)
        found.append((full, path, live, os.path.getmtime(path)))
    found.sort(key=lambda x: (not x[2], -x[3]))
    shown, checked = [], []
    for i, (sid, path, live, mtime) in enumerate(found):
        if i < STATUS_SESSIONS_SHOWN:
            shown.append(session_status(sid, path, now, STATUS_MSGS if i == 0 else 1))
            checked.append(shown[-1])
        elif live or local_dt(mtime) > written + dt.timedelta(minutes=STATUS_BEHIND_MINUTES):
            checked.append(session_status(sid, path, now, 0))
    return shown, checked, len(found)


def todo_groups(meta, seen):
    """Open todos by owner (me / claude / others): newest STATUS_TODOS_SHOWN of each, with how long
    each has waited (its stamp, or when HQ first saw it)."""
    groups = {"me": [], "claude": [], "others": []}
    for t in meta.get("todos", []):
        if t["state"] != "open":
            continue
        owner = t.get("owner")
        since = local_dt(t.get("created") or seen.get(f"{meta.get('id')}|{t['text']}"))
        g = owner if owner in ("me", "claude") else "others"
        groups[g].append({"text": one_line(t["text"], 140), "owner": owner, "since": iso(since)})
    return {g: {"count": len(v), "items": v[-STATUS_TODOS_SHOWN:]} for g, v in groups.items()}


def stale_days(meta):
    """Days an open card has gone without an update, once that is a week or more (the `stale` flag
    of `hq status`, and the board's tag); else 0."""
    age = age_days(meta)
    return age if meta.get("status") in OPEN_STATUSES and age is not None and age >= STATUS_STALE_DAYS else 0


def task_status(meta, state, now, seen):
    card = meta["path"]
    written = local_dt(os.path.getmtime(card))
    size = os.path.getsize(card)
    refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
    state_lines = card_state_lines(meta["body"])
    asks = [a for a in read_asks(meta["dir"]) if a.get("state") == "open"]
    shown, sessions, n_sessions = task_sessions(meta, state, now, written)
    status = meta.get("status")
    is_open = status in OPEN_STATUSES
    flags = []

    def flag(kind, en, zh, **data):
        flags.append(dict({"kind": kind, "text": en, "text_zh": zh}, **data))

    # The card is behind its sessions: one called tools well after the card was last written and
    # is not mid-turn (working, or held at a prompt) — the turn ended without an hq-update.
    for s in sessions:
        t = local_dt(s.get("lastToolAt"))
        if s["state"] not in ("working", "waiting-on-you") and t and (t - written).total_seconds() > STATUS_BEHIND_MINUTES * 60:
            flag("card-behind",
                 f"card behind: session {s['sessionId'][:8]} worked until {short_time(t, now)}, card last written {short_time(written, now)}",
                 f"卡片落后：session {s['sessionId'][:8]} 一直干到 {short_time(t, now)}，卡片最后写入是 {short_time(written, now)}",
                 session=s["sessionId"], at=iso(t), cardWritten=iso(written))
            break
    # Nothing is running, yet the card says it waits on a run.
    waits = waiting_on_a_run([meta.get("next") or ""] + state_lines) if is_open else None
    if waits:
        running = [s for s in sessions if s["live"] and (s["state"] in ("working", "waiting-on-you") or s["background"])]
        quiet = max([local_dt(s["lastAt"]) for s in sessions if s.get("lastAt")] or [written])
        if not running and (now - quiet).total_seconds() > STATUS_IDLE_MINUTES * 60:
            who = "no live session" if not any(s["live"] for s in sessions) else "its sessions are idle with nothing in the background"
            who_zh = "没有活着的 session" if not any(s["live"] for s in sessions) else "session 空闲，后台也没有在跑的东西"
            flag("idle-waiting",
                 f"idle since {short_time(quiet, now)} ({who}), but the card says: {waits}",
                 f"从 {short_time(quiet, now)} 起没有动静（{who_zh}），但卡片说在等：{waits}",
                 since=iso(quiet), says=waits)
    age = stale_days(meta)
    if age:
        flag("stale", f"not updated for {age} days (since {meta.get('updated')})",
             f"{age} 天没更新（上次 {meta.get('updated')}）", days=age)
    if status in ("done", "abandoned"):
        live = [s for s in sessions if s["live"]]
        if live:
            names = ", ".join(f"{s['sessionId'][:8]} ({s['state']})" for s in live)
            flag("done-live", f"task is {status} but {len(live)} session(s) still running: {names}",
                 f"任务已{'完成' if status == 'done' else '放弃'}，但还有 {len(live)} 个 session 在跑：{names}",
                 sessions=[s["sessionId"] for s in live])
    over = []
    if size > CARD_MAX_BYTES:
        over.append((f"{size // 1000} KB (budget {CARD_MAX_BYTES // 1000} KB)", f"{size // 1000} KB（预算 {CARD_MAX_BYTES // 1000} KB）"))
    if len(refs) > CARD_MAX_REFS:
        over.append((f"{len(refs)} links (budget {CARD_MAX_REFS})", f"{len(refs)} 个链接（预算 {CARD_MAX_REFS}）"))
    if len(meta.get("todos", [])) > CARD_MAX_TODOS:
        n = len(meta["todos"])
        over.append((f"{n} todos (budget {CARD_MAX_TODOS})", f"{n} 条待办（预算 {CARD_MAX_TODOS}）"))
    if over:
        flag("over-budget", "card over budget: " + ", ".join(e for e, _ in over),
             "卡片超预算：" + "，".join(z for _, z in over), bytes=size, refs=len(refs), todos=len(meta.get("todos", [])))
    return {
        "id": meta.get("id"), "title": meta.get("title"), "status": status, "project": meta.get("project") or None,
        "updated": meta.get("updated"), "cardWritten": iso(written), "ageDays": age,
        "next": meta.get("next") or "", "state": [one_line(l, 200) for l in state_lines[:6]],
        "stateMore": max(0, len(state_lines) - 6),
        "log": [{"at": x["at"], "text": one_line(x["text"], 200)} for x in card_log(meta["body"])],
        "todos": todo_groups(meta, seen),
        "asks": {"count": len(asks), "items": [
            {"id": a["id"], "text": one_line(a.get("text"), 200), "since": iso(local_dt(a.get("ts"))),
             "snoozedUntil": a.get("snoozed_until") if snoozed(a) else None} for a in asks[:STATUS_ASKS_SHOWN]]},
        "sessions": shown, "sessionsMore": max(0, n_sessions - len(shown)),
        "flags": flags,
    }


def status_text(s, now):
    """`hq status` as text: one block per task."""
    ago = lambda ts: span((now - local_dt(ts)).total_seconds()) if ts else "?"
    out = [f"{s['id']} {s['title']}  [{s['status']}{' · ' + s['project'] if s['project'] else ''}]"
           f"  updated {s['updated']}, card written {short_time(local_dt(s['cardWritten']), now)}"]
    out += [f"  ⚠ {f['text']}" for f in s["flags"]]
    if s["next"]:
        out.append(f"  next: {one_line(s['next'], 240)}")
    if s["state"]:
        out.append("  state: " + s["state"][0])
        out += [f"         {l}" for l in s["state"][1:]]
        if s["stateMore"]:
            out.append(f"         … +{s['stateMore']} more lines")
    if s["log"]:
        out.append("  log:")
        out += [f"    {x['at'][5:16]}  {x['text']}" for x in s["log"]]
    if s["asks"]["count"]:
        out.append(f"  asks waiting for you ({s['asks']['count']}):")
        out += [f"    {a['id']} [{ago(a['since'])}{', later' if a['snoozedUntil'] else ''}] {a['text']}"
                for a in s["asks"]["items"]]
    for g, label in (("me", "@me"), ("claude", "@claude"), ("others", "others")):
        grp = s["todos"][g]
        if not grp["count"]:
            continue
        shown = f", newest {len(grp['items'])}" if grp["count"] > len(grp["items"]) else ""
        out.append(f"  {label} todos ({grp['count']}{shown}):")
        out += [f"    [{ago(t['since'])}] {'@' + t['owner'] + ' ' if g == 'others' and t['owner'] else ''}{t['text']}"
                for t in grp["items"]]
    if s["sessions"]:
        shown = f", {len(s['sessions'])} shown" if s["sessionsMore"] else ""
        out.append(f"  sessions ({len(s['sessions']) + s['sessionsMore']}{shown}):")
    for x in s["sessions"]:
        bits = [x["state"] + (f" {span(x['idleFor'])}" if x["idleFor"] is not None else ""),
                f"last {short_time(local_dt(x['lastAt']), now)}"]
        if x["context"]:
            c = x["context"]
            bits.append(f"ctx {c['tokens'] // 1000}k/{c['budget'] // 1000}k {c['percent']}%")
        if x["background"]:
            bits.append(f"background: {len(x['background'])} ({x['background'][0]}{', …' if len(x['background']) > 1 else ''})")
        # A session named after its task (the board names them so) says nothing more by name.
        title = re.sub(r"^" + re.escape(s["id"] or "") + r"\s+", "", x["title"] or "")
        title = "" if title == s["title"] else title
        out.append(f"    {x['sessionId'][:8]} {title}".rstrip() + "  ·  " + " · ".join(bits))
        out += [f"      [{m['role']} {short_time(local_dt(m['ts']), now)}] {m['text']}" for m in x["messages"]]
    return "\n".join(out)


def cmd_status(args):
    if args.tasks:
        metas = [parse_card(find_card(t)) for t in dict.fromkeys(args.tasks)]
    else:
        state = load_state()
        live_on = {e.get("task") for sid, e in state.items() if isinstance(e, dict) and e.get("task")
                   and isinstance(pet_session(sid), dict) and pid_alive(pet_session(sid).get("pid"))}
        metas = [parse_card(p) for p in card_paths()]
        if args.focus:
            order = load_focus()
            metas = sorted([m for m in metas if m.get("id") in order and m.get("status") in OPEN_STATUSES],
                           key=lambda m: order.index(m.get("id")))
        else:
            # Every open task, and a finished one only while a session still runs on it.
            metas = [m for m in metas if m.get("status") in OPEN_STATUSES or m.get("id") in live_on]
    now = dt.datetime.now().astimezone()
    state = load_state()
    seen = load_json(os.path.join(HOME_DIR, "state", "todo-seen.json"), {})
    seen = seen if isinstance(seen, dict) else {}
    rows = [task_status(m, state, now, seen) for m in metas]
    if args.flagged:
        rows = [r for r in rows if r["flags"]]
    if args.json:
        print(json.dumps({"now": iso(now), "tasks": rows}, ensure_ascii=False))   # compact: it is read by a model
        return
    if not rows:
        print("no tasks with flags" if args.flagged else "no tasks")
        return
    print("\n\n".join(status_text(r, now) for r in rows))
