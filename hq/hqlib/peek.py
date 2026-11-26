"""Live sessions: transcripts, Peek, jumps and a task's session history."""
import collections
import datetime as dt
import json
import os
import re
import time

from .core import die, load_json, local_dt, one_line, strip_hq_blocks, ts_seconds
from .sessions import LAST_REPLY_MAX, load_state, PET_SESSIONS, pid_alive, saved_reply
from .cards import find_card, parse_card


# ---------------------------------------------------------------- live sessions
# How long a turn held open only by background commands that look like waits (the pet's
# BackgroundWork.isWait: labelled "shell") still counts as running. The pet lets the finish
# through after this; so does the board, or a wrong guess would keep a task in Running all day.
SHELL_WAIT_LIMIT = 20 * 60


def pet_activity(d):
    """A pet session file's state, with that limit applied."""
    st = d.get("state")
    agents = d.get("backgroundAgents") or []
    if st == "busy" and d.get("phase") == "awaiting-agent" and agents and all(a == "shell" for a in agents):
        at = local_dt(d.get("updatedAt"))
        if at and (dt.datetime.now().astimezone() - at).total_seconds() > SHELL_WAIT_LIMIT:
            return "idle"
    return st


def transcript_tail(path, nbytes=600_000):
    if not path or not os.path.exists(path):
        return []
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - nbytes))
        # Not splitlines(): that also breaks at U+0085, U+2028… inside a JSON string.
        lines = f.read().decode("utf-8", "ignore").split("\n")
    return parse_jsonl(lines)


def parse_jsonl(lines):
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def message_role(o):
    """Who said a transcript entry: "user", "assistant", or None. A prompt the user typed while
    Claude was busy is not a user entry: it is an attachment of type queued_command, folded into
    the running turn, so it counts as the user's too (only when a human typed it)."""
    t = o.get("type")
    if t == "attachment":
        a = o.get("attachment") or {}
        if a.get("type") == "queued_command" and (a.get("origin") or {}).get("kind") == "human" \
                and a.get("commandMode", "prompt") == "prompt":
            return "user"
        return None
    return t if t in ("user", "assistant") else None


def message_text(o):
    """Visible text of a transcript entry: the user's typed prompt or Claude's prose."""
    if o.get("isSidechain") or o.get("isMeta") or o.get("isCompactSummary"):
        return None  # compaction summaries are not something anyone said
    c = o.get("message", {}).get("content")
    role = message_role(o)
    if role == "user" and o.get("type") == "attachment":
        c = o["attachment"].get("prompt")
    if role == "user":
        if isinstance(c, str):
            t = c
        elif isinstance(c, list):
            if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
                return None
            t = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
        else:
            return None
        if t.startswith("<") and ("command-" in t[:40] or "local-command" in t[:40]
                                  or "system-reminder" in t[:40] or "task-notification" in t[:40]):
            return None
        return t.strip() or None
    if o.get("type") == "assistant" and isinstance(c, list):
        t = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
        return t.strip() or None
    return None


COMMAND_NAME = re.compile(r"<command-name>\s*(/?[^<\s]+)\s*</command-name>")
COMMAND_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)


def command_text(o):
    """A slash command the user ran ("/compact", "/task T-108"), as typed, else None. Claude Code
    writes it as a user entry of <command-name>/<command-args> tags, which message_text leaves out
    with the rest of its markup; its output (<local-command-stdout>) is a separate entry, not this."""
    if o.get("type") != "user" or o.get("isSidechain") or o.get("isMeta"):
        return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    if not isinstance(c, str) or "<command-name>" not in c[:400]:
        return None
    m = COMMAND_NAME.search(c)
    if not m:
        return None
    name = m.group(1) if m.group(1).startswith("/") else "/" + m.group(1)
    a = COMMAND_ARGS.search(c)
    return f"{name} {a.group(1).strip()}".strip() if a else name


# ---------------------------------------------------------------- peek activity
# Peek shows what a session is doing, not just what was said: Claude's tool calls between the
# messages (one line each, paired with their results), its own todo list, and the turn in
# progress. Rows carry a summary only; `hq peek <sid> --tool <id>` gives one call's full input
# and output when a row is opened, so the list the board polls every few seconds stays small.
PEEK_TOOLS_MAX = 300   # tool rows in one Peek window; older ones drop off (messages never do)
PEEK_BYTES_MAX = 64_000_000   # how far back Peek reads for its n messages
TODO_TOOLS = {"TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"}  # shown as the todo list
NOTE_ID = re.compile(r"<tool-use-id>([^<]+)</tool-use-id>")
NOTE_TASK = re.compile(r"<task-id>([^<]+)</task-id>")   # a background command's or agent's own id
NOTE_STATUS = re.compile(r"<status>([^<]+)</status>")
NOTE_RESULT = re.compile(r"<result>(.*?)(?:</result>|\Z)", re.S)
STOP_TOOLS = {"TaskStop", "KillShell", "KillBash"}   # stop a background command or agent
INTERRUPTED = "[Request interrupted by user"


def background_id(tur):
    """The id a background call goes by once launched: a command's backgroundTaskId, an agent's
    agentId. Task notifications and TaskStop name it, not always the tool_use id."""
    if isinstance(tur, dict) and (tur.get("backgroundTaskId") or tur.get("isAsync")):
        return tur.get("backgroundTaskId") or tur.get("agentId")
    return None


# What a line that starts, ends or stops a background call has in it, as written to the transcript.
BG_MARKERS = (b'"backgroundTaskId"', b'"isAsync"', b"<task-notification>",
              *(f'"{n}"'.encode() for n in sorted(STOP_TOOLS)))
BG_LAUNCH_LOOKBACK = 400   # lines between a call and its result (hooks and progress lines sit between)


