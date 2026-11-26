"""Projects and duties: the registry in hq.json, PROJECT.md sections, briefs, `hq project`."""
import datetime as dt
import json
import os
import re
import sys

from .core import (
    atomic_write, card_lock, die, HOME_DIR, hq_root, load_json, ok_workdir, OPEN_STATUSES, snoozed, today,
    TODO_RE,
)
from .cards import (
    append_log, card_paths, check_category, parse_card, parse_frontmatter, root_config_path, set_fields,
)


# ---------------------------------------------------------------- projects
# A project groups tasks: { "name": ..., "paths": [dirs] } in hq.json. A task's directory decides
# its project automatically (deepest matching path wins); the card's `project` field can be changed.
def load_projects():
    cfg = load_json(root_config_path(), None)
    out = []
    for pr in (cfg.get("projects") if isinstance(cfg, dict) else None) or []:
        if isinstance(pr, dict) and isinstance(pr.get("name"), str) and pr["name"]:
            out.append({"name": pr["name"],
                        "paths": [x for x in pr.get("paths", []) if isinstance(x, str) and x]})
    return out


def save_projects(projects):
    cfg = load_json(root_config_path(), {})
    if not isinstance(cfg, dict):
        cfg = {}
    cfg["projects"] = projects
    atomic_write(root_config_path(), json.dumps(cfg, ensure_ascii=False, indent=1) + "\n")


def norm_path(x):
    return os.path.realpath(os.path.expanduser(x))


def project_for_path(path):
    if not path:
        return ""
    target = norm_path(path)
    best, depth = "", -1
    for pr in load_projects():
        for root in pr["paths"]:
            r = norm_path(root)
            if (target == r or target.startswith(r + os.sep)) and len(r) > depth:
                best, depth = pr["name"], len(r)
    return best


def project_for_dirs(dirs):
    for d in dirs or []:
        name = project_for_path(d)
        if name:
            return name
    return ""


def ensure_project(name):
    if name and name not in [x["name"] for x in load_projects()]:
        save_projects(load_projects() + [{"name": name, "paths": []}])
        print(f"hq: added project {name!r}", file=sys.stderr)


# ---------------------------------------------------------------- PROJECT.md
# A project is a line of work — a goal with an end, or a standing duty — not a folder. hq.json
# lists the projects: their names, their order, and `paths` (folders whose new tasks default to
# the project — a suggestion, not what a project is). What a project is lives in
# <root>/projects/<name>/PROJECT.md: kind, goal, done-when, deadline, Jira and the brief every
# session on one of its tasks is given. A listed project with no PROJECT.md still works: it has no
# kind, goal or brief yet.
PROJECT_KINDS = ("goal", "duty")
PROJECT_STATUSES = ("active", "paused", "done", "abandoned")
PROJECT_SECTIONS = {            # heading words (either language; "A / B" headings match either part)
    "goal": re.compile(r"^(?:goal|scope|目标|职责范围|职责)$", re.I),
    "out": re.compile(r"^(?:out of scope|不管)$", re.I),
    "done_when": re.compile(r"^(?:done when|healthy when|完成标准|健康标准)$", re.I),
    "templates": re.compile(r"^(?:templates|task templates|常见的活|模板)$", re.I),
    "intake": re.compile(r"^(?:auto intake|comes in by itself|自动来活)$", re.I),
    "brief": re.compile(r"^(?:brief|project brief|简报|项目简报)$", re.I),
}
# The heading a section gets when `hq project section` writes one the file doesn't have yet
# (in the file's language): {key: (zh, en)}; done_when depends on the kind.
PROJECT_HEADINGS = {"goal": ("目标", "Goal"), "out": ("不管", "Out of scope"),
                    "done_when": ("完成标准", "Done when"), "templates": ("常见的活", "Templates"),
                    "intake": ("自动来活", "Auto intake"), "brief": ("简报", "Brief")}
DUTY_HEALTH_HEADING = ("健康标准", "Healthy when")
PROJECT_END_RE = re.compile(r"^(?:log|decision log|decisions|决策记录|日志)$", re.I)
PROJECT_SET_KEYS = ("title", "kind", "status", "due", "jira", "fixVersions", "parent", "phases", "auto")
PROJECT_LIST_KEYS = ("jira", "fixVersions", "phases", "auto")
# Where a duty's work could come in by itself: switched on here (`auto:`), set up in the duty's Auto
# intake section. Only those in INTAKE_SOURCES make tasks so far; the others are switches.
AUTO_SOURCES = ("qahub-ci", "github-review", "jira-filter")
# "不管：…" / "Out of scope: …" written as a line of the goal (as older PROJECT.md files do).
OUT_LINE_RE = re.compile(r"^\s*(?:不管|out of scope)\s*[:：]\s*(.+)$", re.I)
# Sections added after briefs were in use: inside a brief, a "## Templates" is the brief's own
# heading, not the start of one of these.
LATE_SECTIONS = ("out", "templates", "intake")
CRIT_RE = re.compile(r"^(\s*)[-*] (?:\[([ xX])\] )?(.*\S)\s*$")
BRIEF_CHARS = 2000              # of the brief a session is given; the rest: read PROJECT.md


def projects_dir():
    return os.path.join(hq_root(), "projects")


def check_project_name(name):
    name = check_category(name)
    if "/" in name or name.startswith("."):
        die(f"invalid project name {name!r}: it names a folder — no '/', no leading '.'")
    return name


