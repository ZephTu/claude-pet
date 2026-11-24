---
description: Bind this session to an HQ task (or create one) and pick up from its card
argument-hint: "[T-012 | title of a new task]"
---
HQ binds a Claude Code session to a task card so the card, not the conversation, carries the state.

Argument: `$ARGUMENTS`

1. If the argument is empty: run `~/.claude/hq/bin/hq board` and show the user the open tasks whose `workdirs` include the current directory first. Ask which task this session should work on, or whether to create a new one. Stop there.
2. If the argument looks like a task id (`T-` followed by digits): run `~/.claude/hq/bin/hq bind <id>`.
3. Otherwise treat it as the title of a new task: run `~/.claude/hq/bin/hq new "<title>" --workdir "$PWD"` (add `--lead` if the user said so), then bind the id it prints.
4. After binding, follow the rules the bind command prints for the rest of this session. Read the card, then reply with three short lines: where the task stands, the next step, and anything waiting on the user.
