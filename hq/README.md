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
`hq project list|add|paths|rename|remove|auto`, `hq category list|add|rename|remove`, `hq ask reopen T-012.3`, `hq ask snooze T-012.3 [--until 2026-11-22T09:00]` (Later: hidden until then — tomorrow by default; `--until ""` brings it back), `hq ref add|remove T-012 <url>`, `hq peek <session-id-prefix>` (live or ended), `hq history T-012` (the task's sessions, newest first, with what resuming one needs),
`hq todo T-012 2 done`, `hq set T-012 status=blocked "next=wait for token"`, `hq log T-012 "…"`.

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
   open todo by its text (exactly, or a substring that fits only one). A block holding just
   `touch` stamps the card when nothing changed. Lines that cannot be applied are sent back to
   the session once, listed, to correct. A turn that runs longer than two minutes without
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
3. **Every ask gets one of four answers:**

   | Answer | Meaning |
   |---|---|
   | `do` | yes / here is how (note says how) |
   | `drop` | won't do, stop tracking |
   | `later` | need to ask someone else, revisit |
   | `archive` | I don't have the context to answer — park it |

   On the board the answers read **Yes** (`do`; with a note, the note is the answer), **No**
   (`drop`), **Later** — not a resolution: the ask stays open, hidden until tomorrow (`hq ask
   snooze`, `--until` to pick the time), and the session is told you'll answer later — and **⋯ → No context** (`archive`).
   There is also **To todo**, for an ask that is really something you
   will do yourself: it becomes an `@me` todo on the task and the ask closes. Sessions are told
   to file such things as todos in the first place — an ask is only for a question they need
   answered before going on.

   Answer in chat (Claude records it with an `hq-resolved` block) or on the board. A board
   answer is typed straight into the asking session when it is live in Orca or iTerm2 ("send
   now"); otherwise it is delivered at the start of that session's next turn. With several
   sessions on one task, an answer reaches only the session that asked — the others are not
   told, so they don't act on it too; if the asker has ended or left the task, the next session
   on it to start a turn takes the answer over. Which session was told is recorded on the ask
   (a `delivered` event in `asks.jsonl`), so unbinding a session never makes its answer go out
   again. "Ended" is read from Claude Pet's session records; without the pet installed, an
   asker keeps its answers until it is unbound.
4. **Drafts are not done.** A message Claude drafted for you to send becomes an `@me` todo
   until you tick it.

### Todos

```markdown
- [ ] @me send the reply to Atul         ← yours: shows under "your todos" on the board
- [ ] @claude rerun on build 81599
- [ ] @Wenbing restart the qebot pod     ← waiting on someone else
- [x] done   ·   - [-] dropped
```

## Projects

Projects are the level above tasks: `hq.json` lists them with their directories
(`hq project add claude-pet --path ~/code/claude-pet`). A task joins the project of its directory —
when it is created with a workdir, or when a session is bound — and the card's `project` field can
be changed any time. The board groups tasks by project by default (or by status, a toggle away).
`hq project list | add | paths | rename | remove --to | auto | order` manage them (the list order
is the board's order — drag a group header to change it); `auto` sorts every task
that has no project by its workdirs.

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
board shows the title (cut to a few words). The board shows them under **Resources**,
grouped by kind. Shorthand becomes a link through `links` rules in `hq.json`, tried in order:

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
each with its asks, open todos and sessions. New tasks join automatically. `hq focus
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
├── templates/lead.md         lead agent template
├── .claude/agents/           your leads
└── tasks/T-012-slug/
    ├── TASK.md               frontmatter + Goal / Status / Todo / Log
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