def same_name_project(name, names, but=None):
    """A listed project whose name differs from `name` only in case: on macOS both would be one
    folder, so one PROJECT.md."""
    return next((n for n in names if n != name and n != but and n.lower() == name.lower()), None)


def project_file(name):
    if not name or "/" in name or name.startswith("."):
        return None
    return os.path.join(projects_dir(), name, "PROJECT.md")


def section_key(line, key):
    """What a `## ` line of PROJECT.md starts: a section's key, "" for a Log heading or an old
    Grants one (it ends the section), None for any other heading (a brief's "## Commands" stays in it).
    `key` is the section the line is in."""
    words = [w.strip() for w in line[3:].split("/")]
    new = next((k for k, rx in PROJECT_SECTIONS.items() if any(rx.match(w) for w in words)), None)
    if new in LATE_SECTIONS and key == "brief":
        new = None
    if new:
        return new
    if is_grants_heading(line) or any(PROJECT_END_RE.match(w) for w in words):
        return ""
    return None


def project_spans(lines):
    """{key: [(heading line, end line), …]} of the sections of PROJECT.md `lines`, in file order
    ("" = the Log section, and an old Grants one). A key can have more than one span (a Goal and a Scope).
    Headings inside code fences don't count."""
    spans, key, start, fence = {}, None, None, False
    for i, line in enumerate(lines):
        if re.match(r"^\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence or not line.startswith("## "):
            continue
        new = section_key(line, key)
        if new is None:
            continue
        if start is not None:
            spans.setdefault(key, []).append((start, i))
        key, start = new, i
    if start is not None:
        spans.setdefault(key, []).append((start, len(lines)))
    return spans


def section_raw(lines, spans, key):
    """A section's text as written (all of its spans, joined)."""
    return "\n\n".join("\n".join(lines[a + 1:b]).strip("\n") for a, b in spans.get(key, [])).strip("\n")


def clean_section(text):
    """A section without template hints: HTML comments and a lone `<placeholder>` line (not a
    `<https://…>` link)."""
    t = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    t = re.sub(r"^[ \t]*<(?![^<>\n]*://)(?!mailto:)[^<>\n]*>[ \t]*$", "", t, flags=re.M)
    return re.sub(r"\n{3,}", "\n\n", t).strip()


def project_sections(body, raw=False):
    """{key: text} of a PROJECT.md body: cleaned (clean_section), or as written with raw=True.
    A section runs to the next section, Log or old Grants heading (project_spans)."""
    lines = body.split("\n")
    spans = project_spans(lines)
    out = {k: section_raw(lines, spans, k) for k in spans if k}
    return out if raw else {k: clean_section(v) for k, v in out.items()}


def visible_text(line, in_comment):
    """`line` without its HTML comment parts → (text, still inside a comment at its end)."""
    out = ""
    while line:
        if in_comment:
            j = line.find("-->")
            if j < 0:
                return out, True
            line, in_comment = line[j + 3:], False
        else:
            j = line.find("<!--")
            if j < 0:
                return out + line, False
            out, line, in_comment = out + line[:j], line[j + 4:], True
    return out, in_comment


def split_out_lines(text):
    """Older files say what is out of scope as "不管：…" lines of the goal → (goal without them,
    [what they say]). Lines inside comments stay."""
    keep, outs, inc = [], [], False
    for line in text.split("\n"):
        vis, inc2 = visible_text(line, inc)
        m = None if inc else OUT_LINE_RE.match(vis)
        inc = inc2
        if m:
            outs.append(m.group(1).strip())
        else:
            keep.append(line)
    return "\n".join(keep), outs


def merge_out(out, extra):
    """The out-of-scope text with the `extra` items it doesn't already say, one per line."""
    have = {re.sub(r"^\s*[-*]\s+", "", l).strip() for l in out.split("\n")}
    add = [x for x in dict.fromkeys(extra) if x not in have]
    return "\n".join(([out.rstrip()] if out.strip() else []) + add)


def project_criteria(text):
    """The bullet lines of a Done when / Healthy when section: [{i, text, done}]. A plain bullet is
    an unticked criterion; `- [x]` a ticked one."""
    out = []
    for line in text.splitlines():
        m = CRIT_RE.match(line)
        if m and not m.group(1):
            out.append({"i": len(out) + 1, "text": m.group(3), "done": (m.group(2) or "").lower() == "x"})
    return out


def project_templates(text):
    """A Templates section as [{name, title, goal, todos}]. Each template is a `### name` block of
    `title: …`, `goal: …` (more lines continue it) and `- [ ] @owner todo` lines; a bare
    `- name: title` line (before any block) is a template with just a title."""
    out, cur, in_goal = [], None, False
    for line in text.splitlines():
        h = re.match(r"^###\s+(.+?)\s*$", line)
        if h:
            cur, in_goal = {"name": h.group(1), "title": "", "goal": "", "todos": []}, False
            out.append(cur)
            continue
        if cur is None:
            m = re.match(r"^[-*]\s+([^:：]+?)\s*[:：]\s*(.+)$", line)
            if m:
                out.append({"name": m.group(1), "title": m.group(2).strip(), "goal": "", "todos": []})
            continue
        kv = re.match(r"^(title|标题|goal|目标)\s*[:：]\s*(.*)$", line, re.I)
        t = TODO_RE.match(line)
        if kv:
            is_title = kv.group(1).lower() in ("title", "标题")
            cur["title" if is_title else "goal"] = kv.group(2).strip()
            in_goal = not is_title
        elif t:
            cur["todos"].append(t.group(3).strip())
            in_goal = False
        elif in_goal and line.strip():
            cur["goal"] += "\n" + line.strip()
        elif not line.strip():
            in_goal = False
    return out


def fill_template(text):
    """A template's placeholders that hq can fill: {date} / {日期} and {week} / {周}."""
    d = dt.date.today()
    for k, v in (("date", d.isoformat()), ("日期", d.isoformat()),
                 ("week", f"W{d.isocalendar()[1]:02d}"), ("周", f"W{d.isocalendar()[1]:02d}")):
        text = text.replace("{" + k + "}", v)
    return text


def as_list(v):
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v or "").split(",") if x.strip()]


