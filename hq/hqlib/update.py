"""hq-update blocks: applying one to a card, and catching repeated @me todos."""
import os
import re

from .core import (
    atomic_write, card_lock, is_placeholder, ok_workdir, STATUSES, TODO_RE, TODO_TIME_RE, UPDATE_KEYS,
    update_lines,
)
from .cards import (
    add_todo, append_log, card_todos, parse_card, set_fields, STATUS_HEADING_RE, todo_owner, todo_plain,
)
from .refs import KEY_MARK, merge_refs, ref_key, unmarked
from .history import history_drop_links, log_tick, process_ref, read_history
from .projects import intake_lang, intake_manual, INTAKE_MANUAL_DONE, load_projects
from .asks import CLOSED_STATUSES, hold_close, open_ask_count, open_me_todos, settle_status


# ---------------------------------------------------------------- repeated @me todos
# A session forgets which @me todos it already wrote (a compaction, a new session) and words the
# same step again: "review 并合并 #127、#129、#131" next to "review 并合并 #126、#127、#129、#131", a
# second "从 main 安装". The user ticks each copy. So a new @me todo from a session that repeats an
# open one is refused, with the open one's text to `change:` instead. Repeats, checked on real
# cards: both about installing from main (one install covers both); both about reviewing or merging
# a PR they share; or the same links and nearly the same words. Plain word likeness is not enough:
# "review 并合并 PR #110" and "… #111" are two todos. `todo!:` adds one anyway.
DUP_TEXT_MIN = 0.8
DUP_INSTALL_RE = re.compile(r"(?<![A-Za-z])(?:re)?install(?:s|ed|ing)?(?![A-Za-z])|安装|重装", re.I)
DUP_MAIN_RE = re.compile(r"(?<![A-Za-z])main(?![A-Za-z])|install\.sh", re.I)
DUP_PULL_RE = re.compile(r"github\.com/[^/\s]+/[^/\s]+/pull/([0-9]+)", re.I)


def todo_names(text):
    """The PRs, builds and issues a todo names: `#12` (a PR link counts as its number), `ABC-12`."""
    return ({"#" + n for n in AUTOCLOSE_HASH_RE.findall(text)} | {"#" + n for n in DUP_PULL_RE.findall(text)}
            | set(AUTOCLOSE_KEY_RE.findall(text)))


def text_likeness(a, b):
    """How alike two texts are, 0–1: shared character pairs (Dice), punctuation and spaces aside —
    works the same for Chinese, which has no spaces to split words on."""
    pairs = lambda t: (lambda n: {n[i:i + 2] for i in range(len(n) - 1)} or {n})(re.sub(r"[\W_]+", "", t.casefold()))
    x, y = pairs(a), pairs(b)
    return 2 * len(x & y) / (len(x) + len(y)) if x and y and x != {""} and y != {""} else 0.0


def todo_repeats(new, old):
    """Why `new` repeats the open todo `old` (both plain text), or None."""
    inst = lambda t: bool(DUP_INSTALL_RE.search(t) and DUP_MAIN_RE.search(t))
    if inst(new) and inst(old):
        return "both are about installing from main: one install todo covers them"
    shared = todo_names(new) & todo_names(old)
    pr = AUTOCLOSE_VERBS["pr"]
    if shared and not inst(new) and not inst(old) and pr.search(new) and pr.search(old):
        return f"both are about reviewing or merging {', '.join(sorted(shared))}"
    if todo_names(new) == todo_names(old) and text_likeness(new, old) >= DUP_TEXT_MIN:
        return "nearly the same words"
    return None