def background_entries(path):
    """From the whole transcript, the entries that launch, finish or stop background calls (each
    launch with the call that made it), oldest first: enough for peek_timeline to tell which are
    still running. A long run can be launched far back in a session that kept talking, out of
    reach of any tail read. Read line by line with a byte check first, so tens or hundreds of MB
    cost little time and memory."""
    if not path or not os.path.exists(path):
        return []
    keep, stops = {}, set()   # line no. → entry; stop calls (bytes ids) whose result hasn't come yet
    recent = collections.deque(maxlen=BG_LAUNCH_LOOKBACK)   # (line no., line) to find a launch's call in
    with open(path, "rb") as f:
        for i, line in enumerate(f):
            if line.startswith(b'{"type":"api-request'):
                continue   # a copy of the request, not the conversation
            hit = any(m in line for m in BG_MARKERS) or any(s in line for s in stops)
            if not hit:
                recent.append((i, line))
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            if o.get("type") == "queue-operation":
                # When Claude Code exits with a run going, it kills the run and writes the notice
                # only here: as the queued prompt it never got to deliver.
                t = o.get("content")
                if o.get("operation") == "enqueue" and isinstance(t, str) and "<task-notification>" in t[:200]:
                    keep[i] = {"type": "attachment", "timestamp": o.get("timestamp"),
                               "attachment": {"type": "queued_command", "prompt": t}}
                continue
            recent.append((i, line))
            c = (o.get("message") or {}).get("content")
            if o.get("type") == "assistant" and isinstance(c, list):
                calls = [x.get("id") for x in c if isinstance(x, dict) and x.get("type") == "tool_use"
                         and x.get("name") in STOP_TOOLS and x.get("id")]
                if calls:
                    stops.update(x.encode() for x in calls)
                    keep[i] = o
            elif o.get("type") == "user" and isinstance(c, list):
                for x in c:
                    if not (isinstance(x, dict) and x.get("type") == "tool_result"):
                        continue
                    tid = x.get("tool_use_id") or ""
                    if tid.encode() in stops:
                        stops.discard(tid.encode())
                        keep[i] = o
                    elif tid and (b'"backgroundTaskId"' in line or b'"isAsync"' in line):
                        keep[i] = o
                        keep.update(launch_call(recent, tid, o, i))
                if notification_text(o):
                    keep[i] = o
            elif notification_text(o):
                keep[i] = o
    return [keep[i] for i in sorted(keep)]


def launch_call(recent, tid, result, at):
    """{line no.: entry} for the call a background result answers: its row in peek_timeline. Not
    found (too far back): a stand-in, so the run still counts, under its tool's name alone."""
    b = tid.encode()
    for j, line in reversed(recent):
        if b in line and b'"tool_use"' in line and b'"assistant"' in line:
            try:
                return {j: json.loads(line)}
            except ValueError:
                break
    tur = result.get("toolUseResult") if isinstance(result.get("toolUseResult"), dict) else {}
    name = "Bash" if tur.get("backgroundTaskId") else "Agent"
    return {at - 0.5: {"type": "assistant", "timestamp": result.get("timestamp"),
                 "message": {"content": [{"type": "tool_use", "id": tid, "name": name,
                                          "input": {"command": "…", "description": "…"}}]}}}


def note_status(st):
    """A task notification's <status> as a row status: finished, stopped on purpose, or failed."""
    st = (st or "").strip()
    return "ok" if st == "completed" else "stopped" if st in ("killed", "stopped", "cancelled") else "error"


def interrupted(o):
    """The marker Claude Code writes when you press Esc on a turn (no turn_duration follows)."""
    if o.get("type") != "user" or o.get("isSidechain"):
        return False
    c = (o.get("message") or {}).get("content")
    t = c if isinstance(c, str) else result_text(c) if isinstance(c, list) else ""
    return t.lstrip().startswith(INTERRUPTED)


def entry_ts(o):
    return o.get("timestamp") or (o.get("attachment") or {}).get("timestamp")


def result_text(c):
    """A tool_result's content as text: a string, or text blocks (images as a placeholder)."""
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") if x.get("type") == "text" else "[image]"
                         for x in c if isinstance(x, dict) and x.get("type") in ("text", "image"))
    return ""


def notification_text(o):
    """The text of a <task-notification> entry (a background agent or command finished), else None.
    It arrives as a user entry when the session was idle, or folded into a running turn."""
    if o.get("type") == "attachment":
        a = o.get("attachment") or {}
        t = a.get("prompt") if a.get("type") == "queued_command" else None
    elif o.get("type") == "user":
        c = (o.get("message") or {}).get("content")
        t = c if isinstance(c, str) else result_text(c) if isinstance(c, list) and not any(
            isinstance(x, dict) and x.get("type") == "tool_result" for x in c) else None
    else:
        t = None
    return t if isinstance(t, str) and "<task-notification>" in t[:200] else None


def tool_title(name):
    """mcp__claude_ai_Atlassian__getJiraIssue → Atlassian · getJiraIssue; built-ins as they are."""
    parts = name.split("__")
    if len(parts) >= 3 and parts[0] == "mcp":
        return f"{re.sub(r'^claude_ai_', '', parts[1])} · {'__'.join(parts[2:])}"
    return name


def tool_label(name, inp):
    """The one-line gist of a tool call: the command, the file, the pattern, the agent's job…"""
    inp = inp if isinstance(inp, dict) else {}
    def base(p):
        p = str(p or "").rstrip("/")
        return os.path.basename(p) or p
    if name == "Bash":
        # "cd <repo> && make test" is "make test": the directory is noise in a one-line gist.
        return one_line(re.sub(r"^\s*cd\s+(\"[^\"]*\"|'[^']*'|\S+)\s*(&&|;)\s*", "", str(inp.get("command") or "")))
    if name in ("Edit", "MultiEdit", "Write", "Read", "NotebookEdit"):
        label = base(inp.get("file_path") or inp.get("notebook_path"))
        if name == "Read" and inp.get("offset"):
            label += f":{inp['offset']}"
        return label
    if name in ("Grep", "Glob"):
        return one_line(str(inp.get("pattern") or "") + (f"  in {base(inp['path'])}" if inp.get("path") else ""))
    if name in ("Agent", "Task"):
        return one_line(inp.get("description") or inp.get("prompt"))
    if name == "AskUserQuestion":
        qs = inp.get("questions")
        q0 = qs[0] if isinstance(qs, list) and qs else {}
        return one_line(q0.get("question") if isinstance(q0, dict) else "")
    for k in ("description", "query", "url", "skill", "pattern", "command", "file_path", "title", "name", "summary"):
        if isinstance(inp.get(k), str) and inp[k].strip():
            return one_line(inp[k])
    return one_line(next((v for v in inp.values() if isinstance(v, str) and v.strip()), ""))


def tool_stat(name, tur):
    """What a finished call changed, where that fits in a few characters: "+12 −3" for an edit."""
    if not isinstance(tur, dict):
        return None
    if name in ("Write",) and tur.get("type") == "create":
        return f"new · {len(str(tur.get('content') or '').splitlines())} lines"
    hunks = tur.get("structuredPatch")
    if name in ("Edit", "MultiEdit", "Write") and isinstance(hunks, list):
        add = sum(1 for h in hunks for ln in (h or {}).get("lines") or [] if ln.startswith("+"))
        rem = sum(1 for h in hunks for ln in (h or {}).get("lines") or [] if ln.startswith("-"))
        return f"+{add} −{rem}"
    return None


