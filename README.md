# Claude Pet

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml/badge.svg)](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml)

A little robot that sits on your macOS desktop and shows, at a glance, what every Claude Code session on your machine is doing.

<img src="docs/images/pet.gif" width="300" alt="The robot cycling through its four states">

You stop tabbing through terminal windows to find out which session finished and which one is stuck waiting for you. It never makes a sound and never posts a system notification — it just changes in the corner of your eye.

## The lamp is the signal

The bulb on the antenna is the part you can read without focusing on it:

![Four states](docs/images/states.png)

| Lamp | Meaning | What it does |
| --- | --- | --- |
| 🟢 slow blink | a session is working | heads down, typing, code scrolling on its monitor |
| 🟡 pulse | a session needs your approval | stops typing, turns around, waves — and its monitor switches to a warning |
| 🔴 fast blink | ignored for 60s+ | both arms up, jolting, bubble names the project **and the command it is blocked on** |
| ⚫ off | everything is done | asleep at the desk with z's drifting up |

## What you can do with it

**Click it** to expand a list of every live session — what it is running, and for how long. **Drag** to move it; it remembers where you put it. **Right-click** for pause / launch-at-login / quit.

**Click a row marked ↗** to jump straight to the terminal tab that session is running in.

- **Orca** goes through its own CLI (`orca terminal switch`) and needs no system permission at all
- **iTerm2** goes through AppleScript, so the **first jump raises a macOS Automation prompt**; deny it and jumps fail silently afterwards
- Other terminals cannot be addressed — those rows have no ↗ and clicking them just closes the list

**Hover a row** for 0.45s and the bubble shows that session's name, taken from its terminal tab title. The list's first column is only a directory name, so three sessions open in one repo look identical; the name is what tells them apart. When a directory does have more than one session, the name is shown inline on a second line instead of on hover.

**Hover the robot itself** for a second and it reports your quota as two meters — the five-hour and weekly windows side by side, each with a countdown. The bar turns amber past 60% and red past 85%, the same warning ramp the antenna lamp uses.

**Click the × at the end of a row** to mute that session. A muted session is not in the list and cannot affect the robot's mood — it can sit blocked on a permission prompt without making the robot wave. It comes back on its own **the next time you type into it**; there is nothing to remember to undo. The panel footer says how many are muted, and the right-click menu can unmute them all at once.

When a session finishes a round of work the pet says so immediately, naming that session — so you learn it came to rest without watching for it.

A session stays listed for as long as its process is alive, however long it sits idle. Liveness is a kernel query, not a timestamp heuristic — an open session that nobody has touched in an hour is still an open session.

## Requirements

- macOS 14 or newer
- [Claude Code](https://claude.com/claude-code) installed
- A Swift toolchain (Xcode Command Line Tools) to build from source

Optional: the [claude-hud](https://github.com/jarrodwatts/claude-hud) statusline plugin. The pet reads the usage cache that plugin maintains rather than calling Anthropic's usage API itself — no OAuth token handling, no rate limit of its own. Without it, everything works except the quota readout.

## Install

```bash
./scripts/install.sh
```

Builds the working copy and installs it. No jq, no Python — just the Swift toolchain.

**This edits `~/.claude/settings.json`**, appending eight hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PermissionRequest`, `Stop`, `SessionEnd`). Your existing hooks are not touched — not one byte. The file is backed up first, written atomically, parsed back to verify, and restored from the backup on any doubt. That file drives every Claude Code session on the machine, so it is the highest-risk thing here; keep the backups.

Hooks only take effect in **newly started** sessions. Windows already open are unaffected.

## What it touches

Three places, all reversible by `./scripts/uninstall.sh`:

1. `~/Applications/ClaudePet.app` — the pet itself
2. `~/.claude/pet/` — the hook binary and one small state file per session
3. `~/.claude/settings.json` — seven appended hooks

The state files record a project name, the current state, a tool name, a process id and timestamps. **It does not read your conversations, and it makes no network requests of any kind.**

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the hooks, the app and the launch agent. `settings.json` returns to exactly what it was.

## Sending it to someone else

```bash
./scripts/package.sh
```

Produces two tarballs: one with a precompiled universal binary and a one-click installer, needing no developer tools on the receiving end, and one with just the source.

## Development

```bash
swift run ClaudePetTests     # unit tests — not `swift test`, see below
./hooks/test-pet-emit.sh     # hook behaviour tests
./hooks/test-settings-patch.sh  # settings.json round trip — see below
./scripts/build-app.sh       # build ClaudePet.app without installing
```

Tests run through a small hand-written harness as an executable target rather than XCTest: with only the Command Line Tools installed (no full Xcode), **neither XCTest nor swift-testing is available**, so `swift test` cannot run at all.

To watch all four states animate, serve the repo (`python3 -m http.server 8777`) and open
`http://127.0.0.1:8777/docs/previews/`. That page frames the real `Resources/pet/index.html`
rather than keeping a copy, so it cannot fall behind the app.

The design document in `docs/superpowers/specs/` explains the architecture and, more usefully, why each piece is the way it is. **It is written in Chinese** — the code, comments and this README are English, but that document has not been translated.

### Two things worth knowing before you change anything

**The hit region is two rectangles in `Sources/ClaudePetCore/PetLayout.swift`, and they must agree with the drawing in `Resources/pet/pet.css`.** Change the art and you must change `PetLayout`, and the other way round. No test can catch a mismatch — they can only lock the Swift half — so this is a convention, not a guardrail.

**The `settings.json` patch is tested against real files, not in process.** It is the only thing here that can break someone else's machine, and the parts that make it safe — the backup, the atomic write, the parse-back, the rollback — exist only on disk; testing them in memory tests nothing. The assertion that matters is the round trip: install then uninstall, and not one field of the user's own hooks may differ.

**Terminal jumping is split in two on purpose.** Everything testable — identifying the terminal, parsing session ids, rejecting AppleScript injection — lives in `Sources/ClaudePetCore/TerminalTarget.swift`. The part that actually spawns processes is in `Sources/ClaudePet/TerminalJump.swift`.

## Known limitations

- No Apple Developer signature. The installer strips the quarantine attribute and says so; Gatekeeper may still need a manual allow.
- Click-through is computed from two rectangles, not the figure's outline, so a few transparent pixels near the robot still swallow clicks.
- Roughly 4% CPU while idle — that is the breathing animation.

## License

MIT — see [LICENSE](LICENSE).
