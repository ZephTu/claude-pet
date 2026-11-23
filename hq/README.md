# HQ — run Claude Code sessions as a team, not a pile of tabs

Once you keep a dozen Claude Code sessions open across several repos, the hard part is no
longer the work — it is remembering what each session was doing, what it asked you, and
whether you ever answered. HQ moves that state out of the conversations and into files:

| Layer | What it is | Lives |
|---|---|---|
| **Task card** | `tasks/T-012-slug/TASK.md`: goal, status, next step, todos, log | until the task is done |
| **Asks ledger** | `tasks/T-012-slug/asks.jsonl`: every question Claude put to you, until you answer it | with the task |
| **Session** | a working thread *bound* to one task; disposable | as long as you like |
| **Lead** (optional) | an agent role (`.claude/agents/*-lead.md`) that owns a category of tasks | long-term |

A session can be closed at any time: the next one runs `/task T-012`, reads the card and
carries on. You look at one board instead of twelve terminals.

## Install

Requires macOS or Linux, Claude Code, and `python3` (3.9+, standard library only).

```bash
hq/install.sh --root ~/claude-hq      # where your task cards will live (any directory)
```

The installer first prints every change it is about to make and asks before doing anything
(`--yes` skips the question for scripts). What it can add:

| Where | What | Skip with |
|---|---|---|
| `~/.claude/hq/` | the `hq` CLI, templates, config, session bindings | — |
| your task root | `tasks/`, `templates/`, `hq.json`, a `CLAUDE.md` for that folder — only missing files | — |
| `~/.claude/commands/` | `/task` and `/board` (not if you already have commands by those names) | `--no-commands` |
| `~/.claude/settings.json` | three hooks (SessionStart, UserPromptSubmit, Stop), appended after a backup | `--no-hooks` |

It never edits a global CLAUDE.md. The hooks are user-level because your sessions live in many
directories, but they only act in sessions bound to a task; anywhere else they read one small
JSON file and exit. With `--no-hooks` the board, cards and CLI all work — questions just aren't
captured automatically and sessions don't get the task rules.

**Reading:** `hq sessions` / `hq peek` (and the board's Sessions column) read live sessions'
recent messages from their transcripts under `~/.claude/projects`. Nothing leaves the machine.
`hq peek <sid> --meta --json` also returns `items` (messages and one-line tool calls in order —
`{kind:"tool", id, name, title, label, stat, status: ok|error|pending|background|stopped, ts, endTs}`),
`turn` (`start`, `done`, `ms`, output `tokens`, `context`) and `todos` (Claude's latest
TodoWrite / TaskCreate list: `{text, status, active}`); `hq peek <sid> --tool <tool_use id>`
prints one call's full input and output (an Edit's diff), `--json` for the fields.

**Jump log:** `hq jumps [--days 7] [--json]` summarises `~/.claude/pet/jumps.jsonl`, which
Claude Pet appends to on every ↗ Jump — counts by the session's state at the time
(`permission`, `question`, `replied`, `working`, `agent`, `interrupted`, `idle`, `gone`) × where
it was clicked (`board-card`, `board-sessions`, `board-peek`, `board-context`, `pet-list`,
`pet-finished`, `pet-notice`, `hotkey`; `board` if the page did not say), plus how many had
their Peek opened in the 10 minutes before. Clicks whose terminal can't be found are logged
too. One JSON object per line: `at`, `session`, `source`, `state`, and when known `view`
(board tab), `task`, `project`, `context` (% of the auto-compact window), `waited` (seconds in
that state; for `interrupted`, since it went quiet), `peekedAgo` (seconds since its Peek was
last opened — refreshes while open don't count — since the pet started), `terminal` (left out when
none was found).

Re-run `hq/install.sh` to upgrade. `hq/uninstall.sh` removes hooks, commands and CLI and
leaves your cards alone.

## Start from the sessions you already have

```bash
hq scan                                   # read-only: suggested projects + recent sessions
hq scan --apply-projects --only api,web   # create the ones you want
```

Then run `/hq-onboard` in any Claude Code session: Claude reads your recent sessions, drafts task
cards per project, shows them and asks before creating anything, and binds live sessions to their
tasks. The board offers the same on an empty board and under Projects → Suggest from sessions.

