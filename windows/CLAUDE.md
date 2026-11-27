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
  `hitRow`. Tray menu: show/hide, back to the corner, language, log, quit.
- Hooks in `settings.json` are written as `"$HOME/.claude/pet/pet-emit"` (quoted, forward
  slashes), assuming Claude Code on Windows runs hook commands through Git Bash. **Not verified
  on a real machine yet** — the first thing to check.
- Windows-only Swift: `ProcessProbeWindows.swift` (Toolhelp32 etc.) and `Portable.swift`
  (append with `FILE_APPEND_DATA`, `LockFileEx` locks, `MoveFileExW` replace with retries,
  `processExists`).

## Dev loop on Windows

```powershell
# Once: Swift 6.1.2 for Windows (with the VS Build Tools it asks for) and Node 20+.
swift build --product PetEmit                       # debug build: .build\debug\PetEmit.exe
powershell -ExecutionPolicy Bypass -File windows\scripts\smoke.ps1 (Resolve-Path .build\debug\PetEmit.exe)
cd windows; npm ci
$env:PET_EMIT = (Resolve-Path ..\.build\debug\PetEmit.exe).Path   # else ~\.claude\pet\pet-emit.exe
npx electron .
```

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

## Next on the real machine (in order)

1. Install the CI bundle (or a local build) and start a Claude Code session in Windows Terminal /
   PowerShell / Orca: does the hook run (sessions appear, the cat turns busy)? If hooks don't go
   through Git Bash, change `SettingsPatch.hookCommand` for Windows (keep upgrading the old forms
   via `legacyHookCommands`).
2. Permission prompts: held, shown on the pet, Allow/Deny from the panel reaches Claude Code.
3. Window behaviour: click-through outside the cat, drag, the panel, high-DPI scaling,
   several monitors, the taskbar on another edge, tray menu, install/uninstall/reinstall while a
   session runs.
4. Backlog, roughly by value: jump to the session's terminal (Windows Terminal, Orca, VS Code);
   finish notices and the hover detail card; start at login; scheduled jobs (`--run-job`, Task
   Scheduler); the HQ board on Windows (`hq` uses `fcntl` → `msvcrt`, `os.kill(pid, 0)`
   *kills* on Windows, Keychain → Credential Manager, a bundled Python).