def peek_timeline(entries):
    """A transcript as Peek shows it, oldest first: the messages (see message_text) and, between
    them, Claude's tool calls, each one {"kind": "tool", id, name, title, label, ts, status, …}.
    status: ok | error | pending (no result yet: running, or cut short) | background (launched in
    the background; becomes ok, error or stopped when its task notification arrives, or stopped
    once TaskStop ends it) | stopped.
    Also events between them, {"kind": "event", "event": …, ts}: "compact" (the context was
    compacted: trigger manual | auto, pre / post tokens) and "hook" (a hook sent Claude's reply
    back: hook, text — what makes the reply after it make sense)."""
    items, tools, last_user = [], {}, None
    by_bg, stops = {}, {}   # background id → its row; a TaskStop call's id → the id it stops
    for o in entries:
        if o.get("isSidechain"):
            continue
        ts = entry_ts(o)
        c = (o.get("message") or {}).get("content")
        at = len(items)   # an entry holding text before its tool calls shows the text first
        text_first = False
        if o.get("type") == "assistant" and isinstance(c, list):
            kinds = [x.get("type") for x in c if isinstance(x, dict)]
            text_first = "text" in kinds and kinds.index("text") < (kinds.index("tool_use") if "tool_use" in kinds else len(kinds))
            for x in c:
                if isinstance(x, dict) and x.get("type") == "tool_use" and x.get("name") in STOP_TOOLS:
                    inp = x.get("input") if isinstance(x.get("input"), dict) else {}
                    stops[x.get("id")] = inp.get("task_id") or inp.get("shell_id") or inp.get("bash_id")
                if isinstance(x, dict) and x.get("type") == "tool_use" and x.get("id") \
                        and x.get("name") not in TODO_TOOLS:
                    name = x.get("name") or "?"
                    it = {"kind": "tool", "id": x["id"], "name": name, "title": tool_title(name),
                          "label": tool_label(name, x.get("input")), "ts": ts, "status": "pending"}
                    tools[x["id"]] = it
                    items.append(it)
        elif o.get("type") == "user" and isinstance(c, list):
            results = [x for x in c if isinstance(x, dict) and x.get("type") == "tool_result"]
            tur = o.get("toolUseResult") if len(results) == 1 else None
            for x in results:
                # A TaskStop that worked ends the background call it names.
                target = by_bg.get(stops.get(x.get("tool_use_id")))
                if target and not x.get("is_error") and target["status"] == "background":
                    target.update(status="stopped", endTs=ts, bg="stopped")
                it = tools.get(x.get("tool_use_id"))
                if not it:
                    continue
                it["endTs"] = ts
                if x.get("is_error"):
                    it["status"] = "error"
                elif background_id(tur) or (isinstance(tur, dict) and tur.get("isAsync")):
                    it["status"] = "background"
                    if background_id(tur):
                        by_bg[background_id(tur)] = it
                else:
                    it["status"] = "ok"
                stat = tool_stat(it["name"], tur)
                if stat:
                    it["stat"] = stat
        if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
            md = o.get("compactMetadata") or {}
            items.append({"kind": "event", "event": "compact", "trigger": md.get("trigger") or "",
                          "pre": md.get("preTokens"), "post": md.get("postTokens"), "ts": ts})
            continue
        a = o.get("attachment") if o.get("type") == "attachment" else None
        if isinstance(a, dict) and a.get("type") == "hook_blocking_error":
            be = a.get("blockingError")
            text = be.get("blockingError") if isinstance(be, dict) else be
            items.append({"kind": "event", "event": "hook", "hook": a.get("hookName") or a.get("hookEvent") or "",
                          "text": str(text or "").strip()[:2000], "ts": ts})
            continue
        note = notification_text(o)
        if note:
            # It names the call by its tool_use id, or only by the task's own id (an agent's
            # agentId); a resumed agent's later notifications name the SendMessage call instead.
            # One notification can list several tasks (those an ended session left running).
            m = NOTE_ID.search(note)
            st = (NOTE_STATUS.search(note) or [None, ""])[1].strip()
            for it in [tools.get(m.group(1).strip()) if m else None] + [by_bg.get(k.strip()) for k in NOTE_TASK.findall(note)]:
                if it and it["status"] == "background":
                    it.update(status=note_status(st), endTs=ts, bg=st or "done")
            continue
        cmd = command_text(o)
        if cmd:
            # /compact is written once the compaction is over, after the line saying it happened
            # (its own timestamp is from when it was typed): it goes before that line, as it ran.
            row = {"kind": "msg", "role": "user", "text": cmd, "ts": ts, "command": True}
            k, at_s = len(items), ts_seconds(ts)
            while k and items[k - 1]["kind"] == "event" and items[k - 1]["event"] == "compact" \
                    and at_s is not None and (ts_seconds(items[k - 1]["ts"]) or 0) > at_s:
                k -= 1
            items.insert(k, row)
            last_user = {"text": cmd, "ts": ts}
            continue
        t = message_text(o)
        if not t:
            continue
        role = message_role(o)
        if role == "user":
            # The same prompt is now and then written twice: as the user entry that starts a
            # turn and, a moment later, as a queued_command folded into it. Show it once.
            if o.get("type") == "attachment" and last_user and last_user["text"] == t:
                a, b = ts_seconds(last_user["ts"]), ts_seconds(ts)
                if a is not None and b is not None and abs(b - a) <= 10:
                    continue
            last_user = {"text": t, "ts": ts}
        items.insert(at if text_first else len(items), {"kind": "msg", "role": role, "text": t, "ts": ts})
    return items


def peek_window(path, n):
    """The last n messages with the tool calls among them (at most PEEK_TOOLS_MAX, newest kept),
    and the transcript entries they were read from. Reads further back until it has n messages
    (or PEEK_BYTES_MAX, or the start of the file): screenshots sit in the transcript as base64, so
    a session that looked at a few dozen of them has only a handful of messages in its last 6 MB.
    Each step reads and parses only the bytes the last one did not, and the board polls this
    every few seconds: the worst case, a screenshot-heavy 64 MB tail, takes ~0.2 s."""
    entries, items = [], []
    if not path or not os.path.exists(path):
        return items, entries
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        done, head = size, b""   # [done, size) is parsed; head = the cut line just before it
        for nbytes in (600_000, 6_000_000, 24_000_000, PEEK_BYTES_MAX):
            start = max(0, size - nbytes)
            f.seek(start)
            buf = f.read(done - start) + head
            head = b""
            if start > 0:   # the first line is cut: keep it for the next step, which reads its start
                cut = buf.find(b"\n")
                head, buf = (buf, b"") if cut < 0 else (buf[:cut], buf[cut + 1:])
            # Not splitlines(): that also breaks at U+0085, U+2028… inside a JSON string.
            entries = parse_jsonl(buf.decode("utf-8", "ignore").split("\n")) + entries
            done = start
            items = peek_timeline(entries)
            at = [i for i, it in enumerate(items) if it["kind"] == "msg"]
            if len(at) >= n:
                items = items[at[-n]:]
                break
            if start == 0:
                break
    tools = [it for it in items if it["kind"] == "tool"]
    if len(tools) > PEEK_TOOLS_MAX:
        drop = {id(it) for it in tools[:-PEEK_TOOLS_MAX]}
        items = [it for it in items if id(it) not in drop]
    return items, entries