## Daily use

The full user guide (both languages) is built into the board: open it with **Guide** in the
board's top bar. Its source is `Resources/pet/board/guide.html`.


```text
/board                    in any session: open asks, your @me todos, every open task
/task T-012               bind this session to T-012 and pick up from its card
/task Rerun perf baseline create a new card and bind to it
```

Or from a shell: `hq board`, `hq show T-012`, `hq asks`, `hq ask resolve T-012.3 drop`,
`hq project list|show|brief|add|set|paths|rename|remove|auto|order` (see Projects), `hq category list|add|rename|remove`, `hq ask reopen T-012.3`, `hq ask snooze T-012.3 [--until 2026-11-22T09:00]` (Later: hidden until then — tomorrow by default; `--until ""` brings it back), `hq ref add|remove|restore T-012 <url>`, `hq peek <session-id-prefix> [--meta] [--tool ID]` (live or ended), `hq history T-012` (the task's sessions, newest first, with what resuming one needs),
`hq todo T-012 2 done`, `hq set T-012 status=blocked "next=wait for token"`, `hq log T-012 "…"`,
`hq grant list|add|revoke T-012 …` (standing grants, below).

### Where things stand: `hq status`

`hq status [T-012 …] [--focus] [--flagged] [--json]` sums a task up from the card and its
sessions, without a model: status, next, the card's state section, the last 3 Log entries, open
todos (@me / @claude / others, each with how long it has been open), unanswered asks with how long
they have waited, and the task's sessions (state, last activity, context share, last messages —
about `hq peek -n 3`). About 1k tokens a task. No ids: every open task, plus done ones with a live
session; `--focus` the Focus list's; `--flagged` only tasks with a flag. `--json` gives
`{now, tasks: [{id, …, flags: [{kind, text, text_zh, …}]}]}`.

Flags — where the card and the sessions disagree:

| kind | when |
|---|---|
| `card-behind` | a session not mid-turn (neither working nor held at a prompt) called tools more than 10 min after the card was last written |
| `idle-waiting` | an open task's next/state says it waits on a run (a wait word — wait on, watching, once … finishes, 等, 盯, 跑完后 … — and a machine word — build, job, CI, test, #12345, 构建, 跑 …), but nothing is working on it, waiting on you or running in the background, for 30 min |
| `stale` | open and not updated for 7 days |
| `done-live` | done or abandoned with a session still running |
| `over-budget` | the card is over 16 KB, 30 links or 30 todos |