def match_todo(todos, kind, want, settled=()):
    """The todo a `done:` / `drop:` line means: (todo, None) to change, (None, None) when it is
    already settled (a repeat, or ticked on the board meanwhile), (None, problem) otherwise.

    Exact text first, over every todo whatever its state — so a repeated `done: rerun the suite`
    can't fall through to a substring match and tick `rerun the suite on CI` instead. A
    substring is tried only when no todo has that exact text, and only among open ones.
    `settled` holds the closed todos in HISTORY.md as (owner, text): a repeat of one that has
    moved off the card is settled too, not a substring hunt."""
    owner = todo_owner(want)
    key = " ".join(todo_plain(want).split()).casefold()
    mine = [x for x in todos if owner is None or todo_owner(x[2].group(3)) == owner]
    open_ = [x for x in mine if x[2].group(2) == " "]
    exact = [x for x in mine if x[3].casefold() == key]
    if not exact and key and any(t == key and (owner is None or o == owner) for o, t in settled):
        return None, None
    if exact:
        live = [x for x in exact if x[2].group(2) == " "]
        if not live:
            return None, None
        hits = live
    else:
        hits = [x for x in open_ if key and key in x[3].casefold()]
    if len(hits) == 1:
        return hits[0], None
    listing = "; ".join(f"\"{x[3]}\"" for x in (hits or open_)[:8]) or "none"
    return None, (f"`{kind}: {want}` matches {len(hits) or 'no'} open todos — "
                  f"{'candidates' if hits else 'open todos'}: {listing}")


def plan_change(todos, settled, v, picked, changes):
    """A `change: <open todo> => <new text>` line: queues ((todo), new line text) on `changes`, or
    returns what is wrong. The new text keeps the todo's owner unless it names one. A change already
    made — the old text no longer an open todo, the new one on the card (open or closed since) or in
    HISTORY.md — does nothing, so a resent block is never refused over it."""
    key = lambda t: " ".join(todo_plain(t).split()).casefold()
    is_open = lambda x: x[2].group(2) == " "
    # Every split at an arrow: a todo's own text may hold one ("map a => b"). The one whose old
    # part is an open todo's text wins; else one already made; else the first.
    splits = [(v[:m.start()].strip(), " ".join(v[m.end():].split())) for m in re.finditer(r"\s*(?:=>|⇒)\s*", v)]
    splits = [(o, n) for o, n in splits if o and n]
    if not splits:
        return f"`change: {v}` — write it as `change: <text of an open todo> => <its new text>`"
    closed = {x[3].casefold() for x in todos if not is_open(x)} | {t for _, t in settled}

    def has(text):    # an open todo with exactly this text — and this owner, when it names one
        o, p = todo_owner(text), " ".join(todo_plain(text).split())
        return any(is_open(x) and x[3] == p and (o is None or todo_owner(x[2].group(3)) == o) for x in todos)

    made = lambda o, n: not has(o) and (has(n) or key(n) in closed)
    old, new = next(((o, n) for o, n in splits if any(is_open(x) and x[3].casefold() == key(o) for x in todos)),
                    next(((o, n) for o, n in splits if made(o, n)), splits[0]))
    if made(old, new):
        return None
    if is_placeholder(new):
        return f"`change: {old} => {new}` — the new text is the template's placeholder, not a value"
    pick, problem = match_todo(todos, "change", old, settled)
    if problem:
        return problem
    if not pick:
        return f"`change: {old} => …` — that todo is already closed; add a new one with `todo:`"
    if pick[0] in picked or pick[0] in {c[0][0] for c in changes}:
        return f"`change: {old} => …` — that todo is already ticked, dropped or changed in this block"
    if todo_owner(new) is None:
        o = re.match(r"(@\S+)\s", TODO_TIME_RE.sub("", pick[2].group(3)).strip() + " ")
        if o:
            new = f"{o.group(1)} {new}"
    if new == TODO_TIME_RE.sub("", pick[2].group(3)).strip():
        return None                     # nothing to change
    owner = todo_owner(new)
    twin = next((x for x in todos if is_open(x) and x[0] != pick[0] and x[3].casefold() == key(new)
                 and todo_owner(x[2].group(3)) == owner), None)
    if twin:
        return (f"`change: {old} => {new}` — that is the open todo \"{twin[3]}\" already; "
                f"drop one of them with `drop:` instead")
    changes.append((pick, new))
    return None