def load_project(name):
    """What PROJECT.md says about a project, or None when it has none."""
    path = project_file(name)
    if not path or not os.path.isfile(path):
        return None
    try:   # read by every hook of every session on its tasks: a bad file must not break them
        meta, body = parse_frontmatter(open(path, encoding="utf-8", errors="replace").read())
    except OSError:
        return None
    sec, raw = project_sections(body), project_sections(body, raw=True)
    intake_raw = raw.get("intake", "")     # as written: a prompt keeps its <…> lines
    kind, status = str(meta.get("kind") or "").lower(), str(meta.get("status") or "").lower()
    # Older files say what is out of scope as "不管：…" lines of the goal: shown (and, on the next
    # write, moved) as part of the out-of-scope section.
    goal, outs = split_out_lines(sec.get("goal", ""))
    goal, out = clean_section(goal), merge_out(sec.get("out", ""), outs)
    raw["goal"] = split_out_lines(raw.get("goal", ""))[0]
    raw["out"] = merge_out(raw.get("out", ""), outs)
    # What the board's section editor starts from: the text as written, comments and all — but
    # empty for a section holding only the template's hints.
    raw = {k: v.strip("\n") if clean_section(v) else "" for k, v in raw.items()}
    return {"name": name, "file": path, "title": str(meta.get("title") or ""),
            "kind": kind if kind in PROJECT_KINDS else "",
            "status": status if status in PROJECT_STATUSES else "active",
            "due": str(meta.get("due") or ""), "jira": as_list(meta.get("jira")),
            "fixVersions": as_list(meta.get("fixVersions")), "updated": str(meta.get("updated") or ""),
            "parent": str(meta.get("parent") or ""), "phases": as_list(meta.get("phases")),
            "auto": as_list(meta.get("auto")),
            "goal": goal, "out": out, "done_when": sec.get("done_when", ""),
            "criteria": project_criteria(sec.get("done_when", "")),
            "templates": project_templates(sec.get("templates", "")),
            "intake": project_intake(intake_raw),
            "lang": "zh" if re.search(r"^## .*[\u4e00-\u9fff]", body, re.M) else "en",
            "brief": sec.get("brief", ""), "raw": raw}


def project_info(pr):
    """A listed project (hq.json entry) with what its PROJECT.md says; `defined` false without one."""
    p = load_project(pr["name"])
    base = {"title": "", "kind": "", "status": "active", "due": "", "jira": [], "fixVersions": [],
            "updated": "", "parent": "", "phases": [], "auto": [], "goal": "", "out": "", "done_when": "",
            "criteria": [], "templates": [], "intake": {}, "lang": "", "raw": {}, "brief": "", "file": None}
    return {**base, **(p or {}), "name": pr["name"], "paths": pr.get("paths", []), "defined": bool(p)}


def project_template():
    for tpl in (os.path.join(hq_root(), "templates", "PROJECT.md"), os.path.join(HOME_DIR, "template", "PROJECT.md")):
        if os.path.isfile(tpl):
            return open(tpl, encoding="utf-8").read()
    return ("---\nname: x\ntitle: \"\"\nkind:\nstatus: active\ndue:\njira: []\nfixVersions: []\nupdated: 2026-01-01\n---\n\n"
            "## Goal\n\n## Done when\n\n## Brief\n\n## Log\n")


def ensure_project_file(name, fields=None):
    """PROJECT.md for this project, made from the template if it has none. Returns its path."""
    path = project_file(check_project_name(name))
    if not os.path.isfile(path):
        text = project_template()
        if (fields or {}).get("kind") == "duty":    # a duty is healthy, never done
            text = re.sub(r"(?m)^## Done when$", "## " + DUTY_HEALTH_HEADING[1], text)
            text = re.sub(r"(?m)^## 完成标准$", "## " + DUTY_HEALTH_HEADING[0], text)
        atomic_write(path, text)
        set_fields(path, {"name": name, "title": name, "updated": today()})
    if fields:
        set_fields(path, fields)
    return path


def check_project_fields(pairs):
    """`key=value` arguments of `hq project set` → frontmatter fields, checked."""
    fields = {}
    for kv in pairs:
        if "=" not in kv:
            die(f"expected key=value, got {kv!r} (keys: {', '.join(PROJECT_SET_KEYS)})")
        k, v = kv.split("=", 1)
        k, v = k.strip(), v.strip()
        if k not in PROJECT_SET_KEYS:
            die(f"can't set {k!r} on a project (keys: {', '.join(PROJECT_SET_KEYS)}); "
                "goal, out of scope, done-when, templates and the brief are sections: hq project section")
        if k == "kind" and v and v not in PROJECT_KINDS:
            die("kind is goal (has an end) or duty (a standing responsibility)")
        if k == "status" and v not in PROJECT_STATUSES:
            die(f"status is one of {', '.join(PROJECT_STATUSES)}")
        if k == "due" and v:
            try:
                dt.date.fromisoformat(v)
            except ValueError:
                die(f"due is a date, YYYY-MM-DD (got {v!r})")
        if k == "auto" and [x for x in as_list(v) if x not in AUTO_SOURCES]:
            die(f"auto sources are {', '.join(AUTO_SOURCES)}")
        fields[k] = as_list(v) if k in PROJECT_LIST_KEYS else v
    return fields


