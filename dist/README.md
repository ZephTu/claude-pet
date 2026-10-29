# Claude Pet

**English** · [中文](README.zh-CN.md)

A cat that lives on your macOS desktop and mirrors the state of **every** Claude Code session on this machine.

No more tabbing through terminal windows to find out which session finished and which one is stuck. A glance at the corner of the screen tells you whether anything needs you.

Its pose is the part you can read without focusing on it:

| What you see | What it means |
|---|---|
| curled up asleep, z's drifting up | everything is done |
| hunched over the laptop, typing | a session is working |
| a book up in both paws | reading |
| sorting a stack of paper | compacting its context |
| chin on a paw, laptop pushed aside | it parked a background agent and ended the turn; it will speak again by itself, so this turn gets no finish notice |
| a warning triangle over a cat that keeps working | a tool call failed or was interrupted. Usually not a failed task |
| a raised paw and a warning triangle | a session wants your approval |
| the same raised paw with a question mark | a session wants an answer — typing, not a decision |
| up on its hind legs, shouting, a red alarm beside it | a session has waited on you for over a minute. The bubble names the project and the command |
| both paws up, cheering | a turn just finished. Not a claim that the work was right |

It is animated frame by frame — loops for each pose, transitions between them, and the odd yawn or dance when it has been in one pose a while. With the system's Reduce motion on it holds still.

**Left-click** to expand the list — what each session is running, and for how long.
**Click a row marked ↗** to jump straight to that session's terminal tab (Orca and iTerm2; for VS Code and Cursor, to the window that has its project open).
**Allow / Deny** a permission prompt from the pet itself; answering in the terminal works as always. Multiple-choice questions are left to the terminal.
**Finish bubbles** stack above the cat, one per session that just finished, with the first line of what Claude said. Click one to jump to that session.
**Hover a row** and the bubble shows where that session is, how full its context window is, how long the turn has run versus how long since anything happened, and its last tool call.
**Hover the cat** for a second to see your remaining quota.
**Right-click the pet** for take a nap / keep list open / unmute all / quit; launch at login, the jump shortcut, bubble duration and count, and connection status are under Settings. **Right-click a row** to name that session, pin it, or mute it.
**Click the × at the end of a row** to mute that session — it comes back on its own the next time you type into it.
**Drag** to move it; it remembers where you put it.

It never makes a sound and never posts a system notification.

## Install

```bash
./install.sh
```

**You must start a NEW Claude Code session afterwards** for the hooks to take effect. Windows already open are unaffected.

## Requirements

- macOS 14 or newer
- Claude Code already installed

No Xcode, no Python, no jq. The package ships a universal binary that runs on both Intel and Apple Silicon.

## What it touches on your machine

Three places, all reversible with `./uninstall.sh`:

1. `~/Applications/ClaudePet.app` — the pet itself
2. `~/.claude/pet/` — the hook binary, the session state files, the finished-turn records and each session's last tool call
3. **`~/.claude/settings.json` — 11 appended hooks**

The third is the one to pay attention to: that file governs the behaviour of every Claude Code session you run. The installer **only appends** — not one of your existing hooks is touched. It backs the file up to `~/.claude/settings.json.bak-claudepet-<timestamp>` first, parses the result immediately after writing, and restores the backup on any doubt. Running the installer twice is idempotent; the hooks are not added again.

The pet reads the state files under `~/.claude/pet/sessions/`, which record a project name, the current state, a tool name, a process id and timestamps. **It does not read your conversations, makes no network requests, and uploads nothing.**

## Uninstall

```bash
./uninstall.sh
```

Removes the hooks, deletes the app, cleans up the directory. `settings.json` goes back to exactly what it was; the backups are left in place for you to delete once you are satisfied.

## Known rough edges

- Click-through is computed from a rectangle rather than the figure's outline, so a few apparently-transparent pixels near the cat still swallow clicks.
- Roughly 7% of one core while the cat animates (the app plus the WebKit processes that draw it). Leaving it running all day costs a little battery; Reduce motion stops the animation.
- No Apple Developer signature. The installer clears macOS's download quarantine flag automatically; if Gatekeeper still blocks it, allow it once under System Settings → Privacy & Security.
- Jumping to an **iTerm2** tab raises a macOS Automation prompt the first time. Deny it and jumps fail silently from then on; you can re-allow it under System Settings → Privacy & Security → Automation. **Orca needs no permission at all.**

## Troubleshooting

**The pet is asleep even though sessions are running**
Hooks only apply to **newly started** sessions. Open a new window. If that does not help, check whether files are appearing under `~/.claude/pet/sessions/`.

**A session I closed is still listed**
It should not be: liveness is a process check, so closing the terminal removes it immediately. If you do see one, its state file probably predates the upgrade (no process id recorded) — say anything in that session and it will correct itself.

**A row has no ↗ and clicking does nothing**
Only Orca, iTerm2, VS Code and Cursor sessions can be jumped to. Sessions that were already open before installing also lack it until they next run a hook.

**I want it to shut up for a while**
Right-click → Take a Nap. To silence one session only, hover its row and click the ×.

**I cannot find how to quit**
Right-click → Quit. It is deliberately absent from the Dock and from Cmd-Tab, so the context menu is the only way. Failing that, `pkill -x ClaudePet`.

## Source

The `src/` directory in this package is the complete source. To build it yourself:

```bash
cd src
./scripts/build-app.sh release           # this machine's architecture
./scripts/build-app.sh release universal # Intel + Apple Silicon
swift run ClaudePetTests                 # unit tests (not swift test — needs no Xcode)
./hooks/test-pet-emit.sh                 # hook behaviour tests
```