def recent_messages(path, n=8):
    items, _ = peek_window(path, n)
    return [{"role": it["role"], "text": it["text"], "ts": it["ts"]} for it in items if it["kind"] == "msg"]


def turn_stats(entries, path=None):
    """The turn in progress, or else the last one: when it started, Claude's output tokens in it,
    how long it took (finished turns: Claude Code logs a turn_duration when one ends), and the
    context size at its last reply."""
    ends = [i for i, o in enumerate(entries) if o.get("type") == "system" and o.get("subtype") == "turn_duration"]
    def spoke(o):
        return not o.get("isSidechain") and (o.get("type") == "assistant" or (
            o.get("type") == "user" and (message_text(o) or notification_text(o))))
    lo, hi, ms = 0, len(entries), None
    if ends and not any(spoke(o) for o in entries[ends[-1] + 1:]):
        lo = ends[-2] + 1 if len(ends) > 1 else 0
        hi, ms = ends[-1], entries[ends[-1]].get("durationMs")
    elif ends:
        lo = ends[-1] + 1
    else:  # no turn markers (older Claude Code): from the last thing the user said
        lo = next((i for i in range(len(entries) - 1, -1, -1)
                   if message_role(entries[i]) == "user" and message_text(entries[i])
                   and not interrupted(entries[i]) and not notification_text(entries[i])), 0)
    # Esc on a turn writes no turn_duration, only a marker: the turn ends there, and the next
    # one starts after it (else it would count the interrupted turn and the idle time since).
    cut = [i for i in range(lo, hi) if interrupted(entries[i])]
    if cut and ms is None:
        if any(spoke(o) and not interrupted(o) for o in entries[cut[-1] + 1:hi]):
            lo = cut[-1] + 1
        else:
            prev = cut[-2] + 1 if len(cut) > 1 else lo
            seg = entries[prev:cut[-1]]
            a = next((entry_ts(o) for o in seg if spoke(o) and entry_ts(o)), None)
            b = entry_ts(entries[cut[-1]])
            if a and b and ts_seconds(a) is not None and ts_seconds(b) is not None:
                lo, hi, ms = prev, cut[-1], int((ts_seconds(b) - ts_seconds(a)) * 1000)
    seg = entries[lo:hi]
    start = next((entry_ts(o) for o in seg if spoke(o) and entry_ts(o)), None)
    seen, out, ctx, last = set(), 0, None, lo - 1
    for i, o in enumerate(seg, lo):
        if o.get("type") != "assistant" or o.get("isSidechain"):
            continue
        msg = o.get("message") or {}
        u = msg.get("usage") or {}
        if msg.get("id") not in seen:   # one reply is written as several entries, same usage
            seen.add(msg.get("id"))
            out += u.get("output_tokens") or 0
        n = sum(u.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        if n:
            ctx, last = n, i
    if start is None:
        return None
    post = compacted_since(entries, last, path)
    if post is not None:
        ctx = post or None
    return {"start": start, "done": ms is not None, "ms": ms, "tokens": out, "context": ctx}


def queued_messages(entries):
    """What waits in Claude Code's queue: messages sent while the session was busy that it has not
    taken in yet, [{text, ts}], oldest first. Claude Code logs the queue in the transcript as
    queue-operation lines: `enqueue` and `remove` carry the text, `dequeue` doesn't.
    Matched by text, not replayed as a FIFO: a stale entry (an enqueue written just before Claude
    Code exited, a notification enqueued twice, an enqueue with no text) would make every later
    dequeue pop the wrong one. So an entry leaves when a `remove` has its text, or when a user
    entry — a prompt, a queued_command attachment, a meta prompt from /loop or another session —
    holds it. A queued message is always taken in by the end of the next turn (measured
    2026-11-24 over 169 enqueues in 91 transcripts), so one still there after a turn ended and a
    different prompt started the next is stale and dropped: a `!` command, which runs without
    coming back as its own text, or a queue lost to a restart. Task notifications and enqueues
    with no text are not shown; nobody typed them here. Only the window peek read is seen: a
    queue is short-lived, so its start is in it."""
    def text(c):
        if isinstance(c, list):
            c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
        return c.strip() if isinstance(c, str) else ""
    q = []   # [text, ts, a turn has ended since]
    for o in entries:
        kind = o.get("type")
        if kind == "system" and o.get("subtype") == "turn_duration":
            for x in q:
                x[2] = True
            continue
        if kind == "queue-operation":
            op, t = o.get("operation"), text(o.get("content"))
            if op == "enqueue" and t and not t.startswith("<task-notification>"):
                q.append([t, o.get("timestamp"), False])
            elif op == "remove" and t:
                q = [x for i, x in enumerate(q) if i != next((j for j, y in enumerate(q) if y[0] == t), -1)]
            continue
        if kind == "attachment":
            a = o.get("attachment") or {}
            t = text(a.get("prompt")) if a.get("type") == "queued_command" else ""
        elif kind == "user" and not o.get("isSidechain"):
            c = (o.get("message") or {}).get("content")
            t = "" if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c) else text(c)
        else:
            continue
        if not t:
            continue
        # Whole lines: several queued messages can come in as one prompt, joined by newlines.
        hit = next((i for i, x in enumerate(q) if f"\n{x[0]}\n" in f"\n{t}\n"), None)
        if hit is not None:
            q.pop(hit)
        elif not t.startswith("<task-notification>"):
            q = [x for x in q if not x[2]]
    return [{"text": x[0], "ts": x[1]} for x in q]


