"""Autoclose: ticking todos whose PR merged, Jira issue is done or Jenkins build passed."""
import datetime as dt
from .compat import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import time

from .core import (
    atomic_write, card_lock, clip, die, hq_root, load_json, local_dt, LOCK_DIR, OPEN_STATUSES, SITE_SERVICES,
)
from .cards import _mark_todo, append_log, card_paths, card_todos, parse_card, todo_owner
from .refs import canonical_url, JENKINS_BUILD_RE, JIRA_BROWSE_RE, REF_URL_RE, URL_SPLIT_RE
from .history import history_path, read_history
from .asks import settle_status
from .update import _ascii_word, AUTOCLOSE_HASH_RE, AUTOCLOSE_KEY_RE, AUTOCLOSE_VERBS
from .feeds import feed_open, FeedError, jira_conf, jira_get, site_setting


def pr_states(urls, timeout=20):
    """GitHub PRs' state through `gh` ({url: {...}}), looked up in parallel; {} without gh. A PR
    gh can't read is left out: the report says what it knows."""
    import shutil
    import subprocess
    from concurrent.futures import ThreadPoolExecutor
    gh = shutil.which("gh")
    if not gh or not urls:
        return {}

    def one(url):
        try:
            r = subprocess.run([gh, "pr", "view", url, "--json", "number,title,state,mergedAt,closedAt,isDraft"],
                               capture_output=True, text=True, timeout=timeout)
            return url, json.loads(r.stdout) if r.returncode == 0 else None
        except (OSError, ValueError, subprocess.SubprocessError):
            return url, None
    with ThreadPoolExecutor(max_workers=8) as ex:
        return {u: d for u, d in ex.map(one, urls) if isinstance(d, dict)}


