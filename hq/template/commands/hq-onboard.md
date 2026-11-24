---
description: Set up HQ from the Claude Code sessions already on this machine — duties, projects, task cards, bindings — after asking
argument-hint: "[days, default 60]"
---
Help the user turn their existing Claude Code sessions into an HQ board. Nothing is created until the user confirms. HQ CLI: `~/.claude/hq/bin/hq` (below: `hq`).

A project in HQ is a **line of work, not a folder**: a *duty* (a standing responsibility — release testing, code review, an app you maintain) or a *goal* (has an end — a migration, a launch; it can sit under a duty). One repository often carries several lines of work, and a line of work often spans repositories or has none. So group by what the sessions were *about*, and treat directories only as hints.

**1. Scan.** Run `hq scan --json --days ${ARGUMENTS:-60}` and `hq board --json`. The scan lists `sessions` (id, cwd, title, first message, last activity, `live`, `task` when already bound) and groups them by repository under `projects` — a hint, not a proposal. The board has the projects and tasks that already exist: never duplicate them, and skip sessions already bound to a task.

**2. Read and draft tasks.** Know what each session was doing: its title and first message, then `hq peek <session-id> -n 12` for the recent messages. With more than ~10 sessions, split the reading across parallel subagents (by repository, say) and have each return draft tasks — never paste whole transcripts into this conversation. One task per piece of work: several sessions on the same work → one task; one session that did two unrelated things → two; a quick one-off question → no task. For each: title, status (active / blocked / waiting-on-me / done), the next step, a few lines on where it stands, open todos (`@me` for what the user must do, including drafts they still have to send), related tickets / PRs / docs as `title URL`, workdirs, the session ids, and a confidence (high / medium / low).

**3. Draft the lines of work.** Group the tasks into lines of work. Use an existing project when one fits. For each new one: name (short, lowercase-dashes), kind (duty or goal), a one-line title, its goal (a duty: what it covers), for a goal the duty it sits under if any and a deadline if one was mentioned, and directories only for repositories that belong to it alone (they make new tasks started there default to it). A done one-off with nothing like it elsewhere can go without a project.

**4. Ask.** Show the user the lines of work (new ones marked, kind, what they cover) and then the tasks under each as a compact table. Say plainly that statuses were inferred from the conversations and the low-confidence ones need checking. Ask them to confirm, rename, merge, re-file between projects, or drop items before anything is written; ask about the kind of any line of work you were unsure of (AskUserQuestion with multiSelect when available).

**5. Create — one plan, one command.** Write the confirmed plan as JSON to a file in your scratchpad (or `/tmp`), then run `hq import <file> --dry-run`: it checks everything and prints what it would create. Fix any problem it names and run it again until it is clean; if the preview differs from what the user confirmed, show them. Then `hq import <file>`. Don't create things one by one with `hq new` / `hq set` / `hq addtodo`: each is another round trip, and a half-finished import is worse than none. The plan:

```json
{
  "projects": [
    {"name": "perf", "kind": "duty", "title": "Performance testing",
     "goal": "Benchmarks, regressions, rebaselines", "paths": ["/abs/repo/perf"]},
    {"name": "perf-427", "kind": "goal", "title": "Rebaseline 4.2.7", "parent": "perf",
     "due": "2026-12-31", "goal": "New baseline numbers for 4.2.7"}
  ],
  "tasks": [
    {"title": "Rebaseline LDBC SF100", "project": "perf-427", "status": "waiting-on-me",
     "next": "Review the diff of the new numbers", "state": ["Numbers collected", "Diff ready"],
     "todos": ["@me review the diff"], "refs": ["PR #12 https://github.com/org/repo/pull/12"],
     "workdirs": ["/abs/repo"], "sessions": ["<full session id>"], "confidence": "medium"}
  ]
}
```

Only `name` + `kind` (projects) and `title` (tasks) are required. `projects` holds only new ones — a task names an existing project directly. Optional on a project: `done_when` (a duty: what "running well" looks like) and `brief` (what every session on its tasks should be told). Optional on a task: `goal` and `log` (lines for its log). Import binds the live sessions to their tasks and records the ended ones on the cards, and logs on each card that it came from onboarding with its confidence.

**6. Wrap up.** Reply with what was created (lines of work, tasks per line, sessions bound), what was skipped, and where to adjust: the task board (double-click the Claude Pet cat; everything is editable on Projects & duties) or by asking Claude in any session.