def repeated_todos(todos, picked, changes, adds):
    """The problems of `todo: @me …` lines that repeat an open @me todo (todo_repeats): the open
    ones this block leaves open, as changed, and the ones added before it in the block."""
    changed = {c[0][0]: c[1] for c in changes}
    live = [todo_plain(changed.get(x[0], x[2].group(3))) for x in todos
            if x[2].group(2) == " " and x[0] not in picked
            and todo_owner(changed.get(x[0], x[2].group(3))) == "me"]
    problems = []
    for v, force in adds:
        if todo_owner(v) != "me":
            continue
        new = todo_plain(v)
        if any(new.casefold() == o.casefold() for o in live):
            continue              # the same text again: skipped when added, as before
        if not force:
            hit = next(((o, r) for o in live for r in [todo_repeats(new, o)] if r), None)
            if hit:
                problems.append(f"`todo: {v}` repeats the open todo \"{hit[0]}\" ({hit[1]}). Rewrite that one "
                                f"with `change: {hit[0]} => <new text>`, or close it with `done:` / `drop:` in "
                                f"this block; if it really is a separate step, write `todo!: {v}`")
                continue
        live.append(new)
    return problems


def apply_update(card, block, via="session", change=None, settle=True, hold=False):
    """Apply an hq-update block — the card changes a session writes in its reply instead of running
    `hq log/set/ref/addtodo/todo` one tool call at a time. Every such call is another model round trip
    that re-reads the whole conversation; the block costs a few output tokens.

    All or nothing: the whole block is checked first, and if any line can't be applied nothing
    is written and the problems are returned, for the Stop hook to send back. Applying the good
    lines anyway made the natural retry — the whole block again, corrected — add every todo and
    log line twice. Adding is idempotent too (an open todo with the same text or a log line already
    there is skipped), so a block that does arrive twice changes nothing. A `ref:` line whose URL
    is already on the card replaces that entry's title in place — on purpose, so a title can move
    on (PR #9 open → merged) — and repeating it changes nothing.
    A block made only of template placeholders is the protocol's example echoed back: ignored.
    `change`, a dict, gets the card's status before and after ("from", "to"), both read under the
    same lock as the write, so a status set elsewhere at the same moment is never taken for this one;
    "status" when the block was applied with a status line, "me_ticked" when it ticked off or
    dropped an @me todo, "wrote" what it changed on the card (_apply_update's `wrote`). `settle`: let such a tick take the task out of waiting-on-me (the Stop
    hook passes False and decides once for the whole reply)."""
    entries = update_lines(block)
    if entries and all(v and is_placeholder(v) for _, v in entries):
        return []
    with card_lock(card):
        before, me_before = parse_card(card).get("status"), open_me_todos(card)
        held = None
        if hold:     # `hold`: a close over open asks is held (hold_close) — the Stop hook's case
            block, held = hold_close(card, block)
            entries = update_lines(block)
        wrote = {}
        problems = _apply_update(card, entries, via, closing=held, wrote=wrote)
        if held and not problems:
            append_log(card, f"status {held} held (auto, {via}): {open_ask_count(card)} open question(s) on the task — it closes once they are answered", touch=False)
        said = not problems and any(k == "status" for k, _ in entries)
        me_ticked = not problems and open_me_todos(card) < me_before
        if settle and me_ticked and not said:
            settle_status(card, via)
        if change is not None:
            change.update({"from": before, "to": parse_card(card).get("status"),
                           "status": said, "me_ticked": me_ticked, "held": None if problems else held,
                           "wrote": {} if problems else wrote})
        return problems