# ---------------------------------------------------------------- autoclose: todos settled outside
# An open todo on an open card that names a GitHub PR, a Jira issue or a Jenkins build is closed
# once what it names is finished: done when the PR merged, the issue reached a Done status, the
# build passed; dropped when the PR was closed unmerged. A todo naming several waits for all of
# them. A failed or aborted build leaves the todo alone: what to do about it is the user's call.
# Every close is a log line on the card saying why and how to reopen it; a todo the user reopened
# after a close is never closed again.
#
# A link counts only when the todo is about what finishing it means — merging or reviewing the PR,
# closing or fixing the issue, waiting for the build (AUTOCLOSE_VERBS) — and the todo has no step
# after it ("merge #101, then reinstall", "#101 合并后：重装"; AUTOCLOSE_AFTER): "comment the result on PR #9" or
# "delete the cluster of #9's runs" are not done because #9 merged.
#
# What a todo names: a GitHub PR link, or `#123` — a Jenkins build of that number among the card's
# links (refs and HISTORY.md, where build links go) when the todo waits for a build, else the PR of
# that number among its refs, else in the one repository its refs' PRs (or, with none, its
# workdirs' GitHub remotes) are in;
# a Jira key (ABC-123) or browse link, on the Jira site; a build link on the Jenkins site.
# Sites: `hq site`. Credentials stay in the keychain: "hq-jira" (account: the Jira email),
# "hq-jenkins" (account: the Jenkins user name); PRs go through `gh`.
# The patterns for what a todo names (AUTOCLOSE_HASH_RE, AUTOCLOSE_KEY_RE) and AUTOCLOSE_VERBS are
# in update.py: catching a repeated @me todo reads todos the same way.
AUTOCLOSE_GH_PR_RE = re.compile(r"^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)$", re.I)
AUTOCLOSE_REMOTE_RE = re.compile(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$", re.I)
AUTOCLOSE_KEEP_DAYS = 90        # how long a close is remembered once its todo is gone or closed
AUTOCLOSE_CLOSED_GRACE = 3600   # seconds a PR must have been closed unmerged before its todo is dropped
                                # (closing and reopening a PR to rerun CI is common)
JENKINS_FAILED = ("FAILURE", "ABORTED", "UNSTABLE", "NOT_BUILT")
# A step after the one that finishes: "then", "after …", "and <something else>", 然后 / 之后 / 再 /
# 并<something else> / "…后：", a ";". (A comma followed by words without a link counts too: see
# autoclose_has_after.) Missing one closes a todo with work left, so this errs towards leaving it.
_same_step = "merge|review|approve|land|close|resolve|fix|verify"
AUTOCLOSE_AFTER = re.compile(
    _ascii_word(rf"then|after(?:wards)?|and(?!\s+(?:{_same_step}))") +
    "|然后|之后|以后|随后|再|后[：:，,]|(?<!合)并(?!合并|合入|关闭|关掉|解决|修复|验证|跟进)|[;；]", re.I)
AUTOCLOSE_LINK_MARK = " \x00link\x00 "


def autoclose_path():
    return os.path.join(hq_root(), "secretary", "autoclose.json")


def autoclose_has_after(text):
    """Whether the todo has a step after the one a link finishes (see AUTOCLOSE_AFTER). A part
    after a comma that names nothing is one ("合并 #7，重装"); one that names something is a list
    ("watch #12, #13")."""
    t = REF_URL_RE.sub(AUTOCLOSE_LINK_MARK, text)
    if AUTOCLOSE_AFTER.search(t):
        return True
    named = lambda part: "\x00link\x00" in part or AUTOCLOSE_HASH_RE.search(part) or AUTOCLOSE_KEY_RE.search(part)
    return any(p.strip(" .。…)）") and not named(p) for p in re.split(r"[，,]", t)[1:])


def on_site(url, site):
    """Whether a canonical URL is on this site — scheme too: credentials never go over http when the
    site is https."""
    return bool(site) and url.lower().startswith(site.lower() + "/")


def autoclose_repos(meta, remotes, jenkins_site):
    """The card's PRs and Jenkins builds ({number: [urls]}), and its repositories (refs' first, else
    workdirs')."""
    prs, builds, repos = {}, {}, []
    refs = meta.get("refs") if isinstance(meta.get("refs"), list) else []
    history = read_history(meta["path"])["Links"] if jenkins_site and os.path.isfile(history_path(meta["path"])) else []
    for r in refs + [x[2:] for x in history]:
        for u in REF_URL_RE.findall(str(r)):
            c = canonical_url(u)
            m = AUTOCLOSE_GH_PR_RE.match(c)
            if m and r in refs:
                prs.setdefault(int(m.group(2)), []).append(c)
                repos.append(m.group(1).lower())
            parts = URL_SPLIT_RE.match(c)
            if on_site(c, jenkins_site) and parts and JENKINS_BUILD_RE.match(parts.group(3)):
                builds.setdefault(int(c.rsplit("/", 1)[1]), []).append(c)
    if not repos:
        for w in (meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else []):
            if w not in remotes:
                try:
                    r = subprocess.run(["git", "-C", os.path.expanduser(w), "remote", "get-url", "origin"],
                                       capture_output=True, text=True, timeout=10)
                    m = AUTOCLOSE_REMOTE_RE.search(r.stdout.strip()) if r.returncode == 0 else None
                    remotes[w] = m.group(1).lower() if m else None
                except (OSError, subprocess.SubprocessError):
                    remotes[w] = None
            if remotes[w]:
                repos.append(remotes[w])
    return ({n: sorted(set(u)) for n, u in prs.items()}, {n: sorted(set(u)) for n, u in builds.items()},
            sorted(set(repos)))


def autoclose_links(text, meta, sites, remotes):
    """What a todo's text names and waits on: [{"kind": pr|jira|jenkins, "key", "url", "name"}], in
    order — only the kinds the text has a verb for, and none when a step comes after."""
    out, seen = [], set()
    if autoclose_has_after(text):
        return out
    bare = REF_URL_RE.sub(" ", text)
    verb = {k: bool(r.search(bare)) for k, r in AUTOCLOSE_VERBS.items()}

    def add(kind, key, url, name):
        if key not in seen and verb[kind]:
            seen.add(key)
            out.append({"kind": kind, "key": key, "url": url, "name": name})
    for u in REF_URL_RE.findall(text):
        c = canonical_url(u)
        parts = URL_SPLIT_RE.match(c)
        if not parts:
            continue
        m = AUTOCLOSE_GH_PR_RE.match(c)
        j = JIRA_BROWSE_RE.match(parts.group(3))
        b = JENKINS_BUILD_RE.match(parts.group(3))
        if m:
            add("pr", c.lower(), c, f"PR {m.group(1)}#{m.group(2)}")
        elif j and on_site(c, sites["jira"]) and "?" not in c:
            key = c.rsplit("/", 1)[1]
            add("jira", key, c, key)
        elif b and on_site(c, sites["jenkins"]):
            jobs = b.group(1).split("/job/")[1:]           # ["a", "b/12"] for /job/a/job/b/12
            last, num = jobs[-1].rsplit("/", 1)
            add("jenkins", c, c, f"{'/'.join(jobs[:-1] + [last])} #{num}")
    hashes = AUTOCLOSE_HASH_RE.findall(bare)
    if hashes:
        prs, builds, repos = autoclose_repos(meta, remotes, sites["jenkins"])
        # #n is a build only for a todo that waits for builds and says nothing of merging.
        waits_build = verb["jenkins"] and not verb["pr"]
        for h in hashes:
            n = int(h)
            if waits_build and len(builds.get(n, [])) == 1:
                b = JENKINS_BUILD_RE.match(URL_SPLIT_RE.match(builds[n][0]).group(3))
                jobs = b.group(1).split("/job/")[1:]
                add("jenkins", builds[n][0], builds[n][0], f"{'/'.join(jobs[:-1] + [jobs[-1].rsplit('/', 1)[0]])} #{n}")
                continue
            urls = prs.get(n) or ([f"https://github.com/{repos[0]}/pull/{n}"] if len(repos) == 1 else [])
            if len(urls) == 1:
                m = AUTOCLOSE_GH_PR_RE.match(urls[0])
                add("pr", urls[0].lower(), urls[0], f"PR {m.group(1)}#{n}")
    if sites["jira"]:
        for key in AUTOCLOSE_KEY_RE.findall(bare):
            add("jira", key, f"{sites['jira']}/browse/{key}", key)
    return out


def jenkins_conf():
    """site, user and API token: the site from site_setting("jenkins") (None: Jenkins isn't set
    up); the token from $HQ_JENKINS_TOKEN (with $HQ_JENKINS_USER) or the login keychain, service
    "hq-jenkins", whose account is the user name."""
    site = site_setting("jenkins")
    if not site:
        return None
    user = os.environ.get("HQ_JENKINS_USER") or ""
    token = os.environ.get("HQ_JENKINS_TOKEN") or ""
    if not token:
        args = ["security", "find-generic-password", "-s", "hq-jenkins"] + (["-a", user] if user else [])
        try:
            info = subprocess.run(args, capture_output=True, text=True, timeout=20)
            tok = subprocess.run(args + ["-w"], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            info = tok = None
        if not tok or tok.returncode != 0 or not tok.stdout.strip():
            raise FeedError(f'no Jenkins API token in the keychain (service "hq-jenkins"): create one on your '
                            f'Jenkins user page ({site}/me/configure), copy it, then run '
                            'security add-generic-password -U -s hq-jenkins -a <your Jenkins user> -w "$(pbpaste)"')
        token = tok.stdout.strip()
        if not user:
            m = re.search(r'"acct"<blob>="([^"]*)"', info.stdout)
            user = m.group(1) if m else ""
    if not user:
        raise FeedError("no Jenkins user: put it in the keychain item's account, or set HQ_JENKINS_USER")
    return {"site": site, "user": user, "token": token}


def jenkins_get(conf, url):
    import urllib.error
    try:
        with feed_open(url, conf["user"], conf["token"], Accept="application/json") as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        hint = " (check the API token and the user)" if e.code in (401, 403) else ""
        raise FeedError(f"Jenkins: HTTP {e.code} {e.reason}{hint}", e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise FeedError(f"Jenkins: {getattr(e, 'reason', e)}")


def autoclose_lookup(links, errors):
    """Each link's outcome: {key: {"outcome": done|drop|failed|open|none, "why", "final"}}.
    `final`: it won't change (a merged PR, a finished build), so it needn't be looked up again.
    A source that can't be asked adds to `errors` and leaves its links out."""
    from concurrent.futures import ThreadPoolExecutor
    out = {}
    by = lambda k: [x for x in links if x["kind"] == k]
    prs = by("pr")
    if prs:
        import shutil
        if not shutil.which("gh"):
            errors.append("pr: gh is not installed")
        else:
            st = pr_states([x["url"] for x in prs])
            if len(st) < len(prs):
                # One PR gh can't read is likely not a PR (#n of an issue); none read may be gh
                # itself (logged out, offline): ask it, so that shows as a failure, not as "waiting".
                try:
                    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True, timeout=20)
                    bad = auth.returncode != 0
                except (OSError, subprocess.SubprocessError):
                    bad = True
                if bad:
                    errors.append("pr: gh can't reach GitHub (see gh auth status)")
            for x in prs:
                s = st.get(x["url"])
                if not s:
                    continue            # gh couldn't read it: not a PR, or no access — ask again later
                state = s.get("state")
                closed_at = local_dt(s.get("closedAt")) if s.get("closedAt") else None
                closed_for = time.time() - closed_at.timestamp() if closed_at else 0
                out[x["key"]] = ({"outcome": "done", "why": f"{x['name']} merged", "final": True} if state == "MERGED" else
                                 # Not final: a closed PR may be reopened.
                                 {"outcome": "drop", "why": f"{x['name']} closed unmerged", "final": False}
                                 if state == "CLOSED" and closed_for >= AUTOCLOSE_CLOSED_GRACE else
                                 {"outcome": "open", "why": f"{x['name']} {'closed just now' if state == 'CLOSED' else 'open'}",
                                  "final": False})
    for kind, conf_fn, one in (("jira", jira_conf, autoclose_jira), ("jenkins", jenkins_conf, autoclose_jenkins)):
        xs = by(kind)
        if not xs:
            continue
        try:
            conf = conf_fn()
        except FeedError as e:
            errors.append(f"{kind}: {e}")
            continue
        if not conf:
            continue
        failed = []

        def run(x):
            try:
                return x["key"], one(conf, x)
            except FeedError as e:
                failed.append(str(e))
                return x["key"], None
        with ThreadPoolExecutor(max_workers=6) as ex:
            out.update({k: v for k, v in ex.map(run, xs) if v})
        if failed:
            errors.append(f"{kind}: {failed[0]}" + (f" (and {len(failed) - 1} more)" if len(failed) > 1 else ""))
    return out


def autoclose_jira(conf, x):
    try:
        d = jira_get(conf, f"issue/{x['key']}", fields="status")
    except FeedError as e:
        if e.code == 404:           # not an issue (UTF-8 reads like a key), or not one we may see:
            # asked again every run, since a wrong site or account says 404 too
            return {"outcome": "none", "why": f"{x['key']} not found", "final": False}
        raise
    st = (d.get("fields") or {}).get("status") or {}
    done = (st.get("statusCategory") or {}).get("key") == "done"
    return {"outcome": "done" if done else "open", "why": f"{x['key']} {st.get('name') or '?'}", "final": False}


def autoclose_jenkins(conf, x):
    try:
        d = jenkins_get(conf, x["url"] + "/api/json?tree=building,result,fullDisplayName")
    except FeedError as e:
        if e.code == 404:           # the build is gone (kept builds rotate out), or hidden from us
            return {"outcome": "none", "why": f"{x['name']} not found", "final": False}
        raise
    name = x["name"]        # "job #12": fullDisplayName can run to several lines
    if d.get("building") or not d.get("result"):
        return {"outcome": "open", "why": f"{name} running", "final": False}
    if d["result"] == "SUCCESS":
        return {"outcome": "done", "why": f"{name} passed", "final": True}
    return {"outcome": "failed", "why": f"{name} {d['result'].lower()}", "final": d["result"] in JENKINS_FAILED}


def autoclose_verdict(links, results):
    """A todo's fate from its links' outcomes: ("done"|"drop", why) or (None, why)."""
    rs = [results.get(x["key"]) for x in links]
    if any(r is None for r in rs):
        return None, "not looked up"        # its source failed, or gh couldn't read the PR
    known = [r for r in rs if r["outcome"] != "none"]
    if not known:
        return None, "; ".join(r["why"] for r in rs)
    why = "; ".join(r["why"] for r in known)
    if any(r["outcome"] in ("open", "failed") for r in known):
        return None, why
    return ("drop" if any(r["outcome"] == "drop" for r in known) else "done"), why


def autoclose_apply(meta, text, state, why):
    """Closes the open todo with this text; its number, or None when it is no longer open."""
    card = meta["path"]
    with card_lock(card):
        lines = open(card, encoding="utf-8").read().split("\n")
        pick = next((x for x in card_todos(lines) if x[3] == text and x[2].group(2) == " "), None)
        if not pick:
            return None
        via = "auto: " + re.sub(r"[()]", "", why)
        _mark_todo(card, lines, pick, state, via)
        # Its number now: the tick may have moved older closed todos off the card (the budget).
        mark = "x" if state == "done" else "-"
        now_lines = open(card, encoding="utf-8").read().split("\n")
        n = next((x[1] for x in card_todos(now_lines) if x[3] == text and x[2].group(2).lower() == mark), None)
        undo = (f"reopen it on the board or with hq todo {meta['id']} {n} open --text {shlex.quote(text)}" if n else
                "it went to HISTORY.md with the older closed todos; to reopen it, add it again")
        append_log(card, f"auto-{'closed' if state == 'done' else 'dropped'} todo #{n or pick[1]} ({why}): {text} — {undo}")
        n = n or pick[1]
    if todo_owner(pick[2].group(3)) == "me":
        settle_status(card, "auto")
    return n


def autoclose_run(dry=False, now=None):
    if dry:
        return _autoclose_run(True, now)
    os.makedirs(LOCK_DIR, exist_ok=True)
    with open(os.path.join(LOCK_DIR, "autoclose.lock"), "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            die("hq autoclose is already running")
        try:
            return _autoclose_run(False, now)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _autoclose_run(dry, now=None):
    now = now or dt.datetime.now()
    st = load_json(autoclose_path(), {})
    st = st if isinstance(st, dict) else {}
    closed = st.get("closed") if isinstance(st.get("closed"), dict) else {}
    final = st.get("final") if isinstance(st.get("final"), dict) else {}
    sites = {s: site_setting(s) for s in SITE_SERVICES}
    remotes, todos, reopened = {}, [], []
    for p in card_paths():
        meta = parse_card(p)
        if meta.get("status") not in OPEN_STATUSES:
            continue
        for t in meta["todos"]:
            if t["state"] != "open":
                continue
            text = " ".join(t["text"].split())
            links = autoclose_links(t["text"], meta, sites, remotes)
            if not links:
                continue
            if f"{meta['id']} {text}" in closed:
                reopened.append({"task": meta["id"], "text": text})
                # Still open after the user reopened it: remembered as long as it stays so.
                closed[f"{meta['id']} {text}"]["at"] = now.isoformat(timespec="seconds")
                continue
            todos.append((meta, t, text, links))
    links = {x["key"]: x for _, _, _, ls in todos for x in ls}
    errors = []
    results = {k: final[k] for k in links if isinstance(final.get(k), dict)}
    results.update(autoclose_lookup([x for k, x in links.items() if k not in results], errors))
    out = {"todos": len(todos), "links": {k: sum(1 for x in links.values() if x["kind"] == k) for k in ("pr", "jira", "jenkins")},
           "closed": [], "waiting": [], "reopened": reopened, "errors": errors, "dry": dry}
    for meta, t, text, ls in todos:
        state, why = autoclose_verdict(ls, results)
        row = {"task": meta["id"], "todo": t["i"], "owner": t["owner"], "text": text, "why": why}
        if not state:
            out["waiting"].append(row)
            continue
        n = t["i"] if dry else autoclose_apply(meta, text, state, why)
        if n is not None:
            out["closed"].append(dict(row, todo=n, state=state))
            if not dry:
                closed[f"{meta['id']} {text}"] = {"at": now.isoformat(timespec="seconds"), "state": state, "why": why}
    if not dry:
        keep = (now - dt.timedelta(days=AUTOCLOSE_KEEP_DAYS)).isoformat(timespec="seconds")
        st = {"closed": {k: v for k, v in closed.items() if str(v.get("at", "")) >= keep},
              "final": {k: r for k, r in results.items() if r.get("final")},
              "last": {"at": now.isoformat(timespec="seconds"), "todos": len(todos),
                       "closed": len(out["closed"]), "errors": errors}}
        atomic_write(autoclose_path(), json.dumps(st, ensure_ascii=False, indent=1) + "\n")
    return out


def cmd_autoclose(args):
    r = autoclose_run(dry=args.dry_run)
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
    else:
        verb = {"done": "done", "drop": "dropped"}
        for c in r["closed"]:
            print(f"{c['task']} #{c['todo']} {'would be ' if r['dry'] else ''}{verb[c['state']]}: {clip(c['text'], 80)} ({c['why']})")
        if args.verbose or r["dry"]:
            for w in r["waiting"]:
                print(f"{w['task']} #{w['todo']} waits: {clip(w['text'], 80)} ({w['why']})")
            for x in r["reopened"]:
                print(f"{x['task']} reopened after a close, left alone: {clip(x['text'], 80)}")
        # The job shows the last line, e.g. "4 todos with links → closed 1 · jenkins: HTTP 401 …".
        drop = sum(1 for c in r["closed"] if c["state"] == "drop")
        line = f"{r['todos']} todos with links → closed {len(r['closed']) - drop}" + (f", dropped {drop}" if drop else "")
        print(" · ".join([line] + r["errors"]))
    if r["errors"]:
        sys.exit(1)