def check_project_parent(name, fields, cur, names):
    """A project can sit under a duty: only a goal, only under a listed duty other than itself."""
    parent = fields.get("parent", cur.get("parent", ""))
    if not parent:
        return
    if fields.get("kind", cur.get("kind")) != "goal":
        die("only a goal (kind=goal) sits under a duty")
    if parent == name:
        die("a project can't sit under itself")
    pp = load_project(parent) if parent in names else None
    if not pp or pp["kind"] != "duty":
        die(f"parent must be a duty (no duty {parent!r})")


def put_section(lines, key, text, kind=""):
    """`lines` with section `key` holding `text`: its first span's text replaced (any later span of
    the same key — a Scope after a Goal — removed), or a new section made, in the file's language,
    before the first later section, the Log heading or an old Grants one — else at the end."""
    spans = project_spans(lines)
    body = [l.rstrip() for l in text.strip("\n").split("\n")] if text.strip() else []
    if spans.get(key):
        (a, b), *more = spans[key]
        gone = {i for c, e in more for i in range(c, e)}
        while b > a + 1 and not lines[b - 1].strip():
            b -= 1
        rest = [l for i, l in enumerate(lines) if i >= b and i not in gone]
        while rest and not rest[-1].strip():
            rest.pop()
        return lines[:a + 1] + body + rest
    zh = any(re.search(r"[\u4e00-\u9fff]", l) for l in lines if l.startswith("## "))
    names = DUTY_HEALTH_HEADING if key == "done_when" and kind == "duty" else PROJECT_HEADINGS[key]
    order = list(PROJECT_SECTIONS)
    later = [spans[k][0][0] for k in order[order.index(key) + 1:] if spans.get(k)]
    at = min(later + [a for a, _ in spans.get("", [])[:1]] or [len(lines)])
    block = [f"## {names[0] if zh else names[1]}"] + body + [""]
    if at == len(lines):
        block = [""] + block[:-1]
    return lines[:at] + block + lines[at:]


def write_project_section(path, key, text, kind=""):
    """Write one section of PROJECT.md (put_section). "不管：…" lines still in the goal move to the
    out-of-scope section on the way — unless that is the section written: its text is the whole of
    it (the board shows them as part of it)."""
    lines = open(path, encoding="utf-8").read().rstrip("\n").split("\n")
    outs = []
    for a, b in reversed(project_spans(lines).get("goal", [])):
        kept, found = split_out_lines("\n".join(lines[a + 1:b]))
        if found:
            lines[a + 1:b] = kept.split("\n")
            outs = found + outs
    if key == "goal":
        text, found = split_out_lines(text)
        outs += found
    lines = put_section(lines, key, text, kind)
    if outs and key != "out":
        cur = section_raw(lines, project_spans(lines), "out")
        lines = put_section(lines, "out", merge_out(cur, outs), kind)
    atomic_write(path, "\n".join(lines) + "\n")


def tick_criterion(path, n, done):
    """Tick (or untick) the n-th criterion of Done when / Healthy when — counted as
    project_criteria counts them: bullets inside comments don't count."""
    lines = open(path, encoding="utf-8").read().split("\n")
    k = 0
    for a, b in project_spans(lines).get("done_when", []):
        inc = False
        for i in range(a + 1, b):
            vis, inc = visible_text(lines[i], inc)
            m = CRIT_RE.match(vis)
            if m and not m.group(1):
                k += 1
                if k == n:
                    lines[i] = re.sub(r"^[-*] (?:\[[ xX]\] )?", f"- [{'x' if done else ' '}] ", lines[i], count=1)
                    atomic_write(path, "\n".join(lines))
                    return m.group(3)
    die(f"no criterion #{n}")


def project_brief_text(meta):
    """What a session bound to this task is told about its project: what the project is, then its
    brief. Empty when the task has no project, or its project has no PROJECT.md or an empty brief."""
    name = meta.get("project") or ""
    pr = load_project(name) if name else None
    if not pr or not pr["brief"]:
        return ""
    bits = [{"goal": "a goal", "duty": "a standing duty"}.get(pr["kind"], ""),
            f"due {pr['due']}" if pr["due"] else "", pr["status"] if pr["status"] != "active" else ""]
    bits = [b for b in bits if b]
    lines = [f"{meta['id']} belongs to project {name}" + (f": {pr['title']}" if pr["title"] and pr["title"] != name else "")
             + (f" ({', '.join(bits)})" if bits else "") + f". Project file: {pr['file']}"]
    goal = next((l.strip() for l in pr["goal"].splitlines() if l.strip()), "")
    if goal:
        lines.append(f"Project goal: {goal}")
    if pr["brief"]:
        b = pr["brief"]
        if len(b) > BRIEF_CHARS:
            b = b[:BRIEF_CHARS].rstrip() + "\n… (cut short — the whole brief is in the project file)"
        lines.append(f"Project brief — applies to every task in {name}, whatever repo it works in:\n{b}")
    return "\n".join(lines)


PREFS_CHARS = 1500              # of profile.md's Preferences a session is given
PREFS_HEADINGS = ("preferences", "偏好")


