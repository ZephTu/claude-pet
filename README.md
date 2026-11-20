# Claude Pet

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml/badge.svg)](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml)

Two things for people who run many Claude Code sessions at once on a Mac:

- **The pet** — a cat on your desktop that shows, at a glance, what every session is doing: working, finished, or waiting for you.
- **The Task Board** — a window behind the cat that keeps track of the *work*: what each session is for, what it asked you, what you still owe it — so any session can be closed and the next one picks up where it left off.

<img src="docs/images/cat.gif" width="300" alt="One turn as the cat lives it: asleep, starting work, raising a paw for approval, shouting when ignored, back to work, cheering the finished turn, and dozing off again">

## The pet: every session at a glance

The cat's posture is the state of all your sessions together — asleep when everything has stopped, typing while something works, a raised paw when a session needs your approval or an answer, on its hind legs shouting when you have ignored it for a minute. It never makes a sound and never posts a system notification; it changes in the corner of your eye.

![Every state the cat can show](docs/images/cat-states.png)

- **Click the cat** for the session list, grouped by what wants you first: *Needs you* (approvals, questions), *Finished* (turns you have not looked at, each with the first line of Claude's last reply), *Running*.
- **Allow or Deny** a permission prompt from the list without going back to the terminal — whichever answer comes first, there or here, counts.
- **Jump to the terminal tab** a session runs in (↗): Orca, iTerm2, Ghostty 1.4+, and VS Code / Cursor (to the window).
- **Finish bubbles** name the session that just finished and what it said; a count by the cat's ear says how many are unread.
- **Hover the cat** for your 5-hour and weekly quota; **hover a row** for its path, context use, model and the last tool call.
- **Mute, postpone, rename or pin** a session from its row. A muted one comes back the next time you type into it.
- It notices a session **going round in circles** (four failed tool calls in a row) and work **left running in the background** after a turn ended.

**The full tour** — every state, every button, and why each works the way it does: [docs/pet.md](docs/pet.md).

### What the pet can't see

- **Only sessions started after the install.** Hooks load when a session starts; windows already open are invisible until restarted.
- **An Esc interrupt sends no signal.** Claude Code emits no hook for it, so such a turn shows *No recent activity* after 90 seconds rather than "finished".
- **A turn waiting on a background agent isn't "finished".** It is shown as waiting, and reported done only when the agent wakes the session again.
- **Multiple-choice questions** (`AskUserQuestion`) can't be answered from the pet — the picks are the answer, so the row takes you to the terminal.
- **Jumping and messaging depend on the terminal.** Jump: Orca, iTerm2, Ghostty 1.4+; VS Code-family editors only to the right window, not the tab; anything else has no ↗. Sending a message from the Task Board: Orca and iTerm2 only. Background `claude --bg` sessions have no terminal at all.
- **Quota, context and model need your statusline.** Claude Code hands them only to the statusline command; [claude-hud](https://github.com/jarrodwatts/claude-hud) or `pet-emit --statusline` has to save them ([how](docs/pet.md#optional-reading-quota-from-your-statusline)). Without that, everything else works.
- **macOS 14+ only**, and not signed by an Apple Developer ID (the installer strips the quarantine flag; Gatekeeper may still ask). Click-through is a rectangle, not the cat's outline. Animating costs about 7% of one core and 310 MB.

## The Task Board

With a dozen sessions open across several repos, the hard part stops being the work. It is remembering what each session was for, what it asked you, and whether you ever answered. The Task Board (HQ) moves that out of the conversations and into **task cards**: one per piece of work, with a status, a next step, todos and a log. A session bound to a task reads the card before it starts and writes progress back, so the card — not any one conversation — is the record.

**Double-click the cat** to open it (or right-click → **Task Board…**).

<img src="docs/images/board-today.png" width="900" alt="The Today view: the tasks picked for today, each with its open questions, todos and sessions; the live sessions on the right">

**Today** shows only the tasks you picked for today, each with everything it needs from you: its open questions, your todos, and the sessions working on it. The top bar keeps count of what is waiting and shows your quota.

### Questions, answered in one go

A session ends its reply with the questions it needs answered; they become **asks** on the board and stay there until you answer — nothing you skip is taken as "no". Answer each with **Yes** (go ahead, or as suggested — or write your own answer in the note, several lines and screenshots welcome), **No**, **To todo** when it is really something you will do yourself, or **Later**: the question stays, out of sight until tomorrow, and the session is told you'll answer later. When a task has several, pick an answer for each and send them together as one message:

<img src="docs/images/board-asks.gif" width="700" alt="Three questions from one session: an answer is picked for each, with a note on the first and the third turned into a todo, then all three are sent at once">

The answer goes straight into the session that asked (Orca and iTerm2), or reaches it at the start of its next turn. With several sessions on one task, only the one that asked is told.

### Every task and every session

<img src="docs/images/board-all.png" width="900" alt="The All view: unanswered asks and your todos on the left, tasks grouped by project in the middle, every live session on the right">

**All** is the whole board: what needs you on the left, tasks by project or by status in the middle, every live session on the right — with the same status dots as the cat's list, its context use, and a **new** tag on a finished turn you haven't looked at.

<img src="docs/images/board-task.png" width="900" alt="A task opened: its status line, todos with a Do it button on Claude's, the live session, an earlier session with Resume, and the log">

Open a task for the rest of its card:

- **Todos** — `@me` for you, `@claude` for a session. **▶ Do it** hands a Claude todo to the task's session, or starts one to do it.
- **Sessions** — bind a live one, start a new one in the task's directory, or **↻ Resume** an earlier one where it left off.
- **Log** — decisions and findings, timestamped to the second; sessions read it.

### Talk to a session from the board

<img src="docs/images/board-peek.png" width="900" alt="The conversation window: the last messages of a session, rendered, with a reply box at the bottom">

👁 opens a session's recent conversation; reply from the box at the bottom (paste or drop images too). It arrives exactly as if you had typed it in the terminal — queued if the session is busy.

**And the small things:** drafts you were typing survive a restart; removing or unbinding anything takes two clicks; the board has a built-in **Guide** in English and Chinese.

HQ is optional and installed after the pet — see [hq/README.md](hq/README.md) for how it works, the `hq` CLI and the card format.

## Install

Requirements: macOS 14+, [Claude Code](https://claude.com/claude-code), and a Swift toolchain (Xcode Command Line Tools) to build from source. HQ also needs `python3` (standard library only).

```bash
./scripts/install.sh                              # the pet
hq/install.sh --root ~/claude-hq                  # optional: the Task Board; lists every change and asks first
hq/install.sh --root ~/claude-hq --no-hooks       # the board and CLI only, settings.json untouched
```

**The pet's installer edits `~/.claude/settings.json`**, appending eleven hooks and leaving yours byte for byte as they were; the file is backed up first, written atomically and verified. HQ adds three more (unless `--no-hooks`), which act only in sessions bound to a task. Hooks take effect in **newly started** sessions.

What it keeps: each session's current state, one record per finished turn (7 days), and **one line of each conversation** — the first line of Claude's last reply. Your prompts are never stored, and the pet makes **no network requests**. The Task Board reads live sessions' recent messages from their local transcripts to show them; nothing is sent anywhere. Details: [docs/pet.md](docs/pet.md#what-it-touches).

```bash
./scripts/uninstall.sh      # hooks, app and launch agent removed; settings.json back to what it was
hq/uninstall.sh             # HQ's hooks and commands removed; your task cards are kept
./scripts/package.sh        # a tarball with a prebuilt binary and a one-click installer, to send to someone
```

## More

- [docs/pet.md](docs/pet.md) — the pet in full
- [hq/README.md](hq/README.md) — the Task Board: how it works, the `hq` CLI, the card format
- [docs/development.md](docs/development.md) — tests, debugging hooks, and three things to know before changing anything

## License

MIT — see [LICENSE](LICENSE).
