---
description: Set up HQ from the Claude Code sessions already on this machine — projects, task cards, bindings — after asking
argument-hint: "[days, default 60]"
---
Help the user turn their existing Claude Code sessions into an HQ board. Nothing is created until the user confirms. HQ CLI: `~/.claude/hq/bin/hq` (below: `hq`).

**1. Scan.** Run `hq scan --json --days ${ARGUMENTS:-60}`. It returns `projects` (one per git repository or directory, with session count, last activity, and `existing` if HQ already has a project for it) and `sessions` (id, cwd, title, first message, last activity, live, task if already bound). Also run `hq board --json` to see existing projects and tasks — never duplicate them.

**2. Projects — ask.** Show the suggested new projects as a short table (name · directory · sessions · last active). Personal or throwaway directories are common: let the user pick which to create, rename any, or skip (use AskUserQuestion with multiSelect when available). Then create the chosen ones: `hq scan --apply-projects --only <name,name>`; rename with `hq project rename OLD NEW` if asked.

**3. Tasks — draft.** For each chosen project, look at its sessions (skip ones already bound to a task). Read enough to know what each was doing: the scan's title and first message, then `hq peek <session-id> -n 12` for the recent messages. With more than ~10 sessions, split the reading across parallel subagents by project and have each return a draft list — do not paste whole transcripts into this conversation. Draft one task per piece of work (several sessions on the same work → one task; one session that did two unrelated things → two tasks; quick one-off Q&A → no task). For each draft: title, project, status (active / blocked / waiting-on-me / done), the next step, open todos (`@me` for what the user must do — including drafts the user still has to send), related tickets / PRs / docs as `title URL`, the session ids, and a confidence (high / medium / low).

**4. Tasks — ask.** Show the drafts as a compact table per project. Say plainly that statuses were inferred from the conversations and low-confidence ones need checking. Ask the user to confirm, edit, merge, or drop items before anything is written.

**5. Create.** For each confirmed task:
- `hq new "<title>" --project <project> --category <category> --workdir <dir>` (prints the id)
- `hq set <id> status=<status> "next=<next step>"`
- `hq addtodo <id> "@me …"` / `"@claude …"` per open todo, then `hq todo <id> <n> done` for any listed as already done
- `hq ref add <id> "<title> <url>"` per resource
- `hq log <id> "Created by /hq-onboard from sessions <ids> (confidence <c>); verify the status."`
- link the sessions: `hq bind <id> --session <full-session-id>` for sessions that are **live** (they pick up the task's rules on their next message); for ended ones, `hq set <id> 'sessions=["<8-char prefix>", …]'` so their history stays reachable from the board.

**6. Wrap up.** Reply with: what was created (projects, tasks per project, sessions bound), what was skipped, and where to adjust — the task board (double-click the Claude Pet cat; Projects, Categories and every task are editable there) or by asking Claude in any session. Remind the user that low-confidence tasks are marked in their logs.
