# Claude Pet on Windows — notes for agents working here

The Windows port (HQ task T-129) lives on branch `Zeph-Tu/t129-windows-spike`, draft PR #156.
It is a spike: it shows the pet and answers permission prompts; everything else is backlog.
The repo-root `CLAUDE.md` still applies; this file adds what is specific to Windows.

## How it fits together

- **pet-emit.exe** (Swift, `Sources/PetEmit`, built for Windows) is the Claude Code hook, as on
  the Mac: it writes `%USERPROFILE%\.claude\pet\sessions\*.json`, holds a `PermissionRequest`
  while a process named `ClaudePet` runs, and reads the answer from `pet\decisions\<session>.json`.
  It ignores payloads without `transcript_path`.
- `pet-emit --watch` (`PetWatch.swift`) runs the Mac's own aggregation (`ClaudePetCore`) and
  prints the pet's state as one JSON line per change. `pet-emit --decide <session> <ask>
  allow|deny` answers a held prompt.
- **The Electron shell** (`windows/main.js`, `preload.js`) shows the unchanged page from
  `Resources/pet` in a transparent always-on-top window, served over a `pet://` protocol, and
  feeds it each `--watch` line (`setMood`, `setCatLook`, `setPhase`, `setBadge`, `setSessions`).
  `preload.js` does what `PetHostView` does on the Mac: click-through outside the cat and the
  panel (`setIgnoreMouseEvents(true, {forward:true})`), drag to move, click to `togglePanel` /
  `hitRow`, rest on a row for its detail card. Tray menu: show/hide, back to the corner,
  language, launch at login (installed app only; a `ClaudePet` value under HKCU `...\Run`), log,
  quit.
- Finish notices: `--watch` puts `notices` (Chatter.doneNotices over the settled state, with the
  last reply's first line from `events/`) on the one line where a session finished; main.js calls
  `window.notify`; a click on one jumps to its terminal or opens the list. The rows themselves
  show the unsettled state, as on the Mac.
- The list's Finished group (`PetFinished.swift`, the Mac's CompletionStore over the same
  `events/` + `read.json`): `--watch` adds `finished` rows and counts them in the badge (the cat
  looks up while the badge shows, as on the Mac), marks a finish read once the user typed into
  that session, and ages `events/` out hourly. Clicks (✓, Clear, a finished row, a notice) run
  `pet-emit --mark-read --all | --session <id> | <event id>...`. A row click that jumps closes
  the list, as on the Mac.
- Snooze and mute (`PetMarks.swift`): the Mac keeps these marks in its defaults; here they are
  `pet\muted.json` (HiddenSessions marks, as seconds since 1970 so a mark never reads a fraction
  earlier than `lastPromptAt`) and `pet\snoozed.json` (Snooze.encode). `--watch` passes them to
  `StateAggregator.aggregate`, prunes them, adds `snoozedFor` to rows, leaves snoozed waits out of
  the badge, and reports `hidden` (the footer's "N muted", the tray's Unmute All). A row's ×
  runs `pet-emit --mute`, its clock pops a 5 / 15 / 30 minute menu that runs `--snooze`.
- Quota (`PetQuota.swift`, the Mac's sampleUsage on the watcher's tick, with `usage-seen.json`):
  `--watch` adds `quota` (Chatter.quotaRows) and `quotaFallback`; resting 1 s on the cat with the
  list closed calls `window.showQuota`. A reading comes from claude-hud's
  `display.externalUsageWritePath` = `%USERPROFILE%\.claude\pet\hud-usage.json` (what this
  machine uses), older claude-hud's `.usage-cache.json`, or `pet-emit --statusline`.
- main.js injects a thin scrollbar: Chromium's default on Windows is a wide grey bar.
- main.js skips a `setSessions` payload it just drew (as WebBridge), and after each redraw
  preload.js re-sends the pointer to `setHoverAt`: rows' ages change every second here, and a
  rebuild drops the hovered row's ↗ / clock / ×.
