"""Intake: work that comes in by itself (a duty's Auto intake), such as GitHub review requests."""
import argparse
import contextlib
import datetime as dt
from .compat import fcntl
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

from .core import (
    atomic_write, die, find_claude, HQ_EXE, hq_root, load_json, local_dt, LOCK_DIR, now_iso, ok_workdir,
    OPEN_STATUSES,
)
from .cards import append_log, card_paths, parse_card, set_fields
from .projects import INTAKE_MANUAL_DONE, INTAKE_SOURCES, load_project, load_projects
from .focus import new_card, set_card_goal
from .inbox import _add_refs
from .feeds import FEED_SECRET_ENV


# ---------------------------------------------------------------- intake (自动来活)
# Work that comes in by itself: a duty with a source switched on (PROJECT.md `auto:`) and set up
# in its "自动来活 / Auto intake" section gets a task for each new thing that source has for the
# user, and — when the section says so — a background Claude Code session started on it with the
# section's prompt. `hq intake` scans (Claude Pet runs it as a scheduled shell job).
#
# The section holds a `### <source>` block per source, `key: value` lines; `prompt:` comes last
# and takes the rest of the block (blank lines and all):
#
#   ### github-review
#   repos: tigergraph/bigtest, tigergraph/mit-devops      (`*`: any repository)
#   workdir: ~/code/bigtest       where the session runs (default: the duty's first folder; one
#                                 written here must exist — no falling back to another folder)
#   run: yes                      start a background session on each new task (default: no)
#   permissions: review           that session asks nothing: read-only review tools only (default: ask)
#   done: manual                  only the user closes the task (default); auto: the session may
#   focus: yes                    the task joins Focus (default)
#   title: Review {repo}#{number}: {title}
#   goal: …
#   prompt: Review {url} with /code-review …
#
# Placeholders: {repo} (owner/name) {name} {number} {title} {url} {author} {branch} {base}.
# Inside the prompt only a `### <source>` line ends it (a `## ` heading still ends the section).
# `permissions: review`: what a session started on someone else's PR may do without asking — read
# files, review with /code-review and subagents, read this one PR with gh, bind itself — and nothing
# more. The PR is written by whoever asked for the review (its title, branch and diff can carry
# instructions), so the session never skips permission checks: it runs in dontAsk mode, where
# anything not listed (editing, other commands, other skills, posting on GitHub) is refused rather
# than asked. Never the bare `Skill`: a skill's `allowed-tools` front matter allows those tools
# while it runs, so any installed skill with `Bash` or `*` there would open everything. gh is held
# to the PR's own github.com URL (see intake_review_args): `-R host/…` must not send a request
# elsewhere. `skip`, the old name, means the same: it never skips them either.
INTAKE_REVIEW_TOOLS = ("Read", "Grep", "Glob", "Agent", "Task", "Skill(code-review)", "TodoWrite")
INTAKE_PR_URL = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$")
INTAKE_DEFAULT = {
    "github-review": {
        "title": {"zh": "Review {name}#{number}：{title}", "en": "Review {name}#{number}: {title}"},
        "goal": {"zh": "{author} 请你 review {url}（{branch} → {base}）。意见先写在这张卡上，你确认之后再发到 GitHub。",
                 "en": "{author} asked you to review {url} ({branch} → {base}). The comments wait on this card; "
                       "they go to GitHub once you say so."},
        "prompt": {"zh": "用 /code-review 审这个 PR：{url}（{repo}#{number}「{title}」，作者 {author}）。审完把要发的意见"
                         "整理好写在任务卡上，然后用 hq-asks 问我要不要发到 GitHub。我同意之前，不要在 GitHub 上发任何"
                         "评论、review 或 approve。",
                   "en": "Review this PR with /code-review: {url} ({repo}#{number} \"{title}\" by {author}). Put the "
                         "comments you would post on the task card, then ask me in hq-asks whether to post them. "
                         "Post nothing on GitHub — no comment, review or approval — until I say so."},
    },
}
INTAKE_RECENT_DAYS = 14         # what `hq intake status` lists as recent
INTAKE_MAX_NEW = 3              # new tasks a scan makes; the rest wait for the next (a launch can take a minute)
# The pet's job env (JobRunner): a session started with it would count as the job's and be hidden
# from the pet (HookEmit skips processes with CLAUDE_PET_JOB) — no permission prompts shown.
INTAKE_DROP_ENV = ("CLAUDE_PET_JOB", "CLAUDE_PET_RUN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")
# What ties a process to the terminal tab it started in. A background session is in no terminal; with
# these it would be recorded as in the tab hq (or the pet that ran it) was started from, and the board
# would type messages for it there.
TERMINAL_ENV = ("TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
                "LC_TERMINAL", "LC_TERMINAL_VERSION")