def latest_todos(entries):
    """Claude's own todo list as it last stood: the latest TodoWrite, or the list the
    TaskCreate / TaskUpdate tools have built since. [{text, status, active}], or None."""
    items, creating = None, {}
    for o in entries:
        if o.get("isSidechain"):
            continue
        c = (o.get("message") or {}).get("content")
        if not isinstance(c, list):
            continue
        for x in c:
            if not isinstance(x, dict):
                continue
            inp = x.get("input") if isinstance(x.get("input"), dict) else {}
            if x.get("type") == "tool_use" and x.get("name") == "TodoWrite" and isinstance(inp.get("todos"), list):
                items = {str(i): {"text": t.get("content") or "", "status": t.get("status") or "pending",
                                  "active": t.get("activeForm") or ""}
                         for i, t in enumerate(inp["todos"]) if isinstance(t, dict)}
            elif x.get("type") == "tool_use" and x.get("name") == "TaskCreate":
                creating[x.get("id")] = inp
            elif x.get("type") == "tool_use" and x.get("name") == "TaskUpdate" and items is not None:
                t = items.get(str(inp.get("taskId")))
                if t is not None:
                    if inp.get("status") == "deleted":
                        items.pop(str(inp.get("taskId")))
                        continue
                    t["status"] = inp.get("status") or t["status"]
                    t["text"] = inp.get("subject") or t["text"]
                    t["active"] = inp.get("activeForm") or t["active"]
            elif x.get("type") == "tool_result" and x.get("tool_use_id") in creating and not x.get("is_error"):
                inp = creating.pop(x["tool_use_id"])
                tur = o.get("toolUseResult")
                tid = ((tur.get("task") or {}).get("id") if isinstance(tur, dict) else None) \
                    or (re.search(r"#(\d+)", result_text(x.get("content"))) or [None, None])[1]
                if tid is not None:
                    items = items if items is not None else {}
                    items[str(tid)] = {"text": inp.get("subject") or "", "status": "pending",
                                       "active": inp.get("activeForm") or ""}
    return list(items.values()) if items else None


def tool_detail(path, tool_id, cap_in=100_000, cap_out=200_000):
    """One tool call in full, for an opened Peek row: its input and output as text (an edit's
    output is its diff; a background job's, its result once it has finished)."""
    use = res = tur = note = None
    use_ts = end_ts = None
    bg = stop_ids = None   # once launched in the background: its own id, and TaskStop calls on it
    stopped = None
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            if tool_id not in line and not (bg and bg in line) \
                    and not (stop_ids and any(i in line for i in stop_ids)):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            # Only the conversation's own entries: request records and snapshots repeat the
            # call without its toolUseResult (an edit's diff lives there).
            c = (o.get("message") or {}).get("content") if o.get("type") in ("user", "assistant") \
                and not o.get("isSidechain") else None
            for x in c if isinstance(c, list) else []:
                if isinstance(x, dict) and x.get("type") == "tool_use" and x.get("id") == tool_id and not use:
                    use, use_ts = x, entry_ts(o)
                elif isinstance(x, dict) and x.get("type") == "tool_result" and x.get("tool_use_id") == tool_id and not res:
                    res, end_ts = x, entry_ts(o)
                    tur = o.get("toolUseResult")
                    bg = background_id(tur) if not x.get("is_error") else None
                    stop_ids = set() if bg else None
                elif bg and isinstance(x, dict) and x.get("type") == "tool_use" and x.get("name") in STOP_TOOLS \
                        and bg in json.dumps(x.get("input") or {}):
                    stop_ids.add(x.get("id"))
                elif stop_ids and isinstance(x, dict) and x.get("type") == "tool_result" \
                        and x.get("tool_use_id") in stop_ids and not x.get("is_error") and not note and not stopped:
                    stopped = entry_ts(o)
            t = notification_text(o)
            m = NOTE_ID.search(t) if t else None
            if t and not note and ((m and m.group(1).strip() == tool_id)
                                   or (bg and bg in [k.strip() for k in NOTE_TASK.findall(t)])):
                note, end_ts = t, entry_ts(o)
    if not use:
        return None
    name, inp = use.get("name") or "?", use.get("input") if isinstance(use.get("input"), dict) else {}
    hunks = tur.get("structuredPatch") if isinstance(tur, dict) else None
    diff = "\n".join(f"@@ -{h.get('oldStart')},{h.get('oldLines')} +{h.get('newStart')},{h.get('newLines')} @@\n"
                     + "\n".join(h.get("lines") or []) for h in hunks if isinstance(h, dict)) if hunks else ""
    if name == "Bash":
        text_in = (f"# {inp['description']}\n" if inp.get("description") else "") + f"$ {inp.get('command', '')}"
    elif name in ("Edit", "MultiEdit") and not diff:
        text_in = f"{inp.get('file_path', '')}\n--- old\n{inp.get('old_string', '')}\n--- new\n{inp.get('new_string', '')}"
    elif name in ("Edit", "MultiEdit", "Read"):
        text_in = str(inp.get("file_path", "")) + "".join(
            f"  {k}={inp[k]}" for k in ("offset", "limit", "replace_all") if inp.get(k))
    elif name == "Write":
        text_in = f"{inp.get('file_path', '')}\n\n{inp.get('content', '')}"
    elif name in ("Agent", "Task"):
        text_in = f"{inp.get('description', '')}" + (f"  ({inp['subagent_type']})" if inp.get("subagent_type") else "") \
            + f"\n\n{inp.get('prompt', '')}"
    else:
        text_in = json.dumps(inp, ensure_ascii=False, indent=1)
    if diff and name in ("Edit", "MultiEdit", "Write") and not (res or {}).get("is_error"):
        text_out = diff
    else:
        text_out = result_text((res or {}).get("content"))
    if note:
        r = NOTE_RESULT.search(note)
        st = (NOTE_STATUS.search(note) or [None, ""])[1].strip()
        text_out = (text_out + "\n\n" if text_out else "") + f"— {st or 'finished'} —\n" + (r.group(1).strip() if r else "")
    elif stopped:
        text_out = (text_out + "\n\n" if text_out else "") + "— stopped (TaskStop) —"
        end_ts = stopped
    return {"id": tool_id, "name": name, "title": tool_title(name), "ts": use_ts, "endTs": end_ts,
            "error": bool((res or {}).get("is_error")), "done": res is not None,
            "input": text_in[:cap_in], "inputChars": len(text_in),
            "output": text_out[:cap_out], "outputChars": len(text_out)}


def session_title(entries):
    for o in reversed(entries):
        if o.get("type") == "custom-title" and o.get("customTitle"):
            return o["customTitle"]
    return None


def pet_session(sid):
    return load_json(os.path.join(PET_SESSIONS, f"{sid}.json"), None) if sid and "/" not in sid else None