def prefs_text(meta):
    """The user's standing preferences, from the Preferences section of the secretary's profile.md:
    every bound session is told them, so it asks less and guesses the user's way. Empty with no
    secretary, an empty section, or on the secretary's own card (it reads the whole profile)."""
    from .cards import secretary_task_id
    path = os.path.join(hq_root(), "secretary", "profile.md")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return ""
    if meta.get("id") and meta.get("id") == secretary_task_id():
        return ""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    body, inside = [], False
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            inside = m.group(1).strip().lower() in PREFS_HEADINGS
            continue
        if inside:
            body.append(line)
    b = "\n".join(body).strip()
    if not b:
        return ""
    if len(b) > PREFS_CHARS:
        b = b[:PREFS_CHARS].rstrip() + "\n… (cut short — the rest is in secretary/profile.md)"
    return ("The user's standing preferences (Preferences in secretary/profile.md, learned from how they answered "
            "asks; they apply to every task, but the card and the user's own words win):\n" + b)


def session_context_text(meta):
    """What a bound session is told besides the protocol: its project's brief and the user's
    preferences. One text, so a change to either is announced once (`brief_hash`)."""
    return "\n\n".join(t for t in (project_brief_text(meta), prefs_text(meta)) if t)


def brief_hash(text):
    import hashlib   # only a bound session's hook needs it
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:12] if text else ""


def repo_of(path):
    """The git repository a folder belongs to, named by its main checkout's folder: a worktree
    (claude-pet-T075) counts as its main repo (claude-pet). A folder that is gone (a removed
    worktree): a sibling repo whose name starts it, if any. Not in a repo: the folder's name."""
    target = norm_path(path)
    d = target
    while os.path.isdir(d):
        g = os.path.join(d, ".git")
        if os.path.isdir(g):
            return os.path.basename(d)
        if os.path.isfile(g):
            try:
                m = re.match(r"gitdir:\s*(.+)", open(g, encoding="utf-8").read().strip())
            except OSError:
                m = None
            gitdir = os.path.normpath(os.path.join(d, m.group(1))) if m else ""
            try:      # a worktree's gitdir names the repo's own git dir in `commondir`
                common = os.path.normpath(os.path.join(gitdir, open(os.path.join(gitdir, "commondir"), encoding="utf-8").read().strip()))
                name = os.path.basename(os.path.dirname(common)) if os.path.basename(common) == ".git" else os.path.basename(common)
                return name[:-4] if name.endswith(".git") and len(name) > 4 else name
            except OSError:
                pass
            parts = gitdir.split(os.sep) if gitdir else []
            if ".git" in parts:          # <main>/.git/worktrees/<name> (or .git/modules/… of a submodule)
                return parts[len(parts) - 1 - parts[::-1].index(".git") - 1]
            return os.path.basename(d)
        if os.path.dirname(d) == d:
            break
        d = os.path.dirname(d)
    base, parent = os.path.basename(target), os.path.dirname(target)
    if not os.path.exists(target) and os.path.isdir(parent):
        sibs = [s for s in os.listdir(parent) if base.startswith(s + "-") and os.path.exists(os.path.join(parent, s, ".git"))]
        if sibs:
            return max(sibs, key=len)
    return base


def task_repo(meta):
    dirs = meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else []
    live = [d for d in dirs if os.path.isdir(d)]
    return repo_of((live or dirs)[0]) if dirs else ""


def project_stats(name, metas, now=None):
    """Counts the board's project heading shows. `metas` carry `asks` (read_asks)."""
    now = now or dt.date.today()
    mine = [m for m in metas if (m.get("project") or "") == name]
    st = {"open": 0, "done": 0, "abandoned": 0, "done_7d": 0, "on_me": 0}
    for m in mine:
        s = m.get("status")
        if s in OPEN_STATUSES:
            st["open"] += 1
            st["on_me"] += sum(1 for a in m.get("asks", []) if a["state"] == "open" and not snoozed(a))
            st["on_me"] += sum(1 for t in m["todos"] if t["state"] == "open" and t["owner"] == "me")
        elif s in ("done", "abandoned"):
            st[s] += 1
            try:
                if s == "done" and (now - dt.date.fromisoformat(str(m.get("closed") or m.get("updated", "")))).days < 7:
                    st["done_7d"] += 1
            except ValueError:
                pass
    return st


def relabel(field, old, new, why):
    """Rewrite `field` on every card (open or closed) where it equals `old`. Returns how many."""
    n = 0
    for p in card_paths():
        meta = parse_card(p)
        if (meta.get(field) or "") == old:
            set_fields(p, {field: new, "updated": meta.get("updated", today())})
            append_log(p, f"{field} {old!r} → {new or '(none)'!r} ({why})", touch=False)
            n += 1
    return n


def reparent(old, new, names):
    """Goals that sat under duty `old` now sit under `new` ('' = under nothing)."""
    for n in names:
        f = project_file(n)
        if f and os.path.isfile(f) and (load_project(n) or {}).get("parent") == old:
            set_fields(f, {"parent": new})


def project_line(r):
    """`[goal · active · due 2026-12-19]` — what PROJECT.md says, for a one-line listing."""
    if not r.get("defined"):
        return "[no PROJECT.md]"
    bits = [r["kind"] or "kind?", r["status"]] + ([f"due {r['due']}"] if r["due"] else [])
    return "[" + " · ".join(bits) + "]"