- Hover card: `preload.js` times the dwell (450 ms, as `updateDwell`), main.js runs
  `pet-emit --detail <session>` (`PetDetail.swift`: insight, transcript, context budget, last
  call, background shells — the Mac's `hoverDetail`) and hands the JSON to `window.showDetail`.
  It reads the whole transcript each time (~0.4 s for a long session, release build); the Mac
  caches. pet-emit gets the pet's language as `CLAUDE_PET_LANG`.
- Hooks in `settings.json` are written as `"$HOME/.claude/pet/pet-emit"` (quoted, forward
  slashes): Claude Code on Windows runs hook commands through Git Bash. Verified on a real
  machine (Claude Code 2.1.318) from Orca and Windows Terminal.
- Windows-only Swift: `ProcessProbeWindows.swift` (Toolhelp32 etc.) and `Portable.swift`
  (append with `FILE_APPEND_DATA`, `LockFileEx` locks, `MoveFileExW` replace with retries,
  `processExists`).
- Jump to the terminal (`Sources/PetEmit/WindowsJump.swift`): the hook records `orca` (as on the
  Mac), `wt` (`WT_SESSION`, no `TERM_PROGRAM`) or `console` (no terminal variables, and the
  session's console has a window). A row click runs `pet-emit --jump <session>`: Orca's CLI
  (`%LOCALAPPDATA%\Programs\orca\resources\bin\orca.exe terminal switch`) then raises Orca;
  otherwise it attaches to the session's console (`pid` = claude.exe). Under Windows Terminal the
  console window is a hidden ConPTY window *owned by* the WT window; the tab is found by setting
  the console title to a one-off mark, selecting the tab of that name through UI Automation
  (`Sources/PetUIA`, a C target that `Package.swift` declares on Windows only, because Swift's
  WinSDK module lacks UIAutomationClient.h), and putting the title back (only if the mark still
  shows; the mark is set again on every UIA try, since Claude Code animates its title while it
  works). conhost: the console window itself is raised. `wt` / `console` rows are clickable only
  when the session has a `pid` (Claude Code run by `node.exe` has none).

## Dev loop on Windows

```powershell
# Once: Swift 6.1.2 for Windows (with the VS Build Tools it asks for) and Node 20+.
swift build --product PetEmit
# The exe is in .build\x86_64-unknown-windows-msvc\debug (.build\debug is only a symlink to it,
# and SwiftPM can't create it without Developer Mode).
$bin = '.build\x86_64-unknown-windows-msvc\debug'
powershell -ExecutionPolicy Bypass -File windows\scripts\smoke.ps1 (Resolve-Path $bin\PetEmit.exe)
$env:PET_EMIT = (Resolve-Path $bin\PetEmit.exe).Path   # else ~\.claude\pet\pet-emit.exe
cd windows; npm ci
npx electron .
```

- `npx electron .` (and a `PET_SHOT` render) exits at once, silently, while the installed pet
  runs: both share `%APPDATA%\ClaudePet` and so the single-instance lock. Quit it from the tray
  first.

- `PET_HOME=<dir>` points both pet-emit and the shell at a scratch folder instead of
  `~\.claude\pet` (write fake `sessions\*.json` there to stage a state).
- `PET_SHOT=out.png` (plus `PET_SHOT_JS="window.togglePanel()"`, `PET_SHOT_DELAY=ms`) renders the
  window to a PNG and quits; read the PNG to check layout.
- The shell's log: `%APPDATA%\ClaudePet\pet.log` (tray → Open the log).
- To try it as the user will: `npx electron-builder --win dir --x64 --publish never`, then
  `install.ps1` from a folder laid out like the CI bundle (`pet-emit\` with the exe and Swift
  runtime DLLs, `app\` = `dist\win-unpacked`). `uninstall.ps1` undoes it.
- `.github/workflows/windows.yml` builds, smoke-tests (with only the bundle's DLLs on PATH),
  packages, renders a PNG, and uploads `ClaudePet-windows`. Keep it green.

## Rules

- **The Mac must not change.** Windows code goes behind `#if os(Windows)` /
  `#if !canImport(Darwin)`; Mac code paths stay byte-for-byte the same. The Mac tests
  (`swift run ClaudePetTests`, `hq/tests/test_hq.sh`) can't run here: the macOS CI job runs them
  on every push — wait for it to be green, and say in the PR when a change touches shared code.
- Before every push: `gh pr view 156 --json state` — the user merges fast; never push to a
  merged branch. If the user wants it merged, they merge; you don't.
- After a meaningful batch, have a subagent review the diff; report findings to the user (no
  GitHub comments) and fix them all on the same PR.
- Reply to the user in Chinese; code, comments, commits and the PR stay in English.
- UI changes or big features: show a clickable prototype first, code after the user agrees.
- HQ is not installed on this machine. Record progress in commit messages and the PR
  description (keep its "what works / what doesn't / next" up to date); the user carries it to
  the T-129 card on the Mac.
- Don't touch README / the HQ guide yet (the user said so for the spike).

## Gotchas already hit

- On Windows, WinSDK's `BOOL` imports as Swift `Bool` (no `.boolValue`).
- Windows Foundation lacks `FileManager.replaceItemAt` (it traps) and `memmem`: use
  `Portable.replaceItem` and a manual scan.
- A file another process has open can be renamed but not overwritten or deleted: hence the
  rename-with-retries and install.ps1's `.old-N` fallback.
- Windows PowerShell 5.1 reads a BOM-less script as ANSI: keep `.ps1` files ASCII (use
  `[char]0x4f60` for non-ASCII).
- Every hook payload in tests needs `transcript_path`, or pet-emit ignores it.
- `STILL_ACTIVE` (259) from `GetExitCodeProcess` means alive.
- A shell started before the Swift install (Claude Code's own, say) lacks the toolchain on
  PATH: reload it from the registry (Machine + User `Path`, User `SDKROOT`). A freshly built
  `PetEmit.exe` run from Git Bash also needs `%LOCALAPPDATA%\Programs\Swift\Runtimes\6.1.2\usr\bin`
  on PATH.
- electron-builder fails unpacking `winCodeSign` without symlink rights (darwin `.dylib`
  links). Turn on Developer Mode, or unpack the downloaded `.7z` yourself with
  `node_modules\7zip-bin\win\x64\7za.exe` into
  `%LOCALAPPDATA%\electron-builder\Cache\winCodeSign\winCodeSign-2.6.0` (the two link errors
  are harmless).
- `FileHandle.nullDevice` as a child's stdout/stderr breaks the child on Windows Foundation
  (Orca's CLI printed nothing at all): give it a `Pipe` and read it.
- `AttachConsole` swaps a process's standard handles for the console's unless it was started
  with its own: the hook saves and restores all three around it (`WindowsJump.withConsole`),
  or a held prompt's answer would miss Claude Code's pipe.
- `preload.js` must forward pointer moves to `window.setHoverAt` (as `PetHostView` does): a
  row's ↗ shows only on hover, so without it nothing looks clickable.
- A Windows Terminal started *from* an Orca terminal (`wt.exe` typed there) inherits
  `TERM_PROGRAM=Orca` and `ORCA_TERMINAL_HANDLE`: its sessions are recorded as that Orca tab.
  Start test windows from the Start menu, not from a shell inside Orca.
- A debug `PetEmit.exe` is ~10x slower than release at scanning a transcript (`--detail` took
  3 s): time things with the release build.
- `PET_SHOT_JS` can drive preload.js: a `MouseEvent` dispatched on `window` from the page reaches
  its listeners (how the hover card was checked without a mouse).
- To see a PermissionRequest, the test session must be in the default permission mode
  (`claude --permission-mode default`): in `auto` mode the classifier approves the command and
  no prompt (so no hook) happens. Writes to `/tmp` are allowed without asking too.

## Verified on a real machine (Windows 11, two 2560x1440 screens at 150%)

1. Hooks run (Orca and Windows Terminal): sessions appear, the cat turns busy. Orca sessions
   record `terminal.kind = orca`; Windows Terminal ones record no terminal yet.
2. Permission prompts: held, shown on the pet; Allow / Deny from the panel reach Claude Code
   ("Denied by PermissionRequest hook", reason "The user denied this from Claude Pet").
3. Window behaviour: sharp at 150%, click-through beside the cat and the open panel, drag,
   click to open / close the panel, dragging to the second screen, tray menu. Reinstalling while
   a session runs: pet-emit.exe was overwritten in place.

4. `uninstall.ps1` with a session running: removes only our hooks (the user's Orca hooks stay),
   the app, the binaries and the data folders; reinstall restores them.
5. Jump to the terminal from the panel: Orca, Windows Terminal (the right tab of several),
   a conhost PowerShell window (restored from minimized).

Not checked yet on the machine (built, smoke-tested or rendered only): launch at login; finish
notices (and clicking one); the hover card; the Finished group, its ✓ / Clear and row clicks,
scrolling the list with the wheel; snooze (the menu) and mute, Unmute All; the quota readout
with a real claude-hud reading; the taskbar on another edge.

## Next

Backlog, roughly by value: jump to VS Code's terminal; the cat's chatter (quota warnings,
context-long notes: Chatter.next / QuotaAlarm); scheduled jobs (`--run-job`, Task Scheduler); the HQ board on Windows (`hq` uses `fcntl` → `msvcrt`, `os.kill(pid, 0)`
*kills* on Windows, Keychain → Credential Manager, a bundled Python).
