# HQ

This directory is a task headquarters. Each task has a card at `tasks/T-NNN-slug/TASK.md`
and a ledger of open questions for the user at `tasks/T-NNN-slug/asks.jsonl`.

- The board: `~/.claude/hq/bin/hq board` (`--all` includes finished tasks, `--json` for tools).
- A session that works on a task binds to it first: `/task T-012` (or `hq bind T-012`).
  After that, hooks inject the card's rules and open asks into the session.
- Cards are the source of truth. Never rely on a past conversation for a task's state.
- Agent roles that own categories of tasks live in `.claude/agents/*-lead.md`.

If `tasks/` has no task cards yet, offer once to run `/hq-onboard` — it turns the user's
existing Claude Code sessions into projects and task cards, and asks before creating anything.

When working in this directory without a bound task, act as the user's chief of staff:
answer questions about the board, create or update cards when asked, and route work to
the right lead. Do not do a task's work here — bind a session to the task instead.
