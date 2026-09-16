# Claude Pet

**English** · [中文](README.zh-CN.md)

A small robot that lives on your macOS desktop and mirrors the state of **every** Claude Code session on this machine.

No more tabbing through terminal windows to find out which session finished and which one is stuck. A glance at the corner of the screen tells you whether anything needs you.

The lamp on its antenna is the part you can read without focusing on it:

| Lamp | What it is doing | What it means |
|---|---|---|
| Red, fast blink | arms over its head, jolting, speech bubble | a session has been waiting on you for over a minute. The bubble names the project |
| Amber, pulsing | stops typing, turns around and waves | a session is waiting for your approval |
| Green, slow blink | heads down, typing, code scrolling | a session is working |
| Off | asleep at the desk with z's drifting up | everything is done |

**Left-click** to expand the list — what each session is running, and for how long.
**Click a row marked ↗** to jump straight to that session's terminal tab (Orca and iTerm2).
**Hover a row** and the bubble shows that session's name; when one directory has several sessions, the names are shown inline instead.
**Hover the robot** for a second to see your remaining quota.
**Click the × at the end of a row** to mute that session — it comes back on its own the next time you type into it.
**Right-click** for the menu: nap / launch at login / quit.
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
2. `~/.claude/pet/` — the hook binary and the session state files
3. **`~/.claude/settings.json` — 7 appended hooks**

The third is the one to pay attention to: that file governs the behaviour of every Claude Code session you run. The installer **only appends** — not one of your existing hooks is touched. It backs the file up to `~/.claude/settings.json.bak-claudepet-<timestamp>` first, parses the result immediately after writing, and restores the backup on any doubt. Running the installer twice is idempotent; the hooks are not added again.

The pet reads the state files under `~/.claude/pet/sessions/`, which record a project name, the current state, a tool name, a process id and timestamps. **It does not read your conversations, makes no network requests, and uploads nothing.**

## Uninstall

```bash
./uninstall.sh
```

Removes the hooks, deletes the app, cleans up the directory. `settings.json` goes back to exactly what it was; the backups are left in place for you to delete once you are satisfied.

## Known rough edges

- The expanded panel always opens to the left, so it can run off-screen if you drag the pet to the far-left edge of the display (the pet itself stays put).
- Click-through is computed from two rectangles rather than the figure's outline, so a few apparently-transparent pixels near the robot still swallow clicks.
- Roughly 4% CPU while idle — that is the breathing animation. Leaving it running all day costs a little battery.
- No Apple Developer signature. The installer clears macOS's download quarantine flag automatically; if Gatekeeper still blocks it, allow it once under System Settings → Privacy & Security.
- Jumping to an **iTerm2** tab raises a macOS Automation prompt the first time. Deny it and jumps fail silently from then on; you can re-allow it under System Settings → Privacy & Security → Automation. **Orca needs no permission at all.**

## Troubleshooting

**The pet is asleep even though sessions are running**
Hooks only apply to **newly started** sessions. Open a new window. If that does not help, check whether files are appearing under `~/.claude/pet/sessions/`.

**A session I closed is still listed**
It should not be: liveness is a process check, so closing the terminal removes it immediately. If you do see one, its state file probably predates the upgrade (no process id recorded) — say anything in that session and it will correct itself.

**A row has no ↗ and clicking does nothing**
Only Orca and iTerm2 sessions can be jumped to. Sessions that were already open before installing also lack it until they next run a hook.

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
