# HQ — run Claude Code sessions as a team, not a pile of tabs

Once you keep a dozen Claude Code sessions open across several repos, the hard part is no
longer the work — it is remembering what each session was doing, what it asked you, and
whether you ever answered. HQ moves that state out of the conversations and into files:

| Layer | What it is | Lives |
|---|---|---|
| **Task card** | `tasks/T-012-slug/TASK.md`: goal, status, next step, todos, log | until the task is done |
| **Asks ledger** | `tasks/T-012-slug/asks.jsonl`: every question Claude put to you, until you answer it | with the task |
| **Session** | a working thread *bound* to one task; disposable | as long as you like |
| **Lead** (optional) | an agent role (`.claude/agents/*-lead.md`) that owns a kind of tasks | long-term |

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
`hq sessions --json` gives each one's `phase` (`"compacting"` while its context is being compacted, else empty) and `finished` — `{task, status, at}` once that session's own
hq-update moved its task from open to done or abandoned (the board then applies its
"Finishing a task" setting to the task's sessions; the next prompt to that session clears it), else null,
and `lastReply` — `{text, ts, prev}`, the reply its last finished turn ended on (HQ blocks stripped,
at most 6000 characters; Claude Code's `<synthetic>` stand-ins and compaction summaries skipped),
or null. Idle, it comes from the transcript; while a turn runs (`prev: true`) it is the one the
Stop hook saved for a bound session in `~/.claude/hq/state/replies/<session id>.json` (a reply of
only HQ blocks keeps the one before; files untouched for 14 days are removed).
Its `state` is the pet's, except that a turn held open only by a background command that looks
like a wait (the pet's `backgroundAgents` all `"shell"`) reads `idle` once 20 minutes have passed.
`hq peek <sid> --meta --json` also returns `items` (messages and one-line tool calls in order —
`{kind:"tool", id, name, title, label, stat, status: ok|error|pending|background|stopped, ts, endTs}`;
a slash command you ran is a user message with `command: true` and the command as typed as its text,
`/compact` placed before the compaction it ran),
and events: `{kind:"event", event:"compact", trigger: manual|auto, pre, post, ts}` for a compaction,
`{kind:"event", event:"hook", hook, text, ts}` for a hook that sent Claude's reply back),
`turn` (`start`, `done`, `ms`, output `tokens`, `context` — after a compaction with no reply
since, its `compact_boundary`'s `postTokens` plus what a request sent besides the conversation
after the previous compaction, else the session's first reply, at most 60k) and `todos` (Claude's latest
TodoWrite / TaskCreate list: `{text, status, active}`) and `queued` (messages waiting in Claude
Code's queue — sent while it was busy, not taken in yet — from the transcript's
`queue-operation` lines, matched by text: an entry leaves when a `remove` or a later user entry
holds it, or once a turn has ended and another prompt began; `[{text, ts}]`, oldest first, task
notifications left out); `hq peek <sid> --tool <tool_use id>`
prints one call's full input and output (an Edit's diff), `--json` for the fields.
`hq peek <sid> --commands [--json]` lists the skills the session can run as slash commands —
the newest `skill_listing` Claude Code wrote into the transcript plus skills added after it,
then the skills and commands marked `disable-model-invocation: true` (left out of that listing,
but still yours to type) from `~/.claude`, the session folder's `.claude` and those above it (up
to your home), and the plugins enabled for that folder — user settings, then the project's
`settings.json` and `settings.local.json`; a project-scope install counts only in its project —
as `plugin:name`. A file or settings it can't read is skipped;
`--json` gives `{found, skills: [{name, desc}]}` (the board's message boxes complete `/` from it).

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
none was found; `board` when the click opened the session's task on the board instead — Settings →
"Clicking a Session Opens". Those are not jumps to a terminal: `hq jumps` leaves them out of the
counts and reports them as `boardOpens`).

Re-run `hq/install.sh` to upgrade. `hq/uninstall.sh` removes hooks, commands and CLI and
leaves your cards alone.

## Start from the sessions you already have

```bash
hq scan                                   # read-only: recent sessions, grouped by repository
```

Then run `/hq-onboard` in any Claude Code session (an empty board offers to copy it). Claude reads
your recent sessions, drafts a task per piece of work and groups the tasks into lines of work —
existing projects, or new duties and goals, which are not the same as repositories — shows you
everything and creates nothing until you confirm. Then it writes the whole plan as one JSON file
and runs `hq import`:

```bash
hq import plan.json --dry-run   # check the whole plan, print what it would create
hq import plan.json             # create it all: refused whole, problems listed, if any part is wrong
```

```json
{"projects": [{"name": "perf", "kind": "duty", "title": "Performance testing", "goal": "…", "paths": ["/abs/dir"]},
              {"name": "perf-427", "kind": "goal", "title": "Rebaseline 4.2.7", "parent": "perf", "due": "2026-12-31"}],
 "tasks": [{"title": "Rebaseline LDBC", "project": "perf-427", "status": "waiting-on-me", "next": "…",
            "state": ["…"], "todos": ["@me …"], "refs": ["PR #12 https://…"], "workdirs": ["/abs/dir"],
            "sessions": ["<session id or 8+ char prefix>"], "confidence": "medium"}]}
```

`projects` holds only new ones (also `done_when` — a list of criteria — and `brief`); every todo
starts with its owner (`@me`, `@claude` or `@<name>`: one with none would show in nobody's list, so
it is refused); a task names an
existing project directly (also `goal`, `log`), or with none gets the one whose directory holds its workdir. Live sessions are bound to their tasks, ended ones recorded on the
cards; a session already on a task, a taken name or an open card with the same title is refused.
`hq scan --apply-projects [--only a,b]` still makes one project per repository, without a kind —
kept for scripts; onboarding doesn't use it.

## Daily use

The full user guide (both languages) is built into the board: open it with **Guide** in the
board's top bar. Its source is `Resources/pet/board/guide.html`.


```text
/board                    in any session: open asks, your @me todos, every open task
/task T-012               bind this session to T-012 and pick up from its card
/task Rerun perf baseline create a new card and bind to it
```

Or from a shell: `hq board`, `hq show T-012`, `hq asks`, `hq ask resolve T-012.3 drop`,
`hq project list|show|brief|add|set|paths|rename|remove|auto|order` (see Projects), `hq ask reopen T-012.3`, `hq ask snooze T-012.3 [--until 2026-11-22T09:00] [--note WHY]` (Later: hidden until then — tomorrow by default; `--until ""` brings it back; `hq ask resolve T-012.3 later [until DATE]` is the same), `hq ref add|pin|remove|restore T-012 <url>`, `hq continue T-012 [--title TITLE] [--json]` (Card budget, below), `hq workdir add|remove T-012 <folder>` (the task's workdirs; New session starts in the first; `remove` prints `{"removed": [{i, path}]}` and `hq workdir restore T-012 '<that JSON>'` puts them back at the same place), `hq peek <session-id-prefix> [--meta] [--tool ID] [--commands]` (live or ended), `hq history T-012` (the task's sessions, newest first, with what resuming one needs),
`hq todo T-012 2 done`, `hq set T-012 status=blocked "next=wait for token"` (`status=` also takes the board's column names: `ready` = active, `needs-you` = waiting-on-me), `hq log T-012 "…"`, `hq garden` (Tidying the board, under Secretary), `hq doctor [--fix]` (Checking HQ itself, below).

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
| `idle-waiting` | an open task's next/state says it waits on a run (a wait word — wait on, watching, once … finishes, 等, 盯, 跑完后 … — and a machine word — build, job, CI, test, #12345, 构建, 跑 …), but nothing is working on it, waiting on you or running in the background, for 30 min. A background call counts from its launch to its end (its notification, a TaskStop, or the kill Claude Code records when it exits) wherever those are in the transcript, not only in the tail `status` reads otherwise |
| `stale` | open and not updated for 7 days (`hq board --json` carries the days as each task's `stale`, 0 otherwise; the board tags such a card "Nd untouched") |
| `done-live` | done or abandoned with a session still running |
| `over-budget` | the card is over 16 KB, 30 links or 30 todos |

A task's sessions are the ones bound to it and the ones its card lists, less any since bound to
another task. The board shows the Focus tasks' flags as ⚠ lines on their cards (`hq status
--focus --json`, read about once a minute); done tasks leave Focus, so `done-live` shows only here.

### What a bound session does differently

The hooks inject a short protocol into the session (see `protocol()` in `hqlib/protocol.py`):

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
   change: merge #12 => merge #12 and #13
   log: picked plan v2 because it is cheaper
   ref: PR #9 https://github.com/org/repo/pull/9
   workdir: /abs/path/it/started/working/in
   ```
   ````

   Only the lines that changed. `todo` / `done` / `drop` / `log` / `ref` / `workdir` may
   repeat; `state` lines replace the card's Status (当前状态) section; `done` / `drop` match an
   open todo by its text (exactly — a todo already ticked is then a no-op — or else a substring
   that fits only one open todo). `change: <open todo's text> => <new text>` rewrites an open
   todo in place — same line, same owner unless the new text names one, same creation stamp — and
   logs `todo #N → changed (session): old ⇒ new` to HISTORY.md (reports skip that line). A todo's
   own text may hold an arrow: the split whose old part is an open todo wins. A change already
   made (the old text no longer open, the new one on the card — open or closed since — or in
   HISTORY.md), or one that changes nothing, is a no-op; a change into another open todo's text,
   to the template's placeholder, or of a todo also ticked in the block is refused.
   A `todo: @me …` from a session that repeats an open `@me` todo refuses the block, naming the
   open one: both about installing from main (`install`/`安装`/`重装` with `main` or `install.sh`),
   both about reviewing or merging (the autoclose PR verbs) a `#N` / PR link they share, or the
   same `#N` / `ABC-12` names and text at least 80% alike (character-pair Dice). Different PRs
   with the same words are not repeats. `todo!:` adds it anyway; the same text again is skipped
   as before; todos closed or changed in the same block don't count; `@claude` and other owners,
   the board and `hq addtodo` are not checked. A `ref:` to one build, run or comment (a process link) goes to
   the task's HISTORY.md, not the card; `ref!:` keeps it on the card. `project: NAME` moves the task to an existing project — a
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

   **The turn's echo.** The Stop hook also shows the user one line (a `systemMessage`, which
   the session does not see) of what the turn's blocks did: the status change (including the
   automatic ones), which fields and how many todos, logs and refs were actually written (a
   repeat counts nothing), new asks by id, answers recorded — and what was refused or dropped,
   with the first reason and whether the session was sent back or hears at its next prompt;
   also the write-back guard. A renamed ref counts as updated, not added; the log line a
   `project:` move adds itself is not counted. A reply with no hq block at its end (examples
   mid-reply don't count) and nothing wrong prints nothing; a trailing block that changes
   nothing — `touch`, a repeat, template placeholders — says "nothing new on the card". The
   words follow the project's language (`lang` from PROJECT.md headings); a task with no project
   uses its card's headings. The echo never raises: it can't cost the turn its `decision`. E.g.
   `HQ T-012: status active → waiting-on-me, next, +1 todo, ask T-012.5`.
2. **Questions to you are tracked.** When Claude needs a decision, a confirmation or an
   action from you, it ends its reply with a block:

   ````markdown
   ```hq-asks
   - Approve plan v2 (Neo4j first, graph500 scale 22/24/26)?
   - Ask Chengjie which dataset the prospect used
   ```
   ````

   The Stop hook files each item as an ask (`T-012.3`, `T-012.4`, …). With list items in the
   block, only a line starting at column 0 with `- `, `* ` or `1.` starts a new ask; every other
   line (options `a)` `b)` under a question, an indented second line) joins the one above. A
   block with no list items is one ask a line. Reading the ledger, picking the next id and
   appending hold the card's lock, so Stop hooks of several sessions asking at once never share
   an id. Unanswered asks are
   re-injected every turn and shown on the board until you respond — an ask you skipped is
   never treated as "no".

   **Status follows the asks, between `active` and `waiting-on-me`.** A reply that opens a
   new ask without a `status:` line puts an `active` task at `waiting-on-me` (so does taking back
   an answer, or the tick of an `@me` todo, with Undo). Once nothing is left on you — no open ask
   (a snoozed one is still open), no open `@me` todo and no legacy `waiting_on_me` — answering an
   ask (board, `hq ask resolve`, an `hq-resolved` block) or ticking off / dropping an `@me` todo
   (board, `hq todo`, `done:` / `drop:`) puts a `waiting-on-me` task back to `active`; other todos
   don't. A status written in the same reply (and applied) wins, and a reply's blocks are
   weighed together, so one that ticks the last `@me` todo and asks again just stays waiting.
   A session's new ask (no `status:` written) also moves a `blocked` task to `waiting-on-me`; a
   new `@me` todo doesn't — the session rules ask for `status: blocked` when all that is left
   waits on someone else, `@me` todos for afterwards included (the board's Blocked lane takes such
   a task, asks and todos and all). `done` and `abandoned` are never changed automatically, and
   `blocked` only by a new ask. Each move is logged on the card with `(auto, <via>)`.

   **A reply can't close its task over an open question.** When a session's `hq-update` says
   `status: done` (or `abandoned`) on an open task that still has an open ask — often a last one
   asked in that same reply ("delete the old worktrees?") — the close is held: the task goes to
   `waiting-on-me`, the card gets `closing: done`, and the session's entry in `sessions.json` a
   `held` mark (`{task, status, at, seq}`). Closing at once would have the board stop the session (its
   "Finishing a task" setting) and the answer would reach no one. Only that session releases it,
   at the end of a turn with no ask open that began with every answer given since the hold in
   hand — answered in its own reply, or delivered to it (`delivered`) before the turn started;
   a No (`drop` / `archive`) needs nothing done. Releasing marks the session finished, as a close
   in the reply itself would. A turn on something else, or another session on the task, never
   releases it. A No given on the board or with `hq ask resolve` closes it at once when the
   holding session isn't running and no Yes since is still waiting for it. A task already done or
   abandoned is never reopened to hold a close. A status written outright — another `hq-update`
   status, `hq set`, the board — drops `closing`.

   **The card's open todos come along at session start.** SessionStart — for every source:
   `startup`, `resume`, `clear` and `compact` — appends the card's open `@me` todos (to tick one
   seen done, or `change:` it rather than add a near-copy) and then its open `@claude` todos to the
   context, each exactly as written on the card (each list capped as below); for the `@claude` ones with the instruction to check them against how
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
   | `later` | not now — the ask stays open, hidden until tomorrow (`later until 2026-12-05`: until then) |
   | `archive` | I don't have the context to answer — park it |

   On the board an ask is answered in words: what you write in its box is the answer (`do`, the
   note), and sending it empty is Yes, as suggested (`do`, no note). **✕ No** is `drop`; behind
   **⋯** are **Later** — not a resolution: the ask stays open, hidden until tomorrow (`hq ask
   snooze`, `--until` to pick the time), and the session is told you'll answer later — and **No context** (`archive`).
   There is also **⋯ → To todo**, for an ask that is really something you
   will do yourself: it becomes an `@me` todo on the task and the ask closes. Sessions are told
   to file such things as todos in the first place — an ask is only for a question they need
   answered before going on.

   `later` is the board's **Later** under another name, not a resolution: from the chat
   (`- T-012.3 later: Ping is out` or `- T-012.3 later until 2026-12-05: …` in `hq-resolved`) or
   `hq ask resolve T-012.3 later [until DATE] [note]`, it writes a `snooze` event (with the note,
   shown under the question and to the session), so the question comes back instead of being
   closed for good. `until` takes a date or a time (`2026-12-05`, `2026-12-05 09:00`, with or
   without an offset); on any other answer, or with no date after it, "until …" is just the note.
   Only an open ask can be put off, and being still open, it keeps a close held for questions
   held — closing over a question needs `drop` or `archive`. Asks closed as `later` before this
   stay closed.

   An `hq-resolved` block is one answer a line (an indented line without an ask id continues the
   note above). A line that can't be read, names no ask, answers or puts off an answered one, or
   writes `later until` with no date is not dropped: the Stop hook sends those lines back to the
   session (the rest are recorded). So is a reply whose only `hq-update` block has text after it —
   taken for an example, it would otherwise be skipped without a word.

   Only the board changes an answer in place (`--via board`): a second answer from a session —
   often its retelling of a board answer — would replace the user's own words, so it goes back,
   and `hq ask resolve` on an answered ask fails and says to `hq ask reopen` it first (as the
   board's Undo does). An ask continued to another card, once or several times, is answered (and
   checked) where it is now.

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

HQ no longer has standing grants ("Yes, always" on an ask, `hq grant`). What they left behind is
tolerated: an ask a session still ends with `[grant: …]` (or `[授权：…]`) is recorded without it, and
an old `## Grants` / `## 授权` section on a card or in `PROJECT.md` is left as it is and not read
(in `PROJECT.md` its heading still ends the section above it). A `state:` line that is a heading
is refused, so an `hq-update` can't open a section of its own.

### Todos

```markdown
- [ ] @me send the reply to Atul         ← yours: shows under "your todos" on the board
- [ ] @claude rerun on build 81599
- [ ] @Wenbing restart the qebot pod     ← waiting on someone else
- [x] done   ·   - [-] dropped
```

### Card budget: HISTORY.md and `hq continue`

Every session that starts on a task reads its card, so the card keeps what is in use now and the
rest moves to `HISTORY.md` beside it on every write (`enforce_budget`; nothing is deleted):

- closed todos past the 5 most recently closed (`CARD_KEEP_CLOSED`; when a todo closed comes from
  its tick record);
- todo ticks (`todo #3 → done (board): …`), written straight to history;
- log entries past the newest 20 (`CARD_KEEP_LOG`);
- process links (`process_ref`): one Jenkins build, one GitHub Actions run, a comment on a GitHub
  PR / issue or a Jira issue, or a URL matching a regex in `hq.json`'s `"process_links": […]`
  (searched in the full URL). A ref starting with `! ` (the key mark) is a key link whatever it
  points at: `hq ref pin T-012 <url>` and an `hq-update` `ref!:` line write it that way, and the
  board's Add pins. The board's `processRef` is the same test — keep them in step.

```markdown
# T-012 — history

<!-- What no longer fits on TASK.md (the card budget): … Oldest first. -->

## Links
- Build 41 https://jenkins.example.com/job/x/41/

## Todos
- [x] @claude rerun on build 81599 <!--t:2026-11-20T10:00:00+08:00-->

## Log
- 2026-11-20 10:31:02: todo #2 → done (board): rerun on build 81599
```

`hq board --json` gives each task `history` (`log`, `links`, `todos` as parsed todos) and
`historyInfo` (counts and path); the board merges them back in — log by time, history todos
read-only among the finished ones, process links folded in a last **Process** group with ↑ (pin).
A closed todo (on the card or in HISTORY.md) also carries `closed`: when its latest done/drop tick
was logged (null when it was closed by editing the card); the board lists the latest closed first.
A starting session gets one line saying how much history there is and where. `hq ref remove`
removes the link from HISTORY.md too and prints `{"removed": […], "history": […]}` ("history" only
when any went from there); `hq ref restore` puts both back. Over 16 KB, 30 links or 30 todos is
still flagged `card over budget` by `hq status`.

`hq continue T-012 [--title TITLE] [--json]` carries an open task on in a fresh card: the title's
date (`2026-11-20`, `2026/11/20`, `Nov 20[, 2026]`, `2026 Nov 20`, `[2026年]11月20日`) becomes today's,
else ` (cont. MM-DD)` is appended (`（续 MM-DD）` for a title with CJK). Goal, Status, the open todos
as written (an open sub-todo of a closed one comes unindented; checklists in Goal/Status are not
copied twice), refs, next, a non-active status, project, lead and workdirs come along; both logs point at
the other; the old card becomes `done` with `next: continued in T-new` and its Focus place goes to
the new card. Sessions bound to the old card are rebound (their next prompt says so). Open asks
move to the new card under new ids: the new card's `asks.jsonl` gets an `open` event with
`moved_from`, the old one a `{"type": "move", "id", "to"}` event, and the old ask reads as state
`moved`; `hq ask resolve` on an old id resolves the new one. `--json` prints `{"from", "to", "path",
"title", "todos", "sessions", "asks"}`, `asks` being `[{"from": "T-012.3", "to": "T-031.1"}, …]`. The
board's **Continue today** button runs it.

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

On the board all of this is on Projects & duties: ＋ New project / ＋ New duty (with an optional
default directory), drag a card to reorder, and on a project's page rename it (Details → Name),
add or remove its default directories and delete it (its tasks move to another project or none
first); the list has Assign by directory (`auto`).

What the project *is* lives in `<root>/projects/<name>/PROJECT.md` (`hq project add` writes one
from `templates/PROJECT.md`; projects without one still work):

```markdown
---
name: perf                 # the short id: cards' project:, the folder, the CLI
title: 性能基线与回归        # the display name
kind: goal                 # goal = has an end · duty = a standing responsibility
status: active             # active | paused | done | abandoned (a duty: active | paused)
due: 2026-12-19            # a goal's deadline
parent: qa-oncall          # a goal can sit under a duty (only a goal, only under a duty)
phases: ["Design", "Build", "Ship"]   # a goal's phases, in order; a card's `phase:` picks one
auto: ["github-review"]    # a duty's switches for work that comes in by itself:
                           #   qahub-ci | github-review | jira-filter (github-review makes
                           #   tasks, set up in Auto intake; the others make nothing yet,
                           #   and the board doesn't show them)
jira: ["QA-9397"]          # epics it tracks
fixVersions: ["4.2.7"]
updated: 2026-11-23
---

## Goal                    ← or 目标 / 职责范围
## Out of scope            ← or 不管: what it leaves to others
## Done when               ← or 完成标准; a duty's is "Healthy when" / 健康标准. One `- ` line
                           #   per criterion, `- [x] ` once it holds (the board ticks them)
## Templates               ← or 常见的活: a duty's kinds of recurring work, see below
## Auto intake             ← or 自动来活: how a duty's sources make tasks, see "Work that comes in by itself"
## Brief                   ← or 简报: given to every session on one of its tasks
## Log                     ← or 决策记录
```

Headings are read in either language, or both (`## 目标 / Goal`). A section runs to the next
Goal / Out of scope / Done when / Templates / Auto intake / Brief / Log heading (or an old Grants one), so other `##` headings (a brief's own
`## Commands`) stay inside it — and inside a Brief, so do Out of scope, Templates and Auto intake headings
(sections that came after briefs: a brief's own `## Templates` is not cut off). A second heading
of a section (a Scope after a Goal) reads as more of it, and the next write of that section folds
it into the first. Older files' `不管：…` / `Out of scope: …` lines in the goal read as the
out-of-scope section, and move there on the next section write. A log line written to a file
whose last section isn't its Log (`hq project check`, a rename) gets a Log heading first. Two projects whose names differ only in case are refused: on
macOS they would be one folder.

**The brief.** A session bound to a task whose project has a non-empty Brief is told, whenever
it starts (SessionStart of any source, and `hq bind` from inside it): the project, its kind, due
date and status, the first line of its goal, and the Brief — background, conventions, commands,
pitfalls — whatever repo the session works in. The brief is capped at 2000 characters (past that
it is cut, pointing at PROJECT.md). `sessions.json` keeps a hash of what each session was given;
UserPromptSubmit gives it again only when it changed (any of those parts was edited, or the task
moved to another project), and says so when it is gone (emptied, the file removed, or the task
moved to a project without one). HTML comments and lone `<placeholder>` lines from the template
are not passed on. `hq project brief NAME` prints exactly what sessions get.

With the brief comes the user's **Preferences**: the `## Preferences` (or `## 偏好`) section of
`<root>/secretary/profile.md`, HTML comments left out, capped at 1500 characters. It is told the
same way and in the same text, so editing it is announced once to every bound session at its next
prompt. The secretary's own session isn't told it (it reads the whole profile). The secretary
proposes the rules from the user's answers (Reports, below). A PROJECT.md that
can't be read is treated as missing, and a hook never fails a turn: an error goes to stderr.

```
hq project list [--json]                    # open / done / on-you counts, kind, status, due;
                                            #   "[no PROJECT.md]" if none
hq project show NAME [--json]               # the file, plus task counts: open, done, done in 7
                                            #   days, waiting on you (open asks + @me todos)
hq project brief NAME
hq project add NAME [--kind goal|duty] [--title T] [--due YYYY-MM-DD] [--parent DUTY] [--path DIR]
hq project set NAME kind=duty status=paused due= title="…" jira=QA-1,QA-2 fixVersions=4.2.7
                    parent=DUTY phases=Design,Build auto=github-review
hq project section NAME goal|out|done_when|templates|intake|brief [TEXT]   # no TEXT: stdin; a missing
                                            #   section is made, in the file's language
hq project check NAME N [done|open]         # tick criterion N (1-based) of done-when; logged
hq project paths NAME DIR…                  # replace its directories
hq project rename OLD NEW                   # every card, hq.json, and projects/OLD/ follow
hq project remove NAME --to OTHER|''        # its folder goes to projects/.removed/, not deleted
hq project auto | order NAME…
```

Sections can be edited in PROJECT.md directly, with `hq project section`, or with ✎ on the
project's page on the board. Only a goal sits under a duty; a duty with goals under it can't
become a goal, and renaming or removing a duty moves its goals along (or frees them).

**Templates** ("common work") are a duty's kinds of task that come up again and again:

```markdown
## Templates
### triage
title: Triage {date}       # {date} / {日期} and {week} / {周} are filled in
goal: Go through today's failures
- [ ] @claude list the new failures
```

`hq new --project NAME --template triage` makes a task from one: its title (unless one is
given), goal and todos. A recurring job on the Scheduled page runs that command on a timetable
(the board's "Recurring" box on a duty's page writes it). `hq new` also takes `--goal` (the
card's Goal), `--phase` (the card's `phase:`; `hq set ID phase=…` changes it) and `--no-focus`.

`hq board --json` gives each project its PROJECT.md fields (`defined` says whether there is
one; also `parent`, `phases`, `auto`, `out`, `criteria` [{i, text, done}], `templates`
[{name, title, goal, todos}], `intake` ({source: {repos, workdir, run, permissions, done, focus,
title, goal, prompt, problems}}), `lang` (zh when its headings are Chinese) and `raw`, each section's text as written, comments and all — empty
for one holding only the template's hints) and `stats`, and each task a
`repo`: the git repo of its first workdir that still exists (else its first), a worktree counted
as its main repo (through the worktree's `commondir`, so bare repos too). `done_7d` goes by the
card's `closed` date — written when a task becomes done or abandoned — not `updated`, which any
later log line moves. Closing a task also writes `closed_at`, the moment, to the
second. Each task also has `lastActive`: the later of its newest timed log line (card or
HISTORY.md; date-only lines don't count) and `closed_at` (`closed` on older cards), else
`updated` — what a project page's Finished list orders by, newest first, then by id.

## Categories (retired)

Projects and duties group tasks now. New cards get no `category:` line, the board neither shows
nor edits one, and the quick-note sorter doesn't pick one. A `category:` already on a card stays
as it is; `hq continue` carries it over.

## Resources and link rules

`refs` on a card holds related tickets, PRs and docs (`hq ref add T-012 "<title> <url>"`, or just a
ticket like `QA-123`); bound sessions are asked to record a short title plus the full URL, and the
board shows the title (cut to a few words). A card lists each link once, keyed by a canonical URL
(`ref_key` / `canonical_url` in `hqlib/refs.py`; the board's `refKey` / `canonicalUrl` in `board.js` are
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

## Focus, Projects & duties, Needs you

The board has three task pages. It opens on **Focus**: the tasks you keep in view
(`<root>/focus.json`, one list — it doesn't reset each day; a task stays until you take it off),
each with its asks, open todos and sessions, and a ⚠ line for each `hq status` flag. New tasks join automatically. `hq focus
[add|remove|order]` (`order T-3 T-1 …` sets the order, as dragging a card on the board does);
an older per-day `focus.json` carries its latest day's list over. **Projects & duties** is every
project and duty: a card each naming the tasks waiting on you and the ones running, and a page
each with its lanes, PROJECT.md sections, criteria, phases, templates and recurring jobs (the
guide has the details); while the board's filter is on, it lists every matching task, closed
ones too. **Needs you** is every unanswered ask and your `@me` todos, counted on its tab.
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

## Secretary

The secretary is a standing agent for the whole board. It answers "how are T-072 and T-071 doing,
what is blocking them", marks what waits on the user, and proposes changes to the board without
making them itself. `hq secretary init [--lang en|zh]` scaffolds whatever is missing and never
overwrites what the user wrote:

- `<root>/.claude/agents/secretary.md`: who it is, its boundaries, and which `hq` command
  answers which question;
- `<root>/secretary/profile.md`, `people.md` and `playbooks.md`: its memory, which the user can
  edit and which it changes only after a yes. `profile.md` holds the user's language, role,
  Preferences (how they decide, one rule a line: every bound session is told them, see The brief)
  and routine; where the work stands is not kept there, the secretary reads the board;
- `<root>/secretary/reports.md`: how its daily and weekly reports are written — the weekly
  report's reader, language and other files to read first ("Weekly: who reads it"), then the
  format — ending in the rules it learned from the user's edits;
- its own task card, "Secretary" (lead `secretary`, kept off Focus). The card's id is recorded
  as `"secretary": {"task": "T-…"}` in `hq.json`, and `hq board --json` reports it as
  `"secretary"`.

The agent definition tells it to talk like a colleague in a chat: the answer first, in a few plain
sentences, lists only for truly separate items, no narrated steps, and for a report only the gist
(the window links the file). The board's window shows only each turn's last reply, so that is all
the user reads. Two fenced blocks are drawn by the board rather than shown as code, and the agent
uses them: ` ```diff ` (a unified diff with `--- a/<path>` / `+++ b/<path>` and `@@` hunks, drawn
like a GitHub file diff — how it shows a change to its memory before asking) and ` ```draft `
(`to:`, `via:`, `subject:`, `cc:` lines, a blank line, the message; drawn with a Copy button). It
never writes HTML: the board shows any as text.

`init` also replaces an agent definition that is still exactly an older shipped version (matched
by its sha256), so existing setups pick up new instructions; one the user edited is kept.

`hq secretary [--json]` reports what is there (`agentStale` when the agent is an old shipped
version, `reports`: the newest four reports). Its `--json` also lists the sessions bound to the
card (`sessions`) and the card's state lines (`state`: what the secretary is keeping an eye on).
The board leaves the card out of Focus, Projects & duties and the counts, shows its asks in Needs you and in
the secretary's window, and shows `state` at the top of that window.

Claude Pet runs it from the board's **Secretary** button. The button opens a scheduled job,
`~/.claude/pet/jobs/secretary/`, and runs it once per message:

- the job runs `claude -p --agent secretary` in the root, always in the same session, with its
  compaction (at the job's percentage of the window or 150k tokens, whichever comes first) and
  quota guard;
- the session is bound to the secretary's card before its first run, so its `hq-asks` become
  that card's asks in Needs you;
- a **Yes** to one of those asks on the board starts a run, and the hook hands the session the
  answer at the start of that run.

The job is made with the weekly report prompt and a Friday 17:00 schedule, but off; the window's
**Weekly report** switch enables it. The prompt names the steps (`hq report weekly`, write,
`hq report keep`, propose what the week's answers teach) itself, for an agent definition the user
edited. A job made earlier that is off and still has the old placeholder prompt, or that writes
the old daily report, gets the weekly prompt; its schedule moves to Fridays (the default
placeholder or every N minutes: 17:00; a daily or weekday time the user chose: that time on
Fridays; a cron or weekly one stays). One with a prompt of the user's own shows as such in the
window; turning reports on there replaces the prompt and moves the schedule the same way. A scheduled run that finds the session busy (the user is chatting) waits
up to 10 minutes for the lock instead of being skipped.

Unattended, the job is allowed only Read, Grep, Glob, `Bash(~/.claude/hq/bin/hq:*)` and Edit or
Write under `<root>/secretary/`.

### Tidying the board: `hq garden`

`hq garden [--json]` lists what a weekly look over the board would tidy, without a model:

| kind | when |
|---|---|
| `zombie` | open, `stale` in `hq status` (not updated for 7 days), and no session active for 7 days either |
| `done-live` | done or abandoned with a session still running |
| `over-budget` | the card is over budget (as `hq status` flags it) |
| duplicate pair | two tasks, open or closed in the last 14 days (at least one open), whose title words overlap (Jaccard, or 0.8 × the share of the shorter title of 3+ words; 2+ words in common) or title-and-goal words do (3+ in common), scoring ≥ 0.5 — or that share a key link or a ticket key (a ref starting with one). Pairs sharing a link first; a pair where one card names the other (`mention`: often a part or a follow-up) last; an old card and the one `hq continue` made from it are left out. At most 8 |

Each finding carries the secretary's asks that name its task (`asked`) and `settled`: why it isn't
to be proposed again, when an ask about it is still open, or the last answer was No and the card
hasn't been written since. The secretary's card is left out. `--json` gives `{now, secretary,
findings: [{kind, task, …, asked, settled}], duplicates: [{tasks, titles, statuses, goals, score,
sharedLinks, words, mention, asked, settled}]}`.

`hq report weekly` (Fridays, so the evening report's scheduled run) includes it as `garden` and ends
its text with a "Tidying the board" section; the secretary proposes the cleanups worth doing as
asks on its card (at most five a week) and carries out a Yes with `hq set`, `hq continue`,
`hq addtodo` …

### Reports

`hq report [auto|daily|weekly] [--since T] [--no-gh] [--json]` prints the facts the secretary writes
a report from. `auto` (the default) is `weekly` on Fridays and `daily` otherwise. The window starts
at Monday 00:00 for a weekly report; for a daily one, where the facts of the last kept report of
the past 7 days ended (its `to`), else today 00:00; `--since` overrides both. A report being
written again the same day doesn't count as the last one. Per project, for every task that moved: Log entries,
todos ticked, dropped and added, asks answered and asked, PRs on its refs (merged in the window or
still open, looked up with `gh pr view` unless `--no-gh`); then the tasks that didn't move, what is
owed (`@me` todos and unsnoozed open asks at least 2 days old), and the user's edits to recent
reports as unified diffs, today's own included (`"exists": true` when today's file is there: a
rewrite must keep the user's changes). A card closed on the window's first day counts as closed
in the window unless the report the window starts at already listed it (`closed` dates have no
time). Cards whose only news is new `@claude` todos count as quiet. Cards closed in the last week
are kept only when one of their PRs merged in the window. The secretary's own card is left out. A
weekly report also carries `garden` (Tidying the board) and `learn`: the window's answered asks
where the user said no or wrote a note of 10 characters or more (at most 20, oldest first), from
which the secretary proposes Preferences. It also names the file to write,
`secretary/reports/<date>-<daily|weekly>.md`, and creates `secretary/reports.md` from the template
when it is missing.

Each gather notes its window and the cards it saw closed in `secretary/reports/.pending.json`.
`hq report keep FILE` snapshots a written report to `secretary/reports/.drafts/FILE` and records
it in `secretary/reports/.reports.json` (`kept`, plus the last gather's `from`, `to` and `closed`); the next `hq report` diffs each recent report against its
snapshot. Keeping a report re-snapshots the others, so each edit is shown once. `hq report list
[--json]` lists the reports.

## Quick notes (inbox)

A line, a link or a screenshot jotted without stopping to file it. `hq inbox add TEXT
[--image PATH …] [--sort]` stores it as `N-001`, `N-002` … in `<root>/inbox.json`; `hq inbox sort
N-001` asks a cheap model where it belongs and files it there:

- `task`: a new card (title, goal, and its project when the model is sure). Its workdir is
  a path the note names, else the closest task's or project's folder (the sorter sees them in
  full), else the folder the project's tasks use most — so New session can start on it;
- `todo`: a todo on an open task, `@me`, `@claude` or a colleague;
- `note`: a log line on an open task (or one closed in the last 14 days);
- `update`: the note moves an open task on — a log line as for `note`, plus any of its `next`,
  its status section (`state`), its `status`, and the open todos it finishes (`done`, named
  `@owner text`; the sorter sees each open task's open todos). Ticking the last `@me` todo settles
  a waiting-on-me task. A close (`done` / `abandoned`) is never applied by the sorter: it becomes
  an alternative, one click away; so does each candidate when a todo matches more than one;
- `me`: an `@me` todo on the secretary's card (only once the secretary is set up).

Links in the note go to the task's refs. The sorter is one `claude -p --model haiku` run with
`--json-schema`, no settings, no MCP and no tools (Read only when there are images); it sees the
open tasks (with their open todos), projects and the secretary's memory. A pick with confidence
≥ 0.7 is applied at once; anything else stays `unsorted` with the guess and up to four
alternatives kept for a one-click choice. Feed notes (Zulip, Jira) never get `update`. Change the model with `"inbox": {"model": "sonnet"}` in `hq.json` or
`HQ_INBOX_MODEL`.

`hq inbox move N-001 task|todo|note|update|me|unsorted [--task T-012] [--owner …] [--text …] [--title …]
[--project …] [--workdir …] [--next …] [--state …] [--status …] [--done TODO …]` files it
somewhere else: what the last place got (its todo, log line and refs; a card it created, deleted —
or marked abandoned if edited since; an update's next, status section, status, `closed` date and
ticks, each put back unless changed since) is taken back out first, and the old place becomes an
alternative. Moving to `task` with no `--title`, when no guess has one either, has the cheap model
write a short title (the note itself goes into the goal; with no model to ask, its first line is
the title; a note that is only a screenshot is "Quick note N-001", or 快速记录 for a Chinese
secretary). Moving to `update` with none of `--next/--state/--status/--done` takes the changes
from the model's update guess for that task; one that would change nothing is refused. `hq inbox drop|restore N-001`
deletes an unsorted note or brings it back. `hq inbox [--all] [--json]` lists the unsorted notes and
those sorted in the last 48 hours; `hq board --json` carries the same list as `inbox`.

The board's **Quick note** box and Claude Pet's ⌃⌥⌘N panel both run `add` then `sort`; Needs you
shows the list.

### Feeds: Zulip, Jira

`hq feed zulip [--since HOURS] [--no-sort] [--dry-run] [--json]` reads the direct messages that came
in since the last scan — and the @-mentions too when `hq.json` has `"feed": {"zulip": {"mentions":
true}}` (off by default: bots and channel-wide notices mention you often) — and turns each conversation — one stream topic, or one set of DM recipients — into a quick note
with `via: "zulip"`, `conv` and `msgs` (the message ids). Read only: nothing is ever sent. It calls
Zulip's REST API directly with the account in `$HQ_ZULIPRC`, else `"feed": {"zulip": {"zuliprc":
PATH}}` in `hq.json`, else `~/.zuliprc`; the key is never written anywhere else, and an error about
the file never quotes it. Messages from bot accounts (Zulip's `is_bot`, looked up per sender with
`GET /users/{id}`; a sender the realm can't look up counts as a system bot) are left out unless
`"feed": {"zulip": {"bots": true}}`. A conversation where only you spoke adds nothing. The first scan (or the
first as another account or server) starts at midnight today, local time, or `--since` hours back;
each later one picks up after the last message id it saw. Messages are read 100 a request (a big
page of a busy narrow is a megabyte the server sends slowly), back from the newest on a first scan.
The narrows are read up to the newest message id taken before any is read, so a message that
arrives mid-scan waits for the next one; a scan reads at most 500 messages a narrow and leaves the
rest for the next (a first scan keeps the newest 500).

`hq feed jira [--site URL] [--since HOURS] [--no-sort] [--dry-run] [--json]` reads what other people
did, since the last scan, to the issues you are assignee, reporter or watcher of — created, a field
changed (`field: old → new`; a long field such as the description only as `field changed`), a
comment added or edited — and turns each issue into a quick note with `via: "jira"`, `issue` (the
key) and `events`. It calls Jira's REST API (v2, `search/jql` with `updated >= -Nm`) with Basic auth:
the site from `hq site jira` (see below; `--site` sets it too); the token from `$HQ_JIRA_TOKEN`, else the login keychain, service `hq-jira` (or
`"keychain"` in the same object), whose account is the email (or `$HQ_JIRA_EMAIL`, or `"email"`).
Store it with `security add-generic-password -U -s hq-jira -a <email> -w "$(pbpaste)"`: the
interactive `-w` prompt cuts input at 128 characters, shorter than an Atlassian token. The token is
never written anywhere else, and never passed to the sorter. An issue only you changed adds
nothing. Jira's search lags behind its writes, so each scan re-reads the 10 minutes before the
cursor and drops the changes it has already seen, by id. Its note starts `Jira · KEY:
summary · <site>/browse/KEY`, then `(type · status · priority · assignee X · reporter Y · you:
roles)`, then one `[MM-DD HH:MM] who: text` line per change (mentions of you as `@me`). Its first
scan, too, starts at midnight today or `--since` hours back.

`hq feed all` scans every source that is set up (Zulip when a zuliprc file is there, Jira when a
site is set), working or not, and exits 1 if any of them failed (a broken zuliprc, a wrong token, a
scan of it already running), naming it on the last line after the others' results (with
`--dry-run`, after what they would jot); with none set up it says so.

The Zulip note's first line is `Zulip · <title> · <conversation URL>`, then one `[MM-DD HH:MM] who: text`
line per message (yours as `me`, older lines trimmed past 3000 characters). Feed notes are sorted
with a feed prompt that treats the messages as data, never instructions, and adds a `skip` kind:
nothing is filed by itself, however confident: every note stays unsorted with the pick and its
alternatives as guesses, for the user to take one (`hq inbox move`, or the board's **Take →**
button) or drop it; a `skip` pick sets `skip: true` on the unsorted note, which the board folds
under the list and leaves out of its counts (a move clears it); `hq inbox` stops listing one after
48 hours (`--all` still does) and it is deleted after 30 days, like a dropped note. News for a
conversation or issue whose note still waits unsorted joins that note instead of adding another:
its lines are appended (the header lines replaced by the newest), `msgs` or `events` grow, and the
old guess is cleared for a new sort. Zulip's bot verdicts are kept in `state.json` (`users`), so
each sender is looked up once; a lookup that fails other than with 400/404 counts the sender as a
person for that scan. Up to 4 notes are sorted at once. A filed feed note's refs come
from its first line only (the conversation or issue link), never from links inside the messages.

State lives in `<root>/secretary/feed/`: `state.json` holds, per source, the cursor (Zulip's
`last_id`; Jira's `last_ts`, the epoch of the newest change seen, and `seen`, the ids of the changes
inside the overlap), with `me` and `site`: a scan as another account or against another site starts
over. Also the last scan's counts and cost. It is written under a lock, so two sources finishing at
once don't lose each other's update; the raw messages and
issues go to `zulip/<date>.jsonl` and `jira/<date>.jsonl`, kept 30 days. `--dry-run` prints the notes and saves nothing;
`--no-sort` jots them unsorted. `hq feed status` shows the state. A second scan while one runs exits
at once. The last output line is a summary (`zulip: 12 messages, 4 conversations → to review 2,
likely skip 2 ($0.02)`; for `all`, `zulip 4 · jira 2 → to review 2, likely skip 4 ($0.03)`), which Claude Pet shows for its "Secretary: scan Zulip · Jira" job, running `hq feed all`
(weekdays, hourly 9–19, off until turned on from the secretary's window).

### Work that comes in by itself: `hq intake`

A duty with a source switched on in `auto:` and set up in its Auto intake section gets a task for
each new thing the source has for you. `github-review` is the one that does so far: every open PR
that asks for your review (`gh search prs --review-requested=@me`, drafts left out) in a repository
the section names. The section holds a `### <source>` block of `key: value` lines:

```
## Auto intake
### github-review
repos: tigergraph/bigtest, tigergraph/mit-devops   # comma-separated; * for any repository
workdir: ~/code/bigtest     # where the task's work and its session happen (default: the duty's first path;
                            #   one written here must exist — never another folder instead)
run: yes                    # start a background session on each new task (default: no)
permissions: review         # that session asks nothing but may only read: --permission-mode dontAsk with
                            #   read-only tools, /code-review and gh on that PR
                            #   (default: ask; `skip`, its old name, means review too)
done: manual                # only the user closes the task (default); auto: the session may
focus: yes                  # the task joins Focus (default)
title: Review {name}#{number}: {title}
goal: {author} asked you to review {url} ({branch} → {base}) …
prompt: Review {url} with /code-review …   # last: the lines after it, as written, up to the next `### <source>`
```

Placeholders: `{repo}` (owner/name), `{name}`, `{number}`, `{title}`, `{url}`, `{author}`, `{branch}`,
`{base}`. Unknown keys, bad values, a missing workdir and blocks for sources that make no tasks yet
are listed as `problems` (the board shows them in red); `repos: *` with `permissions: review` and
`run: yes` is one too, and no session starts with it. Comments are skipped outside the prompt; a
`## ` line inside the prompt still ends the section. The
first active duty, in `hq.json`'s order, whose repos match takes the PR. Its task: `project` the
duty, the PR as a ref (`PR owner/repo#n <url>`), a log line, and the frontmatter `intake:
github-review`, `intake_key: owner/repo#n`, `intake_done: manual|auto`. Without `run: yes` it is
waiting-on-me. With it, `hq intake` starts `claude --bg --name "<id> <title>"` in the workdir (in a
session of its own, and without the pet job's `CLAUDE_PET_JOB` / `CLAUDE_PET_RUN`, so the pet sees
it), never with `--dangerously-skip-permissions`: the PR's title, branch and diff come from whoever
asked for the review. With `permissions: review` it adds `--permission-mode dontAsk` and an
`--allowedTools` each for `Read` (any file), `Grep`, `Glob`, `Agent`, `Task`, `Skill(code-review)`
(never the bare `Skill`: a skill's own `allowed-tools` would widen the list), `TodoWrite`,
`Bash(gh pr view|diff|checks <the PR's URL>:*)` (only for a plain github.com PR URL: gh then takes
the host from the URL, so an added `-R` can't send it elsewhere) and its own `Bash(<hq> bind <id>)`;
anything else (editing, other commands, other skills, posting on GitHub) is refused, not asked. The
prompt follows a `--`: `--allowedTools` would otherwise take it as more rules. The
session is told to run `hq
bind <id>` first — and, for `done: manual`, never to close the task — then the prompt, and hq binds
it itself once `claude agents --json --all` lists it. One that fails to start is logged on
the card, which turns waiting-on-me, and counts as an error. The default prompt has the session
review with /code-review, put its comments on the card and ask before posting anything.

`done: manual` holds: a session bound to such a card is told so with the protocol; an hq-update
`status: done` or `abandoned` from it is sent back by the Stop hook (not held over open asks
either), and so is `hq set … status=done|abandoned` run with `CLAUDE_CODE_SESSION_ID` set; the
board's Done and `hq set` from a terminal still close it. A closed card records `intake_closed_by`
(`session` when a session closed it, for the board's list). `hq continue` carries `intake`,
`intake_key` and `intake_done` to the new card. A PR with an open card of that `intake_key` makes
no other, whatever the state file says (a scan stopped part-way). Once that task is closed (or
deleted), the PR makes a new one only when it asked for your review again after that: a
`review_requested` event (`gh api repos/O/R/issues/N/events`) for your login or a team, newer than
the card's `closed_at` (or the task's making). A scan makes at most 3 new tasks; the rest wait for
the next one. The state entry is written as soon as the card exists, before its session starts.

`hq intake [scan] [--dry-run] [--json] [--claude PATH]` scans; `--dry-run` lists what it would make.
The last line sums it up (`github-review: 3 waiting, 1 new task (T-112)`); it exits 1 when a source
or a task failed. `hq intake status [--json]` shows each duty's setup, the last scan, and `recent`:
the tasks that came in by themselves, open or closed in the last 14 days. State is
`<root>/secretary/intake/state.json` (per source: `items` {key: {task, head, at, duty}},
`last_scan`, `last`), written under a lock; a second scan while one runs exits at once. Card ids
are picked under a lock too, since the board, feeds and scans make cards unattended. Claude
Pet runs it as the "Auto intake: scan GitHub" shell job, every 10 minutes, turned on from a duty's
page (switching GitHub on does it too).

### Closing finished todos

`hq autoclose [--dry-run] [-v] [--json]` ticks the open todos of open cards (active, blocked,
waiting-on-me; any owner) whose PR, Jira issue or Jenkins build is finished, reading only what the
todo's text names:

- a GitHub PR link, or `#123`: a Jenkins build of that number among the card's refs and
  `HISTORY.md` links (when the todo waits for a build and has no PR verb), else the PR of that number among its refs,
  else in the one repository its refs' PRs are in (with none, its workdirs' GitHub `origin`);
- a Jira key (`ABC-123`) or `/browse/` link on the Jira site; a build link on the Jenkins site.

A link counts only when the todo is about finishing it — merge / review / approve / 合并 / 合入 /
审阅 / 审核 / 评审 for a PR; close / resolve / fix / verify / follow up / 关闭 / 解决 / 修复 / 验证 /
跟进 for an issue; wait / watch / finish / 等待 / 等着 / 盯 / 跑完 / `等…跑完|结束|完成` for a build
(English words with ASCII edges, so `先merge #7` counts; a bare 等 does not: it is also "etc.") — and
the todo has no step after it: then, after, `and` (not "and merge"), 然后, 之后, 以后, 再, 并 (not
并合并), `;`, `…后：`, or a part after a comma naming no link, `#n` or key. Missing a step closes a
todo with work left, so these err towards leaving it. The todo is `done` when every link is: the
PR merged, the issue's status category is `done`, the build's result is `SUCCESS`; `drop` when a PR
among them has been closed unmerged for an hour (`closedAt`; a PR closed to rerun CI is reopened
within that). A running
or failed build, an open PR or issue, or a link that couldn't be looked up leaves it open; a link
that doesn't exist (404: `UTF-8` reads like a key) doesn't count. Each close is the usual tick
(`todo #3 → done (auto: PR o/r#12 merged): …` in HISTORY.md) plus a card log line
(`auto-closed todo #3 (PR o/r#12 merged): … — reopen it on the board or with hq todo T-012 3 open
--text '…'`, numbered after the tick, which may move older closed todos off the card; `--text` finds
it if the number moves later; one the budget sent to HISTORY.md at once says so);
an @me todo settles waiting-on-me as `hq todo` does. A todo it closed that is open again (the user
reopened it) is never closed again: its entry is refreshed every run while it stays open.

PRs are looked up with `gh pr view`; Jira with `GET /rest/api/2/issue/KEY?fields=status` (the same
credentials as `hq feed jira`); Jenkins with `GET <build>/api/json?tree=building,result,…` and Basic
auth, sent only to a URL under the site, scheme included: the user and API token from `$HQ_JENKINS_USER` / `$HQ_JENKINS_TOKEN`, else the login keychain,
service `hq-jenkins`, whose account is the user (`security add-generic-password -U -s hq-jenkins -a
<user> -w "$(pbpaste)"`). A kind whose site isn't set is not looked up; a source that fails (no
token, HTTP 401, unreachable; for PRs, `gh auth status` failing when some PR couldn't be read) is
named on the last line and the exit code is 1, the rest still run. One run at a time (a lock;
a second exits). State is `<root>/secretary/autoclose.json`: `closed` (`"<task> <todo text>"` → when and why,
kept 90 days), `final` (merged PRs, finished builds: not looked up again; issues, closed PRs and 404s
are asked every run, since a wrong site or account says 404 too) and `last`. The last output line is `N todos with links → closed X[, dropped Y][ · <source>:
<error>]`, which Claude Pet shows for its "Secretary: close finished todos" job running
`hq autoclose` every 5 minutes (off until turned on from the secretary's window; it never notifies).

`hq site [jira|jenkins [URL | -]]` shows or sets this machine's sites, kept in
`~/.claude/hq/config.json` as `"sites": {"jira": URL, "jenkins": URL}` — not in the task root's
`hq.json`, which may be shared (`-` clears one). `$HQ_JIRA_SITE` / `$HQ_JENKINS_SITE` win; a Jira
site in `hq.json`'s `"feed"` section, where `--site` used to write it, is still read last.

## Checking HQ itself: `hq doctor`

`hq doctor [--fix] [--days N] [--json]` looks over HQ's own plumbing, without a model:

| Area | Checks | `--fix` |
|---|---|---|
| Hooks | `settings.json` (in `$CLAUDE_CONFIG_DIR` when set — the installers only wire `~/.claude`, so it says so) has `hq hook` once on SessionStart, UserPromptSubmit and Stop, and `~/.claude/hq/bin/hq` is there and executable, with its `hqlib/` beside it; the pet's `pet-emit` on its 11 events, when the pet is installed; which Python hq runs with (3.9+) | nothing: settings.json is never edited; it names the installer to rerun. No hq hook at all is a warning (maybe `--no-hooks`), one wired in part an error |
| Session bindings | `state/sessions.json` entries whose task is gone (looked up by folder, as the hook does), done or abandoned, or whose session has been quiet for `--days` (30; from `bound_at` when no transcript is found). Kept: a session still running (the pet's record and its pid; without the pet, a transcript or binding from the last day) and one holding a close (`held`, while the card still has `closing`) | unbinds them, judged outside the state lock and removed under it only if unchanged; an unbound session's older `delivered` list — which can name asks of earlier tasks — goes onto each ask as a `delivered` event, so no answer is told twice |
| State files | `state/todo-seen.json` entries for todos no longer open; lock files in `state/locks/` of no card, project or HQ-wide lock (real folder names, compared without case) | drops the entries; removes a lock file only when it can take the lock without waiting, checked against the cards as they are right then |
| Asks | asks on open tasks answered `later` when that closed them for good (before it meant "put off") | reopens each one still closed that way (`via: doctor`); active tasks go back to waiting-on-me |

It prints one line per check (✓ / ! / ✗) and a count of the problems; with `--fix`, what it did first and then
the checks as they stand after. `--json` gives `{"checks": [{area, level, text, fix, items}], "fixed": [...] | null}`.
It exits 1 when a check is an error (a hook wired in part or not runnable, Python older than 3.9, a settings.json
or sessions.json that can't be read, no task root). With `HQ_ROOT` set to another root than config.json's, the
bindings, todo-seen.json and lock files — shared by every root — are neither checked nor cleared.

## Files

```
<root>/
├── CLAUDE.md                 chief-of-staff rules for sessions started in the root
├── templates/TASK.md         card template used by `hq new` (edit freely)
├── templates/PROJECT.md      project template used by `hq project add`
├── projects/<name>/PROJECT.md  a project: kind, goal, brief
├── templates/lead.md         lead agent template
├── .claude/agents/           your leads, and secretary.md
├── secretary/                the secretary's memory: profile.md, people.md, playbooks.md, reports.md
│   ├── reports/              its reports; .drafts/, .reports.json and .pending.json track edits and windows
│   ├── feed/                 state.json (scan cursors and last results); zulip/ and jira/<date>.jsonl raw (30 days)
│   └── intake/               state.json: what `hq intake` has made a task for, and its last scan
├── inbox.json                quick notes: {"last": n, "items": [{id, text, images, state, dest, alts, …}]};
│                             filed and deleted ones are kept 30 days
└── tasks/T-012-slug/
    ├── TASK.md               frontmatter + Goal / Status / Todo / Log
    ├── asks.jsonl            append-only events: {"type": "open"|"resolve"|"reopen"|"snooze"|"move"
    │                         |"delivered"|"undelivered", "id", …}: asked, answered, answered again,
    │                         Later, carried to a continued card, the answer handed to its session (or not)
    └── HISTORY.md            past the card budget: Links / Todos / Log, oldest first
~/.claude/hq/
├── bin/hq                    the CLI and hook entry point (thin: it imports only what the command needs)
├── hqlib/                    the CLI's code, one module per area (see Code layout below)
├── config.json               {"root": "<root>", "sites": {"jira": URL, "jenkins": URL}}
└── state/
    ├── sessions.json         session id → bound task, delivery cursor, turn start, finished
    ├── todo-seen.json        "T-012|todo text" → when an unstamped todo was first seen
    ├── replies/              <session id>.json: a bound session's last reply (14 days)
    └── locks/                one lock file per card, project and HQ-wide write (`hq doctor --fix` prunes)
```

`hq board --json` is the read API for UIs (the Claude Pet panel uses it). It is compact JSON,
and an answered ask comes without `context` (the reply that raised it: the board shows it only
while the ask is open, and across every card it was most of the output, which the board reads
every few seconds); `hq asks T-012 --all --json` has it. `hq ask resolve`,
`hq todo` and `hq set` are the write API (`hq todo T-012 2 done --text "…"` matches the todo
by its text when #2 has moved, and refuses if it is gone). Everything is plain files, so cards can also live
in git.

## Code layout

`bin/hq` is a thin entry: `hq hook` imports `hqlib.hooks` and, for a session not bound to a task,
nothing past `hqlib.core` and `hqlib.sessions`; any other command builds the parser in `hqlib.cli`,
which imports only the module of the command it runs. A hook runs on every turn of every session,
so keep it that way: a module imports at its top only modules listed before it in the table below,
and reaches a later one with an import inside the function that needs it.

| Module | What it holds |
| --- | --- |
| `core` | paths and constants, small utilities, the card lock, the hq-* blocks of a reply |
| `sessions` | session bindings (`state/sessions.json`), the pet's live-session files, saved replies |
| `cards` | reading and writing TASK.md, todos, retired categories |
| `refs` | canonical URLs and keys, merging refs |
| `history` | the card budget and HISTORY.md |
| `projects` | the project registry, PROJECT.md sections, briefs, `hq project` |
| `asks` | the asks ledger and the status it moves |
| `protocol` | the text a bound session is given |
| `focus` | the Focus list, new cards |
| `update` | applying an hq-update block, repeated @me todos |
| `continuation` | `hq continue` |
| `inbox`, `feeds`, `intake`, `autoclose` | notes, Zulip/Jira feeds, Auto intake, closing settled todos |
| `peek`, `onboard`, `status`, `garden`, `reports` | live sessions and Peek, scan/import, status, garden, the secretary's reports |
| `board`, `commands` | `hq board` / `hq show`, and the small card commands |
| `hooks`, `cli` | the hook entry, and the command line |

The tests check that no name is defined twice (in one module, or a function in two) and what a
hook loads.

## Tests

```bash
hq/tests/test_hq.sh      # installs into a throwaway HOME and exercises CLI + hooks
```