def cmd_project(args):
    from .asks import read_asks
    projects = load_projects()
    names = [x["name"] for x in projects]
    metas = [parse_card(p) for p in card_paths()]
    usage = {}
    for m in metas:
        name = m.get("project") or ""
        usage[name] = usage.get(name, 0) + 1
    a = args.action
    if a == "list":
        rows = [dict(project_info(pr), count=usage.get(pr["name"], 0), listed=True) for pr in projects]
        rows += [dict(project_info({"name": n, "paths": []}), count=c, listed=False)
                 for n, c in usage.items() if n and n not in names]
        for m in metas:
            m["asks"] = read_asks(m["dir"])
        for r in rows:
            r["stats"] = project_stats(r["name"], metas)
        if args.json:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
            return
        # Padded per column (the "on you" part and the kind/status part vary in width).
        width = lambda xs: max([len(x) for x in xs] or [0])
        nw = max(22, width([r["name"] for r in rows]))
        onme = [f"({r['stats']['on_me']} on you)" if r["stats"]["on_me"] else "" for r in rows]
        ow, lw = width(onme), width([project_line(r) for r in rows])
        for r, om in zip(rows, onme):
            st = r["stats"]
            print(f"{r['name']:<{nw}} {st['open']:>3} open {st['done']:>3} done"
                  + (f" {om:<{ow}}" if ow else "")
                  + f"  {project_line(r):<{lw}}  {', '.join(r['paths']) or '-'}"
                  + ("" if r["listed"] else "   (not in list — used on cards)"))
        if usage.get(""):
            print(f"{'(no project)':<{nw}} {usage['']:>3} task(s)")
        return
    if a == "order":
        # Projects named here go first, in this order; any others keep their place after them.
        wanted = [n for n in args.names if n in names]
        if not wanted:
            die("usage: hq project order NAME NAME ...")
        rest = [pr for pr in projects if pr["name"] not in wanted]
        by_name = {pr["name"]: pr for pr in projects}
        save_projects([by_name[n] for n in wanted] + rest)
        return
    if a == "auto":
        n = 0
        for p in card_paths():
            meta = parse_card(p)
            if meta.get("project"):
                continue
            name = project_for_dirs(meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else [])
            if name:
                set_fields(p, {"project": name, "updated": meta.get("updated", today())})
                n += 1
        print(f"assigned {n} task(s)")
        return
    if not args.names:
        die(f"usage: hq project {a} NAME ...")
    name = check_category(args.names[0])
    known = name in names or usage.get(name)
    if a in ("show", "brief", "set", "section", "check") and not known:
        die(f"no project {name!r}")
    if a == "show":
        info = project_info(next((pr for pr in projects if pr["name"] == name), {"name": name, "paths": []}))
        for m in metas:
            m["asks"] = read_asks(m["dir"])
        info["stats"] = project_stats(name, metas)
        info["tasks"] = [{"id": m.get("id"), "title": m.get("title"), "status": m.get("status")}
                         for m in metas if (m.get("project") or "") == name]
        if args.json:
            print(json.dumps(info, ensure_ascii=False, indent=1))
            return
        st = info["stats"]
        print(f"{name}{' — ' + info['title'] if info['title'] and info['title'] != name else ''}  {project_line(info)}")
        print(f"file:  {info['file'] or '-  (hq project set ' + name + ' kind=goal|duty makes one)'}")
        print(f"paths: {', '.join(info['paths']) or '-'}")
        if info["jira"] or info["fixVersions"]:
            print(f"jira:  {', '.join(info['jira']) or '-'}   fix versions: {', '.join(info['fixVersions']) or '-'}")
        print(f"tasks: {st['open']} open, {st['done']} done ({st['done_7d']} in the last 7 days), "
              f"{st['abandoned']} abandoned · {st['on_me']} waiting on you")
        if info["parent"] or info["phases"]:
            print(f"under: {info['parent'] or '-'}   phases: {', '.join(info['phases']) or '-'}")
        for label, k in (("Goal", "goal"), ("Out of scope", "out"), ("Done when", "done_when"), ("Brief", "brief")):
            if info[k]:
                print(f"\n{label}:\n{info[k]}")
        if info["templates"]:
            print("\nTemplates:")
            for t in info["templates"]:
                print(f"  {t['name']}: {t['title'] or '-'}" + (f"  ({len(t['todos'])} todo(s))" if t["todos"] else ""))
        return
    if a == "brief":
        # Exactly what a session on one of its tasks is given (task id shown as T-…).
        print(project_brief_text({"id": "T-…", "project": name}) or f"(project {name!r} has no PROJECT.md or no brief: sessions are told nothing about it)")
        return
    if a == "set":
        if len(args.names) < 2 and not (args.kind or args.title or args.due):
            die(f"usage: hq project set NAME key=value ... (keys: {', '.join(PROJECT_SET_KEYS)})")
        fields = check_project_fields(args.names[1:] + [f"{k}={v}" for k, v in
                                      (("kind", args.kind), ("title", args.title), ("due", args.due),
                                       ("parent", args.parent)) if v])
        cur = load_project(name) or {}
        if fields.get("kind", cur.get("kind")) == "duty" and fields.get("status", cur.get("status")) in ("done", "abandoned"):
            die("a duty is active or paused — it has no end (make it kind=goal first, if it does)")
        check_project_parent(name, fields, cur, names)
        if "kind" in fields and fields["kind"] != "duty" and cur.get("kind") == "duty":
            kids = [n for n in names if n != name and (load_project(n) or {}).get("parent") == name]
            if kids:
                die(f"{', '.join(kids)} sit(s) under {name!r}; move them first")
        ensure_project(name)
        print(ensure_project_file(name, fields))
        return
    if a == "section":
        # hq project section NAME goal|out|done_when|templates|brief [TEXT…] — TEXT, or stdin.
        if len(args.names) < 2 or args.names[1] not in PROJECT_SECTIONS:
            die(f"usage: hq project section NAME {'|'.join(PROJECT_SECTIONS)} [TEXT] (no TEXT: read stdin)")
        text = " ".join(args.names[2:]) if len(args.names) > 2 else sys.stdin.read()
        ensure_project(name)
        path = ensure_project_file(name)
        with card_lock(path):
            write_project_section(path, args.names[1], text, (load_project(name) or {}).get("kind", ""))
        set_fields(path, {})
        print(path)
        return
    if a == "check":
        # hq project check NAME N [done|open] — tick a Done when / Healthy when criterion.
        if len(args.names) < 2 or not args.names[1].isdigit() or (args.names[2:] and args.names[2] not in ("done", "open")):
            die("usage: hq project check NAME N [done|open]")
        path = project_file(name)
        if not path or not os.path.isfile(path):
            die(f"project {name!r} has no PROJECT.md")
        done = (args.names[2:] or ["done"])[0] == "done"
        with card_lock(path):
            text = tick_criterion(path, int(args.names[1]), done)
        set_fields(path, {})
        append_log(path, f"{'ticked' if done else 'unticked'}: {text}", touch=False)
        return
    if a == "add":
        name = check_project_name(name)
        if name in names:
            die(f"project {name!r} already exists")
        if same_name_project(name, names):
            die(f"project {same_name_project(name, names)!r} already exists — names that differ only in case would share a folder")
        fields = check_project_fields([f"{k}={v}" for k, v in
                                       (("kind", args.kind), ("title", args.title), ("due", args.due),
                                        ("parent", args.parent)) if v])
        check_project_parent(name, fields, {}, names)
        if same_name_project(name, list(usage)):
            die(f"tasks use {same_name_project(name, list(usage))!r} — names that differ only in case would share a folder")
        save_projects(projects + [{"name": name, "paths": [os.path.abspath(os.path.expanduser(x)) for x in args.path or []]}])
        print(ensure_project_file(name, fields))
    elif a == "paths":
        if name not in names:
            die(f"no project {name!r}")
        new_paths = [os.path.abspath(os.path.expanduser(x)) for x in args.names[1:]]
        save_projects([dict(pr, paths=new_paths) if pr["name"] == name else pr for pr in projects])
    elif a == "rename":
        if len(args.names) < 2:
            die("usage: hq project rename OLD NEW")
        new = check_project_name(args.names[1])
        if new in names and new != name:
            die(f"{new!r} already exists — to merge, use: hq project remove {name!r} --to {new!r}")
        if same_name_project(new, names, but=name):
            die(f"{same_name_project(new, names, but=name)!r} already exists — names that differ only in case would share a folder")
        if not known:
            die(f"no project {name!r}")
        old_file, new_file = project_file(name), project_file(new)
        if old_file and os.path.isfile(old_file) and new != name:
            old_dir, new_dir = os.path.dirname(old_file), os.path.dirname(new_file)
            if new.lower() == name.lower():
                # Only the case changes: on a case-insensitive disk new_dir "exists" — it is old_dir.
                tmp = f"{old_dir}.renaming-{os.getpid()}"
                os.rename(old_dir, tmp)
                os.rename(tmp, new_dir)
            else:
                if os.path.exists(new_dir):
                    die(f"{new_dir} already exists — move it away first")
                os.rename(old_dir, new_dir)
            set_fields(new_file, {"name": new})
            append_log(new_file, f"renamed {name!r} → {new!r}", touch=False)
        if name in names:
            save_projects([dict(pr, name=new) if pr["name"] == name else pr for pr in projects])
        else:
            save_projects(projects + [{"name": new, "paths": []}])
        reparent(name, new, [n for n in names if n != name])
        print(f"renamed {name!r} → {new!r} ({relabel('project', name, new, 'project renamed')} task(s) updated)")
    elif a == "remove":
        n_used = usage.get(name, 0)
        if n_used and args.to is None:
            print(f"hq: {n_used} task(s) are in {name!r}. Re-run with --to <project> to move them, "
                  f"or --to '' to leave them without a project.", file=sys.stderr)
            sys.exit(3)
        to = ""
        if args.to:
            to = check_category(args.to)
            if to == name:
                die("--to must be a different project")
            ensure_project(to)
        f = project_file(name)
        kept = ""
        if f and os.path.isdir(os.path.dirname(f)):
            # Never deleted: put aside, to read or move back by hand. First, so a failure here
            # leaves hq.json and the cards as they were.
            base = os.path.join(projects_dir(), ".removed", f"{name}-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}")
            dest, i = base, 1
            while os.path.exists(dest):
                i += 1
                dest = f"{base}-{i}"
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            os.rename(os.path.dirname(f), dest)
            kept = f"; its folder is now {dest}"
        save_projects([pr for pr in load_projects() if pr["name"] != name])
        reparent(name, to if to and (load_project(to) or {}).get("kind") == "duty" else "", [n for n in names if n != name])
        n = relabel("project", name, to, "project removed") if n_used else 0
        print(f"removed {name!r}" + (f" ({n} task(s) moved to {to or '(none)'!r})" if n else "") + kept)