def _apply_update(card, entries, via, closing=None, wrote=None):
    """`wrote`, a dict, gets a count for each kind of change actually made — next, state, todo,
    done, drop, change, log, ref, workdir, project — for the Stop hook's echo to the user. What
    was already there (a todo or log line repeated, the same next) is not counted."""
    wrote = {} if wrote is None else wrote
    count = lambda k, n=1: n and wrote.__setitem__(k, wrote.get(k, 0) + n)
    problems, fields, state = [], {}, []
    adds, marks, changes, logs, refs, dirs, pins = [], [], [], [], [], [], set()
    auto_logs = set()      # log lines HQ adds itself (a project move): not the session's, not counted
    text = open(card, encoding="utf-8").read()
    lines = text.split("\n")
    todos = card_todos(lines)
    hist = read_history(card)
    settled = [(todo_owner(t.group(3)), todo_plain(t.group(3)).casefold())
               for t in (TODO_RE.match(i.split("\n", 1)[0]) for i in hist["Todos"]) if t]
    picked = set()
    for k, v in entries:
        if k not in UPDATE_KEYS:
            problems.append(f"not an hq-update line: {v if k is None else k + ': ' + v}")
        elif k == "touch":
            continue
        elif not v:
            problems.append(f"`{k}:` with nothing after it")
        elif is_placeholder(v):
            problems.append(f"`{k}: {v}` is the template's placeholder, not a value")
        elif k == "status":
            if v.lower() in CLOSED_STATUSES and via == "session" and intake_manual(card):
                problems.append(f"`status: {v}` — {INTAKE_MANUAL_DONE[intake_lang(card)]}")
            elif v.lower() in STATUSES:
                fields["status"] = v.lower()
                if parse_card(card).get("intake"):
                    # Who closed it, for the duty's "came in by itself" list.
                    fields["intake_closed_by"] = via if v.lower() in CLOSED_STATUSES else None
            else:
                problems.append(f"status must be one of {', '.join(STATUSES)} (got {v!r})")
        elif k == "next":
            fields["next"] = v
        elif k == "state" and v.lstrip().startswith("#"):
            # A heading here would start a section of its own (a forged `## Log`, say).
            problems.append(f"`state: {v}` — a state line can't be a heading; write it as plain text")
        elif k == "state":
            # A checkbox here would turn into a real todo in the Status section.
            state.append(re.sub(r"^-\s*\[[ xX\-]\]\s*", "", v))
        elif k in ("todo", "todo!"):
            adds.append((v, k == "todo!"))
        elif k in ("done", "drop"):
            pick, problem = match_todo(todos, k, v, settled)
            if problem:
                problems.append(problem)
            elif pick and pick[0] in {c[0][0] for c in changes}:
                problems.append(f"`{k}: {v}` — that todo is also changed in this block; do one or the other")
            elif pick and pick[0] not in picked:
                picked.add(pick[0])
                marks.append((k, pick))
        elif k == "change":
            change_problem = plan_change(todos, settled, v, picked, changes)
            if change_problem:
                problems.append(change_problem)
        elif k == "log":
            logs.append(v)
        elif k == "ref":
            refs.append(v)
        elif k == "ref!":
            # A key link: stays on the card even when it is one build or comment.
            refs.append(KEY_MARK + unmarked(v) if process_ref(unmarked(v)) else unmarked(v))
            pins.add(ref_key(v))
        elif k == "project":
            # Moves the task to another project — an existing one only: projects are the user's to make.
            known = {x["name"] for x in load_projects()}
            if v not in known:
                problems.append(f"`project: {v}` is not a project (there are: {', '.join(sorted(known)) or 'none'}); "
                                "only the user makes new ones")
            elif v != (parse_card(card).get("project") or ""):
                fields["project"] = v
                count("project")
                moved = f"project {parse_card(card).get('project') or '(none)'!r} → {v!r}"
                logs.append(moved)
                auto_logs.add(moved)
        elif k == "workdir":
            d = os.path.normpath(os.path.expanduser(v))
            if not os.path.isabs(d) or not os.path.isdir(d):
                problems.append(f"`workdir: {v}` is not an existing absolute path")
            elif not ok_workdir(d):
                problems.append(f"`workdir: {v}` — /, the home folder and the HQ root are never a workdir")
            else:
                dirs.append(d)
    if state and not STATUS_HEADING_RE.search(text):
        problems.append("`state:` — the card has no `## Status` / `## 当前状态` section")
    if via == "session":
        problems += repeated_todos(todos, picked, changes, adds)
    if problems:
        return problems

    # Ticks first, against the line numbers checked above; adding todos would shift them.
    for k, (i, num, t, _) in marks:
        lines[i] = f"{t.group(1)}- [{'x' if k == 'done' else '-'}] {t.group(3)}"
    for (i, num, t, _), new in changes:
        # In place: same spot, same creation time — the user sees it updated, not a new one.
        stamp = TODO_TIME_RE.search(t.group(3))
        lines[i] = f"{t.group(1)}- [{t.group(2)}] {new}" + (f" {stamp.group(0).strip()}" if stamp else "")
    for k, _ in marks:
        count(k)
    count("change", len(changes))
    if marks or changes:
        atomic_write(card, "\n".join(lines))
        for k, (i, num, t, _) in marks:
            log_tick(card, f"todo #{num} → {k} ({via}): {TODO_TIME_RE.sub('', t.group(3))}")
        for (i, num, t, _), new in changes:
            log_tick(card, f"todo #{num} → changed ({via}): {TODO_TIME_RE.sub('', t.group(3))} ⇒ {new}")
    for item, _ in adds:
        have = {(todo_owner(x[2].group(3)), x[3].casefold())
                for x in card_todos(open(card, encoding="utf-8").read().split("\n")) if x[2].group(2) == " "}
        if (todo_owner(item), " ".join(todo_plain(item).split()).casefold()) not in have:
            add_todo(card, item)
            count("todo")
    if state:
        text = open(card, encoding="utf-8").read()
        m = STATUS_HEADING_RE.search(text)
        if m.group(1).strip() != "\n".join(state).strip():
            count("state")
        atomic_write(card, text[:m.start(1)] + "\n".join(state) + "\n\n" + text[m.end(1):])
    meta = parse_card(card)
    if refs:
        have = meta.get("refs") if isinstance(meta.get("refs"), list) else []
        merged = merge_refs(have, refs)
        if merged != have:
            fields["refs"] = merged
            old = {ref_key(r): str(r).strip() for r in have}
            count("ref", sum(ref_key(r) not in old for r in merged))
            count("ref_updated", sum(ref_key(r) in old and old[ref_key(r)] != r for r in merged))
    if pins:
        history_drop_links(card, pins)
    if dirs:
        have = meta.get("workdirs") if isinstance(meta.get("workdirs"), list) else []
        known = {os.path.normpath(h) for h in have}
        fields["workdirs"] = have + [d for d in dict.fromkeys(dirs) if d not in known]
        count("workdir", len(fields["workdirs"]) - len(have))
    if fields.get("next") is not None and fields["next"] != str(meta.get("next") or ""):
        count("next")
    if "status" in fields:
        fields["closing"] = closing     # a status written outright replaces a held close
    set_fields(card, fields)            # also stamps `updated`, so a `touch` block is a touch
    # A log line already there — on the card, or moved to HISTORY.md past the budget — isn't added again.
    logged = open(card, encoding="utf-8").read() + "\n" + "\n".join(hist["Log"])
    for msg in dict.fromkeys(logs):
        if not re.search(r"^- \d{4}-\d\d-\d\d \d\d:\d\d:\d\d: " + re.escape(msg) + r"\s*$", logged, re.M):
            append_log(card, msg)
            count("log", msg not in auto_logs)
    return []