def live_sessions():
    state = load_state()
    out = []
    if not os.path.isdir(PET_SESSIONS):
        return out
    for name in os.listdir(PET_SESSIONS):
        if not name.endswith(".json"):
            continue
        d = load_json(os.path.join(PET_SESSIONS, name), None)
        if not isinstance(d, dict) or not pid_alive(d.get("pid")):
            continue
        sid = d.get("sessionId") or name[:-5]
        last, reply = None, None
        # Screenshots and big tool results can fill the tail; widen once if needed.
        for nbytes in (300_000, 3_000_000):
            entries = transcript_tail(d.get("transcript"), nbytes)
            for o in reversed(entries):
                if o.get("type") == "assistant":
                    # A reply that was only bookkeeping (the answer to a write-back nudge) is not
                    # what the session last said: keep looking.
                    last = strip_hq_blocks(message_text(o) or "", ("hq-resolved", "hq-update"))
                    if last:
                        break
            if last:
                break
        # The reply its last turn ended on. Idle, that is the end of the transcript; while a turn
        # runs, it is what the Stop hook saved, unless the transcript's tail reaches a newer one:
        # a turn ended with Esc, or run while the session was unbound, never reached that hook.
        act = pet_activity(d)   # a wait-only hold past its limit is over: idle, its reply is the last one
        turn_open = act in ("busy", "waiting")
        found = last_reply(entries, turn_open)
        saved = saved_reply(sid) if turn_open else None
        if saved and not (found and (ts_seconds(found.get("ts")) or 0) > (ts_seconds(saved.get("ts")) or 0)):
            reply = {"text": saved["text"], "ts": saved.get("ts"), "prev": True}
        else:
            reply = found or (None if turn_open else saved_reply(sid))
        out.append({
            "sessionId": sid,
            "title": session_title(entries),
            "project": d.get("project") or os.path.basename(d.get("cwd", "")),
            "cwd": d.get("cwd"),
            "state": act,
            "waitingOn": d.get("waitingOn"),
            # "compacting" while the context is being compacted
            "phase": (d.get("phase") or "") if act == d.get("state") else "",
            "updatedAt": d.get("updatedAt"),
            "terminal": d.get("terminal"),
            "transcript": d.get("transcript"),
            "task": state.get(sid, {}).get("task"),
            # Set when this session's own hq-update finished its task: {task, status, at}.
            "finished": state.get(sid, {}).get("finished"),
            "lastText": (last or "")[:400],
            "lastReply": reply,
        })
    out.sort(key=lambda s: s.get("updatedAt") or "", reverse=True)
    return out


def last_reply(entries, turn_open):
    """What the session said at the end of its last finished turn: {text, ts, prev}, or None. Its
    last reply without HQ's blocks (a reply that was only those says nothing: the one before it
    counts); Claude Code's own stand-ins (model <synthetic>) and compaction summaries are not
    replies. While a turn is going (turn_open), what it says mid-turn is not where it got to: the
    reply is the one before the turn's prompt, and prev says so."""
    # A turn starts with a user entry: a prompt, a slash command, or a background task's
    # notification reaching an idle session. Not an attachment: a prompt queued while Claude
    # works, or a notification arriving then, is folded into the turn already going.
    def starts(o):
        return o.get("type") == "user" and not o.get("isSidechain") and not o.get("isMeta") \
            and bool(message_text(o) or notification_text(o) or command_text(o))
    hi = len(entries)
    if turn_open:
        hi = next((i for i in range(len(entries) - 1, -1, -1) if starts(entries[i])), 0)
    for o in reversed(entries[:hi]):
        if o.get("type") != "assistant" or o.get("isSidechain") \
                or (o.get("message") or {}).get("model") == "<synthetic>":
            continue
        t = strip_hq_blocks(message_text(o) or "").strip()
        if t:
            return {"text": t[:LAST_REPLY_MAX], "ts": entry_ts(o), "prev": bool(turn_open)}
    return None


def cmd_sessions(args):
    s = live_sessions()
    if args.json:
        print(json.dumps(s, ensure_ascii=False, indent=1))
        return
    for x in s:
        print(f"{x['sessionId'][:8]}  {x['state'] or '?':<8} {x['task'] or '-':<6} "
              f"{x['project']:<20} {x['title'] or ''}")


PET_JUMPS = os.path.expanduser("~/.claude/pet/jumps.jsonl")
JUMP_STATES = ["permission", "question", "replied", "working", "agent", "interrupted", "idle", "gone"]
JUMP_SOURCES = ["board-card", "board-sessions", "board-peek", "board-context", "board",
                "pet-list", "pet-finished", "pet-notice", "hotkey"]
PEEK_RECENT = 600   # a Peek this many seconds before the jump counts as "read it first"