# ---------------------------------------------------------------- retired standing grants
# HQ once had standing grants ("Yes, always" on an ask): a card's or PROJECT.md's `## Grants`
# (`## 授权`) section, and asks a session ended with `[grant: <wording>]`. They are gone, but files
# and sessions from then still have them. The heading still ends a PROJECT.md section (so what
# follows it parses, and no log line lands under it) and nothing reads what is under it; the
# suffix is dropped from an ask.
GRANTS_WORD_RE = re.compile(r"^(?:Grants|Standing grants|授权|常设授权)$", re.I)


def is_grants_heading(line):
    """`## Grants`, `## 授权`, or a two-language `## 授权 / Grants`."""
    return line.startswith("##") and not line.startswith("###") and \
        any(GRANTS_WORD_RE.match(w.strip()) for w in line[2:].split("/"))

GRANT_SUGGEST_RE = re.compile(r"\s*\[(?:grant|授权)[:：][^\[\]]*\]\s*$", re.I)


# A duty's Auto intake section (intake.py says what it holds), read here with the rest of PROJECT.md.
INTAKE_SOURCES = ("github-review",)         # the auto sources that make tasks so far
INTAKE_KEYS = ("repos", "workdir", "run", "permissions", "done", "focus", "title", "goal", "prompt")
INTAKE_YES = ("yes", "on", "true", "1", "是", "开")
INTAKE_NO = ("no", "off", "false", "0", "否", "关")
INTAKE_MANUAL_DONE = {
    "zh": "这个任务是自动来活建的，由用户自己关：不要写 `status: done` 或 `abandoned`；做完了写 `status: waiting-on-me`，"
          "`next:` 写明可以关了。",
    "en": "This task came in by itself and the user closes it: never write `status: done` or `abandoned`; when "
          "the work is finished, write `status: waiting-on-me` with a `next:` saying it is ready to close.",
}