TERMINAL_ENV_PREFIXES = ("ORCA_", "GHOSTTY_", "KITTY_")   # not VSCODE_*: git's askpass helper needs them


def intake_env(environ):
    """The environment a background session starts with: this one, less what would tie it to a terminal
    or to the session or job running hq."""
    return {k: v for k, v in environ.items() if not k.startswith("CLAUDE_CODE_SESSION")
            and k not in FEED_SECRET_ENV + INTAKE_DROP_ENV + TERMINAL_ENV and not k.startswith(TERMINAL_ENV_PREFIXES)}


class IntakeError(Exception):
    pass


def intake_fill(text, values):
    """{repo}, {number}, … filled in; other braces stay as written."""
    for k, v in values.items():
        text = text.replace("{" + k + "}", str(v))
    return text


def intake_dir():
    return os.path.join(hq_root(), "secretary", "intake")


def intake_state():
    d = load_json(os.path.join(intake_dir(), "state.json"), {})
    return d if isinstance(d, dict) else {}


def save_intake_state(st):
    atomic_write(os.path.join(intake_dir(), "state.json"), json.dumps(st, ensure_ascii=False, indent=1) + "\n")


@contextlib.contextmanager
def intake_lock():
    os.makedirs(LOCK_DIR, exist_ok=True)
    with open(os.path.join(LOCK_DIR, "intake.lock"), "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise IntakeError("a scan is already running")
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def intake_duties(source):
    """[(project info, its config)] of the active duties with `source` switched on and set up, in
    hq.json's order (the first one whose repos match takes a PR)."""
    out = []
    for pr in load_projects():
        p = load_project(pr["name"])
        if not p or p["kind"] != "duty" or p["status"] != "active" or source not in p["auto"]:
            continue
        cfg = p.get("intake", {}).get(source)
        if cfg and cfg["repos"]:
            out.append((dict(p, paths=pr.get("paths", [])), cfg))
    return out


def gh_json(args, timeout=60):
    """`gh <args>` → its JSON output. Raises IntakeError with gh's own message."""
    if not shutil.which("gh"):
        raise IntakeError("gh is not installed (https://cli.github.com)")
    try:
        r = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise IntakeError(f"gh {args[0]}: {e}")
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        raise IntakeError(f"gh {' '.join(args[:2])}: {msg[-1] if msg else 'failed'}")
    try:
        return json.loads(r.stdout or "null")
    except ValueError:
        raise IntakeError(f"gh {' '.join(args[:2])}: not JSON")


def repo_matches(repo, repos):
    return any(r == "*" or r.lower() == repo.lower() for r in repos)


def intake_workdir(duty, cfg):
    """Where the task's work (and its session) happens: the section's `workdir`, else the duty's
    first folder. None when that isn't an existing folder a task may use — a `workdir` written
    wrong never falls back to another folder."""
    for d in [cfg["workdir"]] if cfg.get("workdir") else list(duty.get("paths") or [])[:1]:
        d = os.path.normpath(os.path.expanduser(d))
        if os.path.isdir(d) and ok_workdir(d):
            return d
    return None


def intake_launch(tid, title, wd, prompt, review, lang, manual, claude=None, url=""):
    """Starts a background Claude Code session on the task (`claude --bg`, as the board's ▶ New
    session does in the background): it is told to bind itself first, and is bound from here too
    once `claude agents` reports its id. It never skips permission checks: `review` runs it in
    dontAsk mode with INTAKE_REVIEW_TOOLS, else it asks as usual. Returns its session id (or short
    id); raises IntakeError."""
    from .commands import cmd_bind
    claude = find_claude(claude)
    if not claude:
        raise IntakeError("can't find the claude command")
    hq = shlex.quote(HQ_EXE)
    first = (f"Start by running `{hq} bind {tid}` — it binds this background session to the task and prints "
             f"its rules. " + (INTAKE_MANUAL_DONE[lang] + " " if manual else "") + "Then: ")
    name = f"{tid} {title}"[:60]
    env = intake_env(os.environ)
    env["HQ_ROOT"] = hq_root()
    # `--` before the prompt: --allowedTools takes every word after it up to the next flag, and
    # would take the prompt — PR title and all — as more rules.
    args = [claude, "--bg", "--name", name] + (intake_review_args(hq, tid, url) if review else []) + ["--", first + prompt]
    try:
        # A session of its own: the job's end kills its process group, which must not take this along.
        r = subprocess.run(args, cwd=wd, capture_output=True, text=True, timeout=30, env=env, start_new_session=True)
    except (OSError, subprocess.SubprocessError) as e:
        raise IntakeError(f"claude --bg: {e}")
    said = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "not trusted" in said.lower():
        raise IntakeError("claude --bg: " + (said.strip()[:300] or f"exit {r.returncode}"))
    m = re.search(r"\b[0-9a-f]{8}\b", said)
    if not m:
        return ""
    short = m.group(0)
    for _ in range(10):
        try:
            rows = json.loads(subprocess.run([claude, "agents", "--json", "--all"], capture_output=True, text=True,
                                             timeout=5, env=env).stdout or "[]")
        except (OSError, subprocess.SubprocessError, ValueError):
            rows = []
        row = next((x for x in rows if isinstance(x, dict) and x.get("id") == short), None) if isinstance(rows, list) else None
        if row and row.get("sessionId"):
            with contextlib.redirect_stdout(io.StringIO()):
                cmd_bind(argparse.Namespace(task=tid, session=row["sessionId"]))
            return row["sessionId"]
        time.sleep(0.3)
    return short


def intake_review_args(hq, tid, url=""):
    """`permissions: review`: dontAsk mode, allowed only INTAKE_REVIEW_TOOLS, its own `hq bind` and
    `gh pr view|diff|checks` on the PR's own URL — gh takes the host from the URL, so `-R` added
    after it can't point it at another server. A URL that isn't a plain github.com PR gets no gh."""
    gh = tuple(f"Bash(gh pr {verb} {url}:*)" for verb in ("view", "diff", "checks")) if INTAKE_PR_URL.match(url or "") else ()
    tools = INTAKE_REVIEW_TOOLS + gh + (f"Bash({hq} bind {tid})",)
    return ["--permission-mode", "dontAsk"] + [a for t in tools for a in ("--allowedTools", t)]


def intake_make(source, duty, cfg, item, claude=None, dry=False, record=None):
    """One task for `item` (a PR's fields: repo, number, title, url, author, branch, base, head).
    `record(tid)` is called as soon as the card exists, before any session starts: a scan stopped
    after that (a timeout, Stop) doesn't make the task again. Returns {task, key, duty, title,
    session?, error?}."""
    lang = duty.get("lang") or "en"
    dflt = INTAKE_DEFAULT[source]
    values = {k: item.get(k, "") for k in ("repo", "number", "title", "url", "author", "branch", "base")}
    values["name"] = item["repo"].split("/")[-1]
    title = intake_fill(cfg.get("title") or dflt["title"][lang], values).strip()
    goal = intake_fill(cfg.get("goal") or dflt["goal"][lang], values).strip()
    key = f"{item['repo']}#{item['number']}"
    out = {"key": key, "duty": duty["name"], "title": title, "url": item["url"]}
    if dry:
        return out
    wd = intake_workdir(duty, cfg)
    tid, card = new_card(title, project=duty["name"], workdirs=[wd] if wd else [], focus=cfg["focus"])
    set_fields(card, {"intake": source, "intake_key": key, "intake_done": cfg["done"]})
    if record:
        record(tid)
    set_card_goal(card, goal)
    _add_refs(card, [f"PR {key} {item['url']}"])
    append_log(card, ("自动来活：" if lang == "zh" else "came in by itself: ") + f"{source} {item['url']}")
    out["task"] = tid
    if not cfg["run"]:
        set_fields(card, {"status": "waiting-on-me"})    # no session works on it: it is the user's
    if cfg["run"]:
        try:
            if not wd:
                raise IntakeError(f"no folder to run in: {cfg['workdir']} is not one" if cfg.get("workdir") else
                                  "no folder to run in: set `workdir:` in the duty's Auto intake section")
            if "*" in cfg["repos"] and cfg["permissions"] == "review":
                raise IntakeError("repos: * with permissions: review — name the repositories, or let it ask for permissions")
            prompt = intake_fill(cfg.get("prompt") or dflt["prompt"][lang], values)
            sid = intake_launch(tid, title, wd, prompt, cfg["permissions"] == "review", lang, cfg["done"] == "manual", claude,
                                item.get("url", ""))
            out["session"] = sid
            append_log(card, ("后台 session 已启动" if lang == "zh" else "background session started") + (f" {sid[:8]}" if sid else ""))
        except IntakeError as e:
            out["error"] = str(e)
            append_log(card, ("没能启动后台 session：" if lang == "zh" else "could not start a background session: ") + str(e))
            set_fields(card, {"status": "waiting-on-me"})
    return out


def card_by_id(tid):
    for p in card_paths():
        d = os.path.basename(os.path.dirname(p))
        if d == tid or d.startswith(tid + "-"):
            return p
    return None


def gh_lines(args, timeout=60):
    """`gh <args>` → its output lines. Raises IntakeError with gh's own message."""
    if not shutil.which("gh"):
        raise IntakeError("gh is not installed (https://cli.github.com)")
    try:
        r = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise IntakeError(f"gh {args[0]}: {e}")
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        raise IntakeError(f"gh {' '.join(args[:2])}: {msg[-1] if msg else 'failed'}")
    return [l.strip() for l in r.stdout.splitlines() if l.strip()]


def review_asked_at(repo, number, me):
    """When the PR last asked for the user's review — of them, or of a team (which may be theirs) —
    as an aware datetime, or None."""
    q = ('.[] | select(.event == "review_requested") | '
         f'select(.requested_team != null or (.requested_reviewer.login // "" | ascii_downcase) == "{me.lower()}") | .created_at')
    times = [local_dt(x) for x in gh_lines(["api", f"repos/{repo}/issues/{number}/events?per_page=100", "--paginate", "--jq", q])]
    times = [t for t in times if t]
    return max(times) if times else None


def intake_github_review(claude=None, dry=False):
    """Open PRs that request the user's review (`review-requested:@me`, drafts left out) in the
    repositories a duty watches → a task each, at most INTAKE_MAX_NEW a scan. A PR with an open
    task (by its card's `intake_key`) makes no other. Once that task is closed (or its card
    deleted), a new one only when the PR asked for the user's review again after that."""
    source = "github-review"
    duties = intake_duties(source)
    r = {"source": source, "duties": [d["name"] for d, _ in duties], "found": 0, "made": [], "errors": [], "left": 0}
    if not duties:
        return r
    prs = gh_json(["search", "prs", "--review-requested=@me", "--state=open", "--limit", "100",
                   "--json", "repository,number,title,url,author,isDraft"]) or []
    open_keys = {}
    for p in card_paths():
        m = parse_card(p)
        if m.get("intake") == source and m.get("intake_key") and m.get("status") in OPEN_STATUSES:
            open_keys[str(m["intake_key"]).lower()] = m["id"]
    st = intake_state()
    items = st.setdefault(source, {}).setdefault("items", {})
    me = None
    for pr in prs:
        repo = ((pr.get("repository") or {}).get("nameWithOwner") or "")
        if pr.get("isDraft") or not repo:
            continue
        match = next(((d, c) for d, c in duties if repo_matches(repo, c["repos"])), None)
        if not match:
            continue
        r["found"] += 1
        key = f"{repo}#{pr['number']}"
        if key.lower() in open_keys:
            continue
        try:
            prev = items.get(key)
            if prev:
                # Its task is closed or gone: only a request made after that makes a new one.
                card = card_by_id(prev.get("task", ""))
                m = parse_card(card) if card else {}
                since = local_dt(m.get("closed_at") or m.get("closed") or prev.get("at"))
                if me is None:
                    me = (gh_lines(["api", "user", "--jq", ".login"]) or [""])[0]
                asked = review_asked_at(repo, pr["number"], me)
                if not asked or (since and asked <= since):
                    continue
            if len([x for x in r["made"] if x.get("task") or dry]) >= INTAKE_MAX_NEW:
                r["left"] += 1
                continue
            view = gh_json(["pr", "view", str(pr["number"]), "-R", repo, "--json", "headRefOid,headRefName,baseRefName"])
            item = {"repo": repo, "number": pr["number"], "title": pr.get("title", ""), "url": pr.get("url", ""),
                    "author": (pr.get("author") or {}).get("login", ""), "branch": view.get("headRefName", ""),
                    "base": view.get("baseRefName", "")}

            def record(tid, key=key, head=view.get("headRefOid", ""), duty=match[0]["name"]):
                items[key] = {"task": tid, "head": head, "at": now_iso(), "duty": duty}
                save_intake_state(st)       # before any session starts: a stopped scan won't make it twice
            made = intake_make(source, match[0], match[1], item, claude=claude, dry=dry, record=record)
        except Exception as e:              # one PR going wrong doesn't stop the others
            r["errors"].append(f"{key}: {e}")
            continue
        r["made"].append(made)
        if made.get("error"):
            r["errors"].append(f"{made.get('task')}: {made['error']}")
    return r


INTAKE_RUN = {"github-review": intake_github_review}


def intake_recent(days=INTAKE_RECENT_DAYS):
    """Tasks that came in by itself, newest first: the ones still open, and those closed in the
    last `days` days."""
    cut = (dt.date.today() - dt.timedelta(days=days)).isoformat()
    out = []
    for p in card_paths():
        m = parse_card(p)
        if not m.get("intake"):
            continue
        if m.get("status") not in OPEN_STATUSES and str(m.get("closed") or m.get("updated") or "") < cut:
            continue
        out.append({k: m.get(k) for k in ("id", "title", "status", "project", "intake", "intake_key", "intake_done",
                                           "intake_closed_by", "closed", "updated")})
    return sorted(out, key=lambda x: int(re.sub(r"\D", "", x["id"] or "0") or 0), reverse=True)


def intake_status():
    st = intake_state()
    out = {"sources": {}, "recent": intake_recent()}
    for src in INTAKE_SOURCES:
        s = st.get(src) if isinstance(st.get(src), dict) else {}
        duties = []
        for pr in load_projects():
            p = load_project(pr["name"])
            if not p or p["kind"] != "duty":
                continue
            cfg = p.get("intake", {}).get(src)
            on = src in p["auto"]
            if not on and not cfg:
                continue
            others = [x for k, c in p.get("intake", {}).items() if k != src for x in c.get("problems", [])]
            duties.append({"name": p["name"], "on": on, "active": p["status"] == "active", "set_up": bool(cfg and cfg["repos"]),
                           "repos": (cfg or {}).get("repos", []), "run": bool((cfg or {}).get("run")),
                           "done": (cfg or {}).get("done", "manual"), "problems": (cfg or {}).get("problems", []) + others})
        out["sources"][src] = {"duties": duties, "last_scan": s.get("last_scan"), "last": s.get("last"),
                               "tracked": len(s.get("items") or {})}
    return out


def cmd_intake(args):
    if args.action == "status":
        st = intake_status()
        if args.json:
            print(json.dumps(st, ensure_ascii=False, indent=1))
            return
        for src, s in st["sources"].items():
            print(f"{src}: last scan {s['last_scan'] or 'never'}" +
                  (f" — made {len(s['last'].get('made') or [])}" if s.get("last") else ""))
            for d in s["duties"]:
                state = ("on" if d["on"] else "off") + ("" if d["set_up"] else ", no repos set") + ("" if d["active"] else ", paused")
                print(f"  {d['name']} ({state}): {', '.join(d['repos']) or '-'}; run {'yes' if d['run'] else 'no'}; done {d['done']}")
                for pb in d["problems"]:
                    print(f"    ! {pb}")
        if st["recent"]:
            print("\nrecent:")
            for t in st["recent"]:
                print(f"  {t['id']:<6} {t['status']:<13} [{t['project']}] {t['title']}")
        return
    results, failed = [], []
    try:
        with intake_lock():
            for src in INTAKE_SOURCES:
                try:
                    r = INTAKE_RUN[src](claude=args.claude, dry=args.dry_run)
                except IntakeError as e:
                    failed.append(f"{src} failed: {e}")
                    continue
                results.append(r)
                if not args.dry_run:
                    st = intake_state()
                    s = st.setdefault(src, {})
                    s["last_scan"] = now_iso()
                    s["last"] = {"found": r["found"], "made": [m.get("task") for m in r["made"]], "errors": r["errors"],
                                 "left": r.get("left", 0)}
                    save_intake_state(st)
    except IntakeError as e:
        die(str(e))
    if args.json:
        print(json.dumps({"results": results, "failed": failed}, ensure_ascii=False, indent=1))
    else:
        for r in results:
            for m in r["made"]:
                extra = " (dry run)" if args.dry_run else (f" → session {m['session'][:8]}" if m.get("session") else "") + \
                    (f" — {m['error']}" if m.get("error") else "")
                print(f"{m.get('task', '+')} [{m['duty']}] {m['title']}{extra}")
        # The job shows the last line, e.g. "github-review: 3 waiting, 1 new task (T-112)".
        parts = []
        for r in results:
            if not r["duties"]:
                parts.append(f"{r['source']}: no duty set up")
                continue
            made = [m.get("task") for m in r["made"] if m.get("task")]
            parts.append(f"{r['source']}: {r['found']} waiting, " + (f"{len(r['made'])} new" if args.dry_run else
                         f"{len(made)} new task{'s' if len(made) != 1 else ''}" + (f" ({', '.join(made)})" if made else ""))
                         + (f", {r['left']} left for the next scan" if r.get("left") else "")
                         + (f", {len(r['errors'])} error{'s' if len(r['errors']) != 1 else ''}" if r["errors"] else ""))
        print(" · ".join(parts + failed))
    if failed or any(r["errors"] for r in results):
        sys.exit(1)