A task's sessions are the ones bound to it and the ones its card lists, less any since bound to
another task. The board shows the Focus tasks' flags as ⚠ lines on their cards (`hq status
--focus --json`, read about once a minute); done tasks leave Focus, so `done-live` shows only here.

### What a bound session does differently

The hooks inject a short protocol into the session (see `protocol()` in `bin/hq`):

1. **The card is the source of truth.** Claude reads it first and writes progress back — not
   with `hq log/set/ref/addtodo/todo` calls (each tool call is another model round trip over
   the whole conversation; measured at 5–10% of a task session's tokens) but with a block at
   the end of its reply, which the Stop hook applies:

   ````markdown
   ```hq-update
   status: blocked
   next: wait for infra's token
   state: build is green; waiting on the token
   todo: @me send the token request
   done: rerun the suite
   log: picked plan v2 because it is cheaper
   ref: PR #9 https://github.com/org/repo/pull/9
   workdir: /abs/path/it/started/working/in
   ```
   ````

   Only the lines that changed. `todo` / `done` / `drop` / `log` / `ref` / `workdir` may
   repeat; `state` lines replace the card's Status (当前状态) section; `done` / `drop` match an
   open todo by its text (exactly — a todo already ticked is then a no-op — or else a substring
   that fits only one open todo). `project: NAME` moves the task to an existing project — a
   name not in `hq.json` refuses the whole block, since only the user makes projects. A block holding just `touch` stamps the card when nothing
   changed. Only a block at the end of the reply counts, at the start of a line and outside any
   other fence; one shown mid-reply, or made of template placeholders (`<…>`), is an example.
   Keys take a full-width colon too, and one pair of quotes round a value is dropped.

   All or nothing: if any line cannot be applied, nothing in the block is written and the
   problems (with candidate todos) are sent back once; a todo, log line or ref already on the
   card is never added twice, so resending the whole block is safe. If another Stop hook ends
   the turn first, the problems are told at the next prompt instead. Card writes from hooks,
   the board and the CLI hold a per-card lock (`~/.claude/hq/state/locks/`). A turn that runs longer than two minutes without
   touching the card is sent back once to update it.
2. **Questions to you are tracked.** When Claude needs a decision, a confirmation or an
   action from you, it ends its reply with a block:

   ````markdown
   ```hq-asks
   - Approve plan v2 (Neo4j first, graph500 scale 22/24/26)?
   - Ask Chengjie which dataset the prospect used
   ```
   ````

   The Stop hook files each line as an ask (`T-012.3`, `T-012.4`, …). Unanswered asks are
   re-injected every turn and shown on the board until you respond — an ask you skipped is
   never treated as "no".

   **Claude's open todos come along at session start.** SessionStart — for every source:
   `startup`, `resume`, `clear` and `compact` — appends the card's open `@claude` todos to the
   context, each exactly as written on the card, with the instruction to check them against how
   things stand and tick finished ones with `done: <text>` / drop obsolete ones with
   `drop: <text>` in the next `hq-update` (after a compaction it adds that the list is the card's,
   not the session's memory of it). At most 20 todos and 2000 characters of todo text: the newest
   that fit are listed, in card order, and a last line counts the older ones left out. A session
   bound from the board gets the same list once with its first prompt; ordinary prompts never
   carry it (UserPromptSubmit stays small). The board's **Tidy todos** asks for the same check
   mid-session, and its message carries the list itself (same cap), since the one from the start
   may be stale or compacted away. `@Claude` and `@Me` count as `@claude` / `@me`.
3. **Every ask gets one of four answers:**

   | Answer | Meaning |
   |---|---|
   | `do` | yes / here is how (note says how) |
   | `drop` | won't do, stop tracking |
   | `later` | need to ask someone else, revisit |
   | `archive` | I don't have the context to answer — park it |

   On the board the answers read **Yes** (`do`; with a note, the note is the answer), **No**
   (`drop`), **Yes, always** (`do` plus a standing grant, below), **Later** — not a resolution: the ask stays open, hidden until tomorrow (`hq ask
   snooze`, `--until` to pick the time), and the session is told you'll answer later — and **⋯ → No context** (`archive`).
   There is also **To todo**, for an ask that is really something you
   will do yourself: it becomes an `@me` todo on the task and the ask closes. Sessions are told
   to file such things as todos in the first place — an ask is only for a question they need
   answered before going on.

   Answer in chat (Claude records it with an `hq-resolved` block) or on the board. A board
   answer is typed straight into the asking session when it is live in Orca, iTerm2 or Terminal, or is a background
   session between turns ("send now"); otherwise it is delivered at the start of that session's next turn. With several
   sessions on one task, an answer reaches only the session that asked — the others are not
   told, so they don't act on it too; if the asker has ended or left the task, the next session
   on it to start a turn takes the answer over. Which session was told is recorded on the ask
   (a `delivered` event in `asks.jsonl`), so unbinding a session never makes its answer go out
   again. "Ended" is read from Claude Pet's session records; without the pet installed, an
   asker keeps its answers until it is unbound.
4. **Drafts are not done.** A message Claude drafted for you to send becomes an `@me` todo
   until you tick it.
5. **Granted steps aren't asked again.** A standing grant is a kind of step you have said yes
   to for good ("rerun with the same parameters", "fix review findings and push to the same
   PR"). SessionStart (every source) lists the task's grants in force — at most 10 and 1500
   characters — with the rule: grants are permissions, not requests to act now; while bound to
   this task, a step the session would otherwise ask about that a grant clearly covers is taken
   without an `hq-asks` and the grant named in the reply; each is read narrowly, and anything
   bigger, riskier or different is asked as usual. A session bound from the board gets the list
   with its first injection. Each session's entry in `sessions.json` keeps the grants it was
   last shown (`grants`, and `grants_task`), so a prompt only carries a line when they changed
   (`+ granted — a permission from now on, not a request to act now: …` / `- revoked — ask again
   before doing this: …`) and nothing otherwise; a grant made by an answer is stated once, with
   the answer. A SessionStart (resume, compact) first lists what was revoked since the session
   last saw the grants, since the resumed conversation still holds the old list; a session
   re-bound to another task hears that the old task's grants don't apply there. When an ask is
   about a routine, reversible kind of step that will come up again, the session may end its
   line with a suggested wording, `- Rerun #31388? [grant: rerun with the same parameters]` —
   never for deleting, sending, spending, merging or force-pushing; it is kept apart from the
   question (the ask's `grant` field) and pre-fills the board's **Yes, always** editor.

   Grants come from you only. The protocol tells sessions never to add, widen or reword one,
   and `hq grant add` and `ask resolve --grant` refuse to run inside a Claude Code session
   (`CLAUDE_CODE_SESSION_ID` set; the board's hq runs without it, a session may still revoke).
   A `state:` line that is a heading is refused, so an `hq-update` can't open a grants section
   of its own. Ways in: **Yes, always** on an ask (`hq ask resolve T-012.3 do --grant
   "<wording>"` — `--grant` needs `do`; the resolve event records `granted`, the command prints
   `{"granted", "existed"}` for the board's Undo, and the answer the session gets says the step
   is granted from now on), **＋** under the task's Grants on the
   board, or `hq grant add T-012 "<wording>" [--source T-012.3]`. A wording already granted
   (same words, ignoring case and spacing) is not added twice; a leading `[ ]` is dropped
   (a checkbox line would be a todo). `hq grant list T-012 [--json]`
   numbers them; `hq grant revoke T-012 <n | wording> [--text <wording as last seen>]` removes
   one (with `--text`, a number that now points at a different grant goes by the wording instead,
   and fails if that wording is gone) and prints it
   as JSON, which `hq grant add … --at <ts> --source <ask>` puts back unchanged. Adding and
   revoking are logged on the card. Project grants live in the project's `PROJECT.md` (same
   section and parser) and hold for every task in it: `hq grant add|list|revoke --project NAME …`
   in place of the task id. A session is given both, task grants first, then a "From project
   NAME" group.

### Grants

```markdown
## Grants                                   ← or "## 授权"; the first such section outside a code fence
- rerun release_test with the same parameters <!--g:2026-11-23T10:12:00+08:00 T-077.5-->
- fix review findings as suggested and push to the same PR <!--g:2026-11-23T11:40:00+08:00-->
```

One plain bullet per grant — not a `- [ ]` checkbox, which would read as a todo. The comment
holds when it was granted and the ask it came from (none: added by hand). Edit the section by
hand freely; the CLI and board create it before the Todo section when it is missing (`## 授权`
on a Chinese card) and remove it when the last grant is revoked.

### Todos

```markdown
- [ ] @me send the reply to Atul         ← yours: shows under "your todos" on the board
- [ ] @claude rerun on build 81599
- [ ] @Wenbing restart the qebot pod     ← waiting on someone else
- [x] done   ·   - [-] dropped
```

## Projects

A project is a line of work, not a directory: a **goal** with an end ("ship hq-v2") or a
standing **duty** ("customer RCAs"). A task belongs to one project (the card's `project` field);
its workdirs say where it is worked on, which is a separate thing — one repo can serve many
projects, and one project can span repos.

`hq.json` lists the projects — name, board order, and directories. The directories only
suggest: a task with no project gets the one of its workdir when it is created or a session is
bound (the deepest match wins). Give directories to repos that belong to one project; leave
shared repos out, and tasks started there stay in "No project" until sorted. `auto` sorts every
task that has no project by its workdirs.

What the project *is* lives in `<root>/projects/<name>/PROJECT.md` (`hq project add` writes one
from `templates/PROJECT.md`; projects without one still work):

```markdown
---
name: perf                 # the short id: cards' project:, the folder, the CLI
title: 性能基线与回归        # the display name
kind: goal                 # goal = has an end · duty = a standing responsibility
status: active             # active | paused | done | abandoned
due: 2026-12-19            # a goal's deadline
jira: ["QA-9397"]          # epics it tracks
fixVersions: ["4.2.7"]
updated: 2026-11-23
---

## Goal                    ← or 目标 / 职责范围
## Done when               ← or 完成标准 / 健康标准
## Brief                   ← or 简报: given to every session on one of its tasks
## Grants                  ← or 授权: project grants, same format as a card's
## Log                     ← or 决策记录
```

**The brief.** A session bound to a task whose project has a PROJECT.md is told, whenever it
starts (SessionStart of any source, and `hq bind` from inside it): the project, its kind, due
date and status, the first line of its goal, and the Brief section — background, conventions,
commands, pitfalls — whatever repo the session works in. The brief is capped at 2000 characters
(past that it is cut, pointing at PROJECT.md). `sessions.json` keeps a hash of what each session
was given; UserPromptSubmit gives it again only when it changed (the brief was edited, or the
task moved to another project), and says so when it is gone. HTML comments and lone
`<placeholder>` lines from the template are not passed on. `hq project brief NAME` prints
exactly what sessions get.

```
hq project list [--json]                    # with kind, status, due; "[no PROJECT.md]" if none
hq project show NAME [--json]               # the file, plus task counts: open, done, done in 7
                                            #   days, waiting on you (open asks + @me todos)
hq project brief NAME
hq project add NAME [--kind goal|duty] [--title T] [--due YYYY-MM-DD] [--path DIR]
hq project set NAME kind=duty status=paused due= title="…" jira=QA-1,QA-2 fixVersions=4.2.7
hq project paths NAME DIR…                  # replace its directories
hq project rename OLD NEW                   # every card, hq.json, and projects/OLD/ follow
hq project remove NAME --to OTHER|''        # its folder goes to projects/.removed/, not deleted
hq project auto | order NAME…
```

Goal, done-when and the brief are edited in PROJECT.md directly. `hq board --json` gives each
project its PROJECT.md fields (`defined` says whether there is one) and `stats`, and each task a
`repo`: the git repo of its first workdir, a worktree counted as its main repo.

## Categories

Each task root keeps its own category list in `hq.json` (new roots start with feature, bug,
investigation, review, ops, docs, other). Manage it from the board's **Categories** button or
`hq category add|rename|remove`. A category is just a label on each card: renaming rewrites
every card that uses it; removing one that cards use requires saying where they go
(`hq category remove X --to Y`, or `--to ''` for none), and each moved card logs the change. A
card whose category is not in the list (e.g. hand-edited) still shows, marked "not in list".

## Resources and link rules

`refs` on a card holds related tickets, PRs and docs (`hq ref add T-012 "<title> <url>"`, or just a
ticket like `QA-123`); bound sessions are asked to record a short title plus the full URL, and the
board shows the title (cut to a few words). A card lists each link once, keyed by a canonical URL
(`ref_key` / `canonical_url` in `bin/hq`; the board's `refKey` / `canonicalUrl` in `board.js` are
the same rules — keep them in step):

| URL | Canonical form |
|---|---|
| GitHub (any host containing `github`) `…/<owner>/<repo>/pull/<n>` or `issues/<n>`, plus anything after it (`/files`, `/commits/…`, `?…`, `#diff-…`) | `…/<owner>/<repo>/pull/<n>` (or `issues/<n>`) |
| GitHub, a link to one comment (`#issuecomment-<n>`, `#discussion_r<n>`, `#pullrequestreview-<n>`, `#r<n>`) | kept as written: a comment is its own entry, not merged into the PR |
| Jira `…/browse/KEY-123` with any query, fragment or trailing path | `…/browse/KEY-123` |
| Jira `…/jira/…/KEY-123`, or `…/jira/…?…selectedIssue=KEY-123` | `…/browse/KEY-123` |
| Jira, a comment (`focusedCommentId=<n>` or `#comment-<n>`) | `…/browse/KEY-123?focusedCommentId=<n>` |
| Jenkins `…/job/<a>[/job/<b>…]/<build#>/<console, testReport/…, artifact/…>` | `…/job/<a>…/<build#>` (a job URL without a build number stays as it is; on a host without `jenkins` in its name only Jenkins' own pages after the build number count, so `…/job/engineer/123/apply` is left alone) |
| anything else | as written, `#fragment` included (`#L10`, `#/runs/2`, `#Heading` point somewhere else) |

Scheme and host compare in lower case, and a trailing `/` or `).,;:` never counts. A ref with two or
more URLs, or none, is matched by its whole text (whitespace collapsed). Entries with the same key
merge into one, at the place of the first: its URL rewritten to the canonical one (an entry with
no other of its key is left exactly as written), its title that
of an entry whose URL already is the canonical one (the newest such — so a PR's title can move on
from open to merged), else the newest entry's. `hq ref add` and an `hq-update` `ref:` line merge
this way (resending the same block changes nothing), and removing one removes every entry with that
key, whichever view of it you name. The board applies the same merge when it shows a card written
before these rules. `hq ref remove` prints what it removed as JSON
(`{"removed": [{"i": 0, "ref": "…"}, …]}`), and `hq ref restore T-012 '<that JSON>'` puts every entry
back at its old place — the board's Undo after ✕ does this. The board shows them under **Links**
(Resources) in the task's right rail, grouped by source — GitHub, Jira, Confluence, Jenkins, Other —
newest first, five per group before "N more". Shorthand becomes a link through `links` rules in `hq.json`, tried in order:

```json
"links": [
  {"match": "^([\\w.-]+)#(\\d+)", "url": "https://github.com/your-org/$1/pull/$2", "kind": "pr"},
  {"match": "\\b([A-Z][A-Z0-9]+-\\d+)\\b", "url": "https://your-site.atlassian.net/browse/$1", "kind": "ticket"}
]
```

`kind` is `ticket`, `pr`, `doc` or `link`. Works for any tracker — Linear, GitHub Issues, Jira.

## Workdirs

A task's `workdirs` fill themselves: binding a session to a task adds that session's directory
(not your home folder or the task root). You can also type one when creating a task.

## Focus, All, Needs you

The board has three pages, two columns each. It opens on **Focus**: the tasks you keep in view
(`<root>/focus.json`, one list — it doesn't reset each day; a task stays until you take it off),
each with its asks, open todos and sessions, and a ⚠ line for each `hq status` flag. New tasks join automatically. `hq focus
[add|remove|order]` (`order T-3 T-1 …` sets the order, as dragging a card on the board does);
an older per-day `focus.json` carries its latest day's list over. **All** is every task and every
session; **Needs you** is every unanswered ask and your `@me` todos, counted on its tab.
The cat shows each session's task in its list, counts open asks in its badge and announces new
ones.

## Starting sessions from the board

A task's **▶ New session** starts `claude` in the task's workdir, named after the task and bound to
it from the first prompt (it reads the card, reports, and waits). It opens in a new Orca, iTerm2 or
Terminal tab, or in the background (`claude --bg`); background sessions show on the board with
Attach (`claude attach` in your terminal) and Stop.

## Leads

Copy `templates/lead.md` (scaffolded into your root) to `<root>/.claude/agents/bench-lead.md`,
describe the scope, and start it with `claude --agent bench-lead` from the root. A lead binds
to the task you name, delegates heavy work to background subagents, keeps its own context
small and reports in a fixed shape. Small tasks don't need one — the bound session is the lead.

## Files

```
<root>/
├── CLAUDE.md                 chief-of-staff rules for sessions started in the root
├── templates/TASK.md         card template used by `hq new` (edit freely)
├── templates/PROJECT.md      project template used by `hq project add`
├── projects/<name>/PROJECT.md  a project: kind, goal, brief, project grants
├── templates/lead.md         lead agent template
├── .claude/agents/           your leads
└── tasks/T-012-slug/
    ├── TASK.md               frontmatter + Goal / Status / Grants / Todo / Log
    └── asks.jsonl            append-only events: {"type":"open"|"resolve", …}
~/.claude/hq/
├── bin/hq                    the CLI and hook entry point
├── config.json               {"root": "<root>"}
└── state/sessions.json       session id → bound task, delivery cursor, turn start
```

`hq board --json` is the read API for UIs (the Claude Pet panel uses it); `hq ask resolve`,
`hq todo` and `hq set` are the write API (`hq todo T-012 2 done --text "…"` matches the todo
by its text when #2 has moved, and refuses if it is gone). Everything is plain files, so cards can also live
in git.

## Tests

```bash
hq/tests/test_hq.sh      # installs into a throwaway HOME and exercises CLI + hooks
```