def project_intake(text):
    """An Auto intake section, as written → {source: {key: value, "problems": [...]}}. `repos` is a
    list; run, focus are booleans; permissions is ask|review (`skip` is read as review); done is
    manual|auto; the rest are
    strings. Comments are skipped outside the prompt; the prompt keeps every line as written until
    a `### <source>` line (so a `### Steps` of its own stays in it)."""
    out, cur, key, inc = {}, None, None, False
    for line in text.split("\n"):
        h = re.match(r"^###\s+(.+?)\s*$", line)
        if h and (key != "prompt" or h.group(1).strip().lower() in AUTO_SOURCES):
            cur, key, inc = {"problems": []}, None, False
            out[h.group(1).strip().lower()] = cur
            continue
        if cur is None:
            continue
        if key == "prompt":                 # the prompt takes the rest of the block
            cur["prompt"] += "\n" + line
            continue
        vis, inc = visible_text(line, inc)
        if not vis.strip():
            continue
        m = re.match(r"^\s*([A-Za-z]+)\s*[:：]\s*(.*?)\s*$", vis)
        if m and m.group(1).lower() in INTAKE_KEYS:
            key = m.group(1).lower()
            # The prompt's first line as written (comments and all); the others' without comments.
            cur[key] = re.sub(r"^\s*prompt\s*[:：]\s*", "", line, flags=re.I) if key == "prompt" else m.group(2)
        elif key == "goal":
            cur["goal"] += "\n" + vis.strip()
        elif m:
            cur["problems"].append(f"unknown key {m.group(1)!r} (keys: {', '.join(INTAKE_KEYS)})")
            key = None
        else:
            cur["problems"].append(f"not a `key: value` line: {vis.strip()}")
    for src, c in out.items():
        if "prompt" in c:
            c["prompt"] = c["prompt"].strip()
        c["repos"] = [r for r in re.split(r"[\s,，]+", c.get("repos", "")) if r]
        for k, default in (("run", False), ("focus", True)):
            v = str(c.get(k, "")).strip().lower()
            if v and v not in INTAKE_YES + INTAKE_NO:
                c["problems"].append(f"{k}: yes or no (got {v!r})")
            c[k] = (v in INTAKE_YES) if v else default
        for k, allowed in (("permissions", ("ask", "review")), ("done", ("manual", "auto"))):
            v = str(c.get(k, "")).strip().lower()
            if k == "permissions" and v == "skip":
                v = "review"            # never skips permission checks any more (see INTAKE_REVIEW_TOOLS)
            if v and v not in allowed:
                c["problems"].append(f"{k}: {' or '.join(allowed)} (got {v!r})")
                v = ""
            c[k] = v or allowed[0]
        if c.get("workdir"):
            d = os.path.normpath(os.path.expanduser(c["workdir"]))
            if not os.path.isdir(d):
                c["problems"].append(f"workdir: no folder {c['workdir']} — no session starts until it exists")
            elif not ok_workdir(d):
                c["problems"].append(f"workdir: {c['workdir']} — /, the home folder and the HQ root are never a workdir")
        if "*" in c["repos"] and c["permissions"] == "review" and c["run"]:
            c["problems"].append("repos: * with permissions: review would let anyone who asks for your review run a "
                                 "session that asks you nothing — no session starts; name the repositories")
        if src not in INTAKE_SOURCES:
            c["problems"].append(f"{src}: makes no tasks yet (sources that do: {', '.join(INTAKE_SOURCES)})")
    return out


def intake_lang(card):
    """The language of the duty a card is in (its PROJECT.md's headings): zh or en."""
    p = load_project(parse_card(card).get("project") or "")
    return (p or {}).get("lang") or "en"


def intake_manual(card):
    """A task that came in by itself and waits for the user to close it (`intake_done: manual`)."""
    m = parse_card(card)
    return bool(m.get("intake")) and str(m.get("intake_done") or "manual") != "auto"