# How autoclose reads a todo (autoclose.py says what it does with it); a repeated @me todo is caught
# the same way. ASCII-only edges, not \b: Chinese characters count as word characters, and
# "跟进QA-9" or "合并#7" are written without spaces.
AUTOCLOSE_HASH_RE = re.compile(r"(?<![A-Za-z0-9_/&#])#([0-9]+)(?![0-9A-Za-z_])")
AUTOCLOSE_KEY_RE = re.compile(r"(?<![A-Za-z0-9_/.-])([A-Z][A-Z0-9]+-[0-9]+)(?![A-Za-z0-9_-])")
_ascii_word = lambda words: rf"(?<![A-Za-z])(?:{words})(?![A-Za-z])"
AUTOCLOSE_VERBS = {
    "pr": re.compile(_ascii_word("merge[sd]?|review|approve|land") + "|合并|合入|审阅|审核|审查|评审", re.I),
    "jira": re.compile(_ascii_word("close|resolve|fix|verify|follow[ -]?up") + "|关闭|关掉|关单|解决|修复|验证|跟进", re.I),
    # Not a bare 等: it is also "etc." (等人, 等 PR).
    "jenkins": re.compile(_ascii_word("wait|watch|finish(?:es|ed)?") + "|等待|等着|盯|跑完|等.{0,80}?(?:跑完|结束|完成|出结果)", re.I),
}