def jump_summary(days, now=None):
    """Jumps of the last `days` days from the pet's jump log, counted by state x source. A click
    that opened the session's task on the board instead (terminal "board", Settings → "Clicking a
    Session Opens") is no jump to a terminal: counted apart, as boardOpens."""
    since = (now or time.time()) - days * 86400
    events = []
    try:
        with open(PET_JUMPS, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                    t = dt.datetime.fromisoformat(str(e["at"]).replace("Z", "+00:00"))
                except (ValueError, KeyError, TypeError):
                    continue
                if t.tzinfo is None:   # the pet writes UTC; a stamp without a zone is read as UTC too
                    t = t.replace(tzinfo=dt.timezone.utc)
                if t.timestamp() >= since:
                    events.append(e)
    except FileNotFoundError:
        pass
    board_opens = sum(1 for e in events if e.get("terminal") == "board")
    events = [e for e in events if e.get("terminal") != "board"]
    grid, by_state, by_source, peeked = {}, {}, {}, {}
    for e in events:
        st, src = (str(e.get(k)) if e.get(k) not in (None, "") else "?" for k in ("state", "source"))
        grid.setdefault(st, {}).setdefault(src, 0)
        grid[st][src] += 1
        by_state[st] = by_state.get(st, 0) + 1
        by_source[src] = by_source.get(src, 0) + 1
        if isinstance(e.get("peekedAgo"), int) and e["peekedAgo"] <= PEEK_RECENT:
            peeked[st] = peeked.get(st, 0) + 1
    order = lambda known, seen: [k for k in known if k in seen] + sorted(k for k in seen if k not in known)
    return {"days": days, "total": len(events), "boardOpens": board_opens, "grid": grid, "byState": by_state, "bySource": by_source,
            "peekedFirst": peeked, "states": order(JUMP_STATES, by_state),
            "sources": order(JUMP_SOURCES, by_source)}


def cmd_jumps(args):
    r = jump_summary(args.days)
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return
    opens = (f"; {r['boardOpens']} clicks opened the task on the board instead, not counted"
             if r["boardOpens"] else "")
    if not r["total"]:
        print(f"no jumps in the last {args.days} days (log: {PET_JUMPS}){opens}")
        return
    cols = r["sources"]
    w = max([len("state")] + [len(x) for x in r["states"]])
    print(f"{r['total']} jumps in the last {args.days} days, by state x where it was clicked\n")
    print(f"{'state':<{w}}  " + "  ".join(f"{c:>{len(c)}}" for c in cols) + "  total  peeked")
    for st in r["states"]:
        row = r["grid"].get(st, {})
        print(f"{st:<{w}}  " + "  ".join(f"{row.get(c, 0) or '.':>{len(c)}}" for c in cols)
              + f"  {r['byState'][st]:>5}  {r['peekedFirst'].get(st, 0):>6}")
    print(f"{'total':<{w}}  " + "  ".join(f"{r['bySource'][c]:>{len(c)}}" for c in cols) + f"  {r['total']:>5}")
    print(f"\npeeked = its Peek was open on the board in the {PEEK_RECENT // 60} minutes before the jump{opens}")


def find_transcript(prefix):
    """A session's transcript by id or id prefix: the pet's record if the session is live,
    else a search of ~/.claude/projects (so closed sessions can still be read)."""
    if not prefix or "/" in prefix or len(prefix) < 6:
        return None, False
    for name in os.listdir(PET_SESSIONS) if os.path.isdir(PET_SESSIONS) else []:
        if name.startswith(prefix):
            d = load_json(os.path.join(PET_SESSIONS, name), {})
            if d.get("transcript") and os.path.exists(d["transcript"]):
                return d["transcript"], pid_alive(d.get("pid"))
    import glob
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{glob.escape(prefix)}*.jsonl"))
    if not hits:
        return None, False
    return max(hits, key=os.path.getmtime), False


def session_skills(path):
    """The skills a session can run as slash commands, as Claude Code itself listed them: it
    writes a skill_listing attachment when the session starts (and again after a compaction or
    a resume), plus one for each skill that turns up later. So the newest full listing and the
    additions after it — this session's project, user and plugin skills, nothing guessed.
    [{name, desc}] in the listing's order; [] when the transcript has none."""
    import mmap
    key = b'"type":"skill_listing"'
    found = []
    with open(path, "rb") as f:
        if os.fstat(f.fileno()).st_size == 0:
            return []
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            end = len(m)
            while True:
                at = m.rfind(key, 0, end)
                if at < 0:
                    break
                start = m.rfind(b"\n", 0, at) + 1
                stop = m.find(b"\n", at)
                stop = len(m) if stop < 0 else stop
                end = start
                try:
                    a = (json.loads(m[start:stop]) or {}).get("attachment") or {}
                except ValueError:
                    continue
                if a.get("type") != "skill_listing":
                    continue
                found.append(a)
                if a.get("isInitial"):
                    break
    # Oldest first: a name keeps its first place, and a later listing of it (a skill that
    # changed) brings its new description.
    order, seen, desc = [], set(), {}
    for a in reversed(found):
        names = [n for n in a.get("names") or [] if isinstance(n, str)]
        # "- name: description" per line; a plugin's name has a colon of its own, so match the
        # longest listed name each line starts with.
        for line in str(a.get("content") or "").split("\n"):
            hit = max((n for n in names if line.startswith(f"- {n}:")), key=len, default=None)
            if hit:
                desc[hit] = line[len(hit) + 3:].strip()
        for n in names:
            desc.setdefault(n, "")
            if n not in seen:
                seen.add(n)
                order.append(n)
    return [{"name": n, "desc": one_line(desc[n], 140)} for n in order]


def _front(path):
    """A skill or command file's frontmatter as {key: value}: flat `key: value` lines, and a
    `>` / `|` block's indented lines joined into one. {} when there is none or it can't be read."""
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            text = f.read(16384)
    except OSError:
        return {}
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    out, block = {}, None
    for line in lines[1:]:
        if line.strip() == "---":
            return out
        if block and (line[:1].isspace() or not line.strip()):
            out[block] = (out[block] + " " + line.strip()).strip()
            continue
        block = None
        k, sep, v = line.partition(":")
        if sep and k and not k[0].isspace():
            k, v = k.strip(), v.strip()
            if v[:1] in (">", "|"):
                block, v = k, ""
            out[k] = v.strip("'\"")
    return {}


def _flag(v):
    """A frontmatter true/false the way Claude Code reads one: yes/no, on/off, 1/0 too. None if neither."""
    v = str(v).strip().lower()
    return True if v in ("true", "yes", "on", "1") else False if v in ("false", "no", "off", "0") else None


def hidden_skills(cwd):
    """Skills and commands marked `disable-model-invocation: true`. Claude Code leaves them out
    of the skill listing (it is the list Claude may call), yet you can still type them — so they
    are read from the same places it reads them: your ~/.claude, the project's .claude (the
    session's folder and the folders above it, short of your home), and the plugins enabled for
    that folder (user settings, then the project's settings and settings.local), whose names get
    the plugin's prefix. [{name, desc}]. Never raises: a folder or file it can't read is skipped."""
    home = os.path.expanduser("~")
    real_home = os.path.realpath(home)
    roots, projects = [(os.path.join(home, ".claude"), "")], []
    d = os.path.realpath(cwd) if cwd else ""
    while d and d != real_home and d != os.path.dirname(d):
        projects.append(d)
        roots.append((os.path.join(d, ".claude"), ""))
        d = os.path.dirname(d)

    def obj(path, *keys):
        x = load_json(path, {})
        for k in keys:
            x = x.get(k) if isinstance(x, dict) else None
        return x if isinstance(x, dict) else {}

    enabled = dict(obj(os.path.join(home, ".claude", "settings.json"), "enabledPlugins"))
    for proj in reversed(projects):   # nearer folders win
        for f in ("settings.json", "settings.local.json"):
            enabled.update(obj(os.path.join(proj, ".claude", f), "enabledPlugins"))
    installed = obj(os.path.join(home, ".claude", "plugins", "installed_plugins.json"), "plugins")
    for key, on in enabled.items():
        recs = installed.get(key)
        recs = [x for x in recs if isinstance(x, dict)] if isinstance(recs, list) else []
        # A project-scope install counts only in that project (or below it).
        recs = [x for x in recs if not x.get("projectPath")
                or os.path.realpath(str(x["projectPath"])) in projects]
        path = next((x.get("installPath") for x in reversed(recs)
                     if isinstance(x.get("installPath"), str) and os.path.isdir(x["installPath"])), None)
        if on is True and path:
            roots.append((path, str(key).split("@")[0] + ":"))

    def listdir(d):
        try:
            return sorted(os.listdir(d))
        except OSError:
            return []

    out, seen = [], set()
    for root, prefix in roots:
        files = [(os.path.join(root, "skills", n, "SKILL.md"), n) for n in listdir(os.path.join(root, "skills"))]
        files += [(os.path.join(root, "commands", n), n[:-3]) for n in listdir(os.path.join(root, "commands")) if n.endswith(".md")]
        for path, default in files:
            fm = _front(path)
            if _flag(fm.get("disable-model-invocation", "")) is not True or _flag(fm.get("user-invocable", "")) is False:
                continue
            name = fm.get("name") or default
            if prefix and not name.startswith(prefix):
                name = prefix + name
            if name not in seen:
                seen.add(name)
                out.append({"name": name, "desc": one_line(fm.get("description", ""), 140)})
    return out


def transcript_cwd(path):
    """The folder a session runs in, from the first transcript lines that say."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _, line in zip(range(200), f):
                if '"cwd"' in line:
                    try:
                        c = json.loads(line).get("cwd")
                    except ValueError:
                        continue
                    if c:
                        return c
    except OSError:
        pass
    return None


def cmd_peek(args):
    path, live = find_transcript(args.session)
    if args.commands:
        skills = session_skills(path) if path else []
        if path:
            listed = {x["name"] for x in skills}
            try:
                skills += [x for x in hidden_skills(transcript_cwd(path)) if x["name"] not in listed]
            except Exception:   # the transcript's own list matters more than these extras
                pass
        if args.json:
            print(json.dumps({"found": bool(path), "skills": skills}, ensure_ascii=False, indent=1))
        else:
            for x in skills:
                print(f"/{x['name']}  {x['desc']}")
        return
    if args.tool:
        d = tool_detail(path, args.tool) if path else None
        if not d:
            die(f"no tool call {args.tool} in session {args.session}")
        if args.json:
            print(json.dumps(d, ensure_ascii=False, indent=1))
        else:
            print(f"[{d['title']}]\n{d['input']}\n\n{d['output']}")
        return
    items, entries = peek_window(path, args.n) if path else ([], [])
    msgs = [{"role": it["role"], "text": it["text"], "ts": it["ts"]} for it in items if it["kind"] == "msg"]
    if args.json:
        if args.meta:
            cwd = next((o.get("cwd") for o in reversed(entries) if o.get("cwd")), None)
            # items: the messages with the tool calls between them; turn: the turn in progress
            # (or the last one); todos: Claude's own todo list; queued: messages waiting in Claude
            # Code's queue. `messages` stays for older readers.
            print(json.dumps({"session": os.path.basename(path)[:-6] if path else args.session,
                              "found": bool(path), "live": live, "title": session_title(entries),
                              "cwd": cwd, "messages": msgs, "items": items,
                              "turn": turn_stats(entries, path), "todos": latest_todos(entries),
                              "queued": queued_messages(entries)},
                             ensure_ascii=False, indent=1))
        else:
            print(json.dumps(msgs, ensure_ascii=False, indent=1))
        return
    for m in msgs:
        print(f"[{m['role']}] {m['text']}\n")


def cmd_history(args):
    """The sessions that have worked on a task (newest first), with what's needed to resume one:
    full id, the directory it ran in, its name, when it was last active, its last words."""
    meta = parse_card(find_card(args.task))
    seen, rows = set(), []
    for short in reversed(list(meta.get("sessions") or [])):
        path, live = find_transcript(str(short))
        if not path or path in seen:
            continue
        seen.add(path)
        entries = transcript_tail(path, 300_000)
        gists = (strip_hq_blocks(message_text(o) or "", ("hq-resolved", "hq-update"))
                 for o in reversed(entries) if o.get("type") == "assistant")
        last = next((g for g in gists if g), "")
        rows.append({
            "sessionId": os.path.basename(path)[:-6],
            "cwd": next((o.get("cwd") for o in reversed(entries) if o.get("cwd")), None),
            "title": session_title(entries),
            "lastAt": dt.datetime.fromtimestamp(os.path.getmtime(path)).astimezone().isoformat(timespec="seconds"),
            "live": live,
            "lastText": " ".join(last.split())[:160],
        })
    rows.sort(key=lambda r: r["lastAt"], reverse=True)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return
    for r in rows:
        print(f"{r['sessionId'][:8]}  {r['lastAt'][:16]}  {'live ' if r['live'] else ''}{r['title'] or ''}  {r['cwd'] or ''}")


def compacted_since(entries, i, path=None):
    """The context the last compaction after entries[i] left, or None when there was none
    (0 when its boundary does not say). /compact writes no reply, so until the next one this is
    the session's size. The boundary's postTokens is the conversation alone: the next request
    also sends the system prompt, the tools and the files Claude Code attaches again, 25-55k
    more. So add what that came to (compaction_overhead) — the pet counts it the same way."""
    cut = next((o for o in reversed(entries[i + 1:])
                if o.get("type") == "system" and o.get("subtype") == "compact_boundary"), None)
    if cut is None:
        return None
    post = (cut.get("compactMetadata") or {}).get("postTokens")
    if not isinstance(post, int) or post <= 0:
        return 0
    return post + (compaction_overhead(path) if path else 0)


def compaction_overhead(path):
    """What a request sends on top of the conversation: the latest compaction that has a reply
    after it, that reply's size less the boundary's postTokens; before any, the session's first
    reply (a system prompt, the tools and one prompt; at most 60k). 0 when the transcript has neither.
    Reads by bytes from the boundaries, so a long transcript costs a few finds."""
    import mmap
    bkey, ukey = b'"subtype":"compact_boundary"', b'"usage":{"input_tokens":'
    def line_at(m, at):
        a = m.rfind(b"\n", 0, at) + 1
        b = m.find(b"\n", at)
        b = len(m) if b < 0 else b
        try:
            return json.loads(m[a:b]), b
        except ValueError:
            return None, b
    def reply_after(m, at, stop):
        while True:
            hit = m.find(ukey, at, stop)
            if hit < 0:
                return None
            o, at = line_at(m, hit)
            if isinstance(o, dict) and o.get("type") == "assistant" and not o.get("isSidechain") \
                    and reply_tokens(o) > 0:
                return reply_tokens(o)
    try:
        with open(path, "rb") as f:
            if os.fstat(f.fileno()).st_size == 0:
                return 0
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
                end = len(m)
                while True:
                    hit = m.rfind(bkey, 0, end)
                    if hit < 0:
                        break
                    o, stop = line_at(m, hit)
                    end = hit
                    post = ((o or {}).get("compactMetadata") or {}).get("postTokens") \
                        if isinstance(o, dict) and o.get("subtype") == "compact_boundary" else None
                    if not isinstance(post, int) or post <= 0:
                        continue
                    n = reply_after(m, stop, len(m))
                    if n is not None:
                        return max(0, n - post)
                # A first reply is mostly system prompt and tools; past 60k its prompt was a long paste.
                return min(reply_after(m, 0, len(m)) or 0, 60_000)
    except OSError:
        return 0


def reply_tokens(o):
    """Tokens a reply's request sent; 0 for an API error, which is written as a reply with none
    (and model "<synthetic>")."""
    u = (o.get("message") or {}).get("usage") or {}
    return sum(u.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
               if isinstance(u.get(k), int))
