# Claude Pet on Windows — notes for agents working here

The Windows port (HQ task T-129, PR #156). The pet and the Task Board run on Windows; what is
still Mac only is listed in `docs/windows.md` (the user-facing doc, with `docs/windows.zh-CN.md`).
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
  `hitRow`, rest on a row for its detail card. Tray menu (laid out as PetMenu):
  Task Board, nap, Keep List Open, Unmute All, show/hide, back to the corner, and Settings: launch
  at login (installed app only; a `ClaudePet` value under HKCU `...\Run`), click target, bubble
  duration / count, character, language, log; quit.
- The Mac's menu settings are prefs.json keys: `keepListOpen` (main.js sends `pinned` to
  preload.js, which then puts the list up instead of toggling it; `closePanel` is WebBridge's, a
  no-op while pinned), `noticeHoldSeconds` (overrides `--watch`'s `holdMs`), `noticeCount`
  (`window.setMaxNotices` on every page load), `skin` (`index.html?skin=<id>`, a reload, as
  PetPanel.setSkin; a skin missing one of the nine stills is greyed out; the tray icon follows
  it). The nap (`paused`, in memory only, as on the Mac): `--watch` keeps running and `last`
  stays current, but `draw` shows the fixed `NAP` state, the board's dots are empty (as the Mac's
  petDots), and notices are skipped, so waking does not replay them; no quota on dwell. A skin
  switch reloads the page: `loadPetPage` puts click-through back and drops a pending hover card.
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
  list closed calls `window.showQuota`. `usage` (the Mac's BoardBridge.usage, only while the
  reading is usable) goes to the board's "pet" read for the status bar's meters. A reading comes from claude-hud's
  `display.externalUsageWritePath` = `%USERPROFILE%\.claude\pet\hud-usage.json` (what this
  machine uses), older claude-hud's `.usage-cache.json`, or `pet-emit --statusline`.
- The cat speaking up (`PetChatter.swift`, the Mac's maybeSpeak / noticeReturn /
  noticeTransients on the watcher's tick): `--watch` adds `say` (`{text, emphasis, variant,
  holdMs}`: Chatter.next with the QuotaAlarm decision and the ContextAlarm's due session over
  PetRows' context readings) and `flash` (`{kind, pose, mark}`, as WebBridge.flash) only on the
  line where they happen; main.js calls `window.say` / `window.flash` (a line that arrives before
  the page is in is said on did-finish-load, while its hold lasts). What the Mac reads off its
  own window main.js writes to `--watch`'s stdin, one change per line (`list 1`, `card 0`,
  `nap 1`, all three again when `--watch` restarts): the list open (the page's layout report has
  a `panel`), a hover card or the quota up (`cardUp`), the nap. Recorded only when said, as on
  the Mac: quota thresholds in `pet\quota-said.json` (the Mac's `quotaThresholdsSaid` default),
  the rest in memory. Away and back: `GetLastInputInfo` (idle for AwayReport.awayAfter, then
  input), finishes counted from `events/`. Names in the lines (and in the finish notices) are
  the rows' names.
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
- The rows' extras (`PetRows.swift`, the Mac's TranscriptCache / readContext / TaskIndex /
  findBackgroundShells): turns and context from the transcript (only what was appended, opened
  with full sharing so Claude Code keeps writing, at most 64 MB a tick; a row shows them once
  its transcript was read to the end: a 250 MB one takes ~4 s after the pet starts), the HQ task and status from hq's files every 8 s, the count
  of commands an idle session left running (BackgroundShells), and Claude Code's name for the
  session (`~\.claude\sessions\<pid>.json` `name`) as the Mac's tab title. `context*` and
  `background` are dot fields, so the board's rows get them too.
- Windows-only Swift: `ProcessProbeWindows.swift` (Toolhelp32; a process's command line through
  ntdll's NtQueryInformationProcess, split by the C runtime's rules, so BackgroundShells and
  startedToolShell work as on the Mac) and `Portable.swift`
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
- HQ (`hq/`, Python, shared with the Mac) runs on Windows: `hq/install.sh` from Git Bash (Claude
  Code runs hooks and the slash commands' `~/.claude/hq/bin/hq` there too). On Windows the
  installer finds a real Python 3.9+ (`py -3`, `python`; `python3` is usually the Store's
  stand-in), installs the entry as `bin/hq.py` and writes `bin/hq` as a sh script that runs it
  with `-X utf8` (the code page here is GBK) and `USERPROFILE=$HOME` (python reads USERPROFILE,
  bash and the tests set HOME). `hqlib/compat.py`: `fcntl.flock` over `msvcrt.locking` (hq locks
  only empty `.lock` files) and `win_pid_alive` (OpenProcess). `atomic_write` retries a replace
  that a reader blocks. The user's task root here is `C:\Users\28332\claude-hq`, separate from
  the Mac's. pet-emit records `transcript` for a `C:\` path too (it only took `/`-paths), so hq
  finds a live session's transcript.
- The HQ board (tray → "Task Board..."): `openBoard` in main.js shows the unchanged
  `Resources/pet/board/board.html` in an ordinary window (bounds kept in prefs.json `board`).
  `board-preload.js` plays `window.webkit.messageHandlers.hq` (a promise per message, rejecting
  with the error, as WKScriptMessageHandlerWithReply) and `PET_LANG`; `ipcMain.handle("hq")`
  takes only the board window's main frame on `pet://app/`. `board.js` is BoardWindow.perform:
  the same `hq` argument lists (runs `bin/hq.py` with the Python named in `bin/hq`), the shared
  reads of SharedReads, copy / openURL / openPath / open / pick-folder / saveImage / jump
  (`pet-emit --jump`). What the Mac keeps in its defaults (BoardPrefs, BoardSeen, BoardPhrases)
  and the reading area are `pet-emit --board` (`PetBoard.swift`, `pet\board.json`, over
  QuickPhrases / SeenCards / DocReader; DocReader takes `C:\` paths on Windows). `jobs` is
  empty; the secretary and jobs answer "not on Windows yet". The board window gets no push
  (BoardEvents): the page polls; phones get one (below).
  Renders: `PET_SHOT_BOARD=1` shoots the board window (`=T-123`: opened at that task);
  `PET_HQ_HOME=<dir>` points board.js (and the hq it runs, as USERPROFILE) at a scratch home
  with its own `hq/install.sh`.
- Prompts on the board: the `pet` read's `dots` are the `--watch` rows filtered by
  WebBridge.dotKeys (PetWatch.row already carries BoardPrompt.dotFields). `prompt`, `decide`,
  `answer-question`, `plan-feedback` are `pet-emit --board` ops (PetBoard): each re-reads the
  session file and answers only while a pet-emit holds that very ask (askAnswerable, same id and
  kind), writing `decisions\<session>.json` as the Mac's `answer` does.
- Starting sessions (`launch`, `resume`, `attach`, board.js `openInTerminal`): the page's
  "Terminal" place is Windows Terminal (`wt.exe -w 0 new-tab --title … -- <cmd>`), "Orca" is
  `orca terminal create --shell powershell.exe --command "<cmd>; exit"`, "Background" is
  `claude --bg` (and `agents` is `claude agents --json`, `stop` is `claude stop`). `<cmd>` is
  `powershell -EncodedCommand <base64>` that starts claude through ProcessStartInfo with an exact
  command line (`winArg`): nothing passes through wt's `;` splitting, a shell's quoting or
  PowerShell 5.1's native-argument quote mangling; checked with quotes, curly quotes, `;`, line
  breaks, trailing backslashes and Chinese through both terminals. A script whose base64 passes
  8000 characters (a long prompt) goes in a temp `.ps1` the stub reads and deletes (a command
  line stops at 32767). claude must be an `.exe` (`findClaude`): npm's `claude.cmd` would run
  through cmd.exe, which re-parses the line (`&`, `%VAR%` in a title would run or expand), and
  Node refuses to execFile a `.cmd`. The tab and `claude` get `CLAUDE_ENV` (no CLAUDECODE etc.,
  but the user's CLAUDE_CODE_* settings kept). With `--focus`, `pet-emit --raise-orca` brings Orca
  forward.
- Resume going back to a tab (`PetResume.swift`, `pet-emit --board` ops; board.js `resumeInOrca`
  / `resumeInWT` type the new tab's line without `; exit`: the tab's shell may be cmd):
  `resume-orca` is the Mac's resumeInOrcaPlace (OrcaPlace over `orca agent show`, `terminal
  list`, `worktree activate`; the woken tab's WakeWatch is `resume-orca-watch`, which board.js
  runs in the background when staying on the board) and then the Orca half of resumeInIdleTab.
  Between them, a Windows step: a tab whose screen ends at a prompt under Claude Code's exit line
  `claude --resume <id>` (`IdleTab.endedHere`) - after an exit Orca drops the agent's place
  (`places: []`), the pet deletes the session's record, and pwsh takes the tab's title back, so
  nothing else finds it. `resume-wt` does that for Windows Terminal: shells (`pwsh`,
  `powershell`, `cmd`, `bash`) right under WindowsTerminal.exe with no child process (Git Bash's
  `Git\bin\bash.exe` is a launcher: its one inner bash is the shell), alone on their console
  (`GetConsoleProcessList`: a `start /b` program is no child but shares it), their screen read by
  attaching (`WindowsJump.screen`), the line typed with `WindowsJump.type`, the tab selected as a
  jump does. A send that may have gone in (Orca's CLI ended at its timeout, a partial console
  write) is an error, never a fallback to a new tab; so is `agent show` timing out. `IdleTab.atShellPrompt` takes `PS D:\x>` and `D:\x>` on Windows only.
  An Orca terminal of a workspace not open in Orca's sidebar is `orphaned` (skipped) or missing
  from `terminal list`; the place logic then wakes its workspace.
- Phone access (`remote.js`, BoardServer + RemoteAccess + Tailnet ported to Node): the board's
  `remote*` ops go to it (board.js `configure({remote})`). A `net` server on `::` (dual stack,
  `pauseOnConnect`) decides on the peer's address before a byte is read (`admission`: private,
  or public IPv6 on a non-tunnel adapter's /64; or a Tailscale address while Tailscale is on —
  also any peer that arrived on this PC's own Tailscale address (a subnet router keeps far
  private sources) — then `tailscale whois --json` from
  `%ProgramFiles%\Tailscale\tailscale.exe` must name this PC's own untagged user), then hands
  the socket to an `http` server. That server never listens, so its own timeouts never run:
  `accept` holds each connection to 60 s until its request is in (not `/events`), every answer
  is `Connection: close` (each request is let in afresh, as on the Mac), a refusal cuts off a
  body it never read, 100-continue waits for the token check, and `stop()` / Tailscale off end
  every open socket. Same Host / Origin checks, SHA-256 token hashes, lockout, code
  cancellation, ETag / gzip, `X-HQ-Have` "same" answers, phone-op allow list (`PHONE_OPS`;
  test/remote.test.js checks every board.js op is on it or on `PC_ONLY`). `POST /api` runs
  board.js `handle(body, null)` (`skip` from `pet\board.json`'s shared prefs); served pages get
  `HQ_REMOTE`, `PET_LANG` and `PET_OS = "windows"`: the page's `TM()` strings (the ones naming
  the computer, never user text) then say "PC" / "电脑" for "Mac".
  Switches and devices are prefs.json `boardServerEnabled`, `boardServerTailnet`,
  `boardServerDevices` (ISO dates), `boardServerPort`. QR codes: the `qrcode` package (a runtime
  dependency, packed into app.asar). `POST /events` (SSE) is fed by `board-events.js`:
  `fs.watch` recursive over the HQ root, `~\.claude\hq` and the pet's folder, BoardPush.relevant
  and PushGate ported, dropping board.js's kept `board` / `sessions` / `status` reads first
  (not `agents`: each phone's refresh would start a Claude Code). Checked on this machine over
  loopback, the LAN address and this PC's own Tailscale address (whois of itself); not yet from a
  real phone.
- The cat opens the board: a double click toggles it (preload.js puts the list back as the
  first click found it, as WebBridge.handleDoubleClick; "in front" = focused, or lost focus in
  the last 1.5 s); tray → "Clicking a Session Opens" (prefs.json `clickTarget`, the board's
  setting writes the same) sends a click on a row or notice bound to a task (hq's
  `state\sessions.json`) to the board at that task, as ClickTarget.route.
- Typing into a session from the board (`send`, `interrupt`, `plan-approve`, `stop-session`):
  `pet-emit --board` ops in `PetControl.swift`, BoardBridge's checks over the same core
  (BoardSend, SessionControl, ClaudeSessionStatus; the recorded pid must still be Claude Code,
  older than the last hook, and on that session per `~\.claude\sessions\<pid>.json`). Orca: its
  CLI, as on the Mac. `wt` / `console`: `WindowsJump.type` attaches to the session's console and
  writes key events into `CONIN$` (not the std handle: pet-emit's stdin is the board's pipe) -
  the text as a bracketed paste (`ESC[200~ … ESC[201~` typed as characters: Claude Code takes it
  as text, no `@` / `/` menu; a long one shows as a paste, as on the Mac), then Enter on its own
  after BoardSend.returnDelay; text in but no Enter is `unsure`. While attached, pet-emit ignores
  the console's Ctrl+C events. Orca's CLI is given 10 s (then `unsure`). Stop is Ctrl+C as a key,
  twice, up to two rounds (no SIGTERM here). The page's
  SENDABLE / INTERRUPTIBLE list `wt` and `console` (the Mac never records them). board.js keeps
  approvedPlans and continues background sessions (`sendBackground`: `claude stop`, then
  `claude --bg --resume <id> <text>`). Checked with real Claude Code in Windows Terminal and Orca
  (message, plan approval, Esc, stop) and with a raw-mode stand-in in conhost.
  `CLAUDE_ENV` also drops `CLAUDE_CODE_CHILD_SESSION` (inherited, it turns the new session's
  transcript off), the other per-session `CLAUDE_CODE_*` markers, `ORCA_*` and `TERM_PROGRAM`.
  The tab's stub drops the same from claude's environment, except `ORCA_*` / `TERM_PROGRAM` in an
  Orca tab: there they are the new tab's own, and without them the hook records no terminal (the
  board can't message or jump to the session).

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
  first, or add `--user-data-dir=<scratch dir>` (its own lock and prefs.json: stage settings such
  as `skin` or `keepListOpen` by writing that prefs.json first).

- `PET_HOME=<dir>` points both pet-emit and the shell at a scratch folder instead of
  `~\.claude\pet` (write fake `sessions\*.json` there to stage a state).
- `node --test test/remote.test.js` (in `windows`): phone access's checks and its server on a
  loopback port (CI runs it).
- `ELECTRON_RUN_AS_NODE=1 npx electron scripts/serve-board.js 18790 [--tailnet]`: phone access
  alone (the Mac's `--serve-board`), its prefs in a temp file, printing a pairing link.
  `npx electron <full path>\scripts\render-url.js out.png [390x844] "<url>"` renders a page as a
  phone's browser does (`RENDER_JS` runs first). Stop serve-board by its electron.exe process:
  stopping the shell that started it leaves it holding the port.
- `PET_SHOT=out.png` (plus `PET_SHOT_JS="window.togglePanel()"`, `PET_SHOT_DELAY=ms`) renders the
  window to a PNG and quits; read the PNG to check layout.
- The shell's log: `%APPDATA%\ClaudePet\pet.log` (tray → Open the log).
- **Installing on this machine: `powershell -ExecutionPolicy Bypass -File
  windows\scripts\install-local.ps1`** (the user's choice: always this, not CI's artifact). It
  does what CI does - release pet-emit plus the Swift runtime DLLs, smoke.ps1 with only the
  bundle's DLLs on PATH, `node --test test/remote.test.js`, electron-builder (`npx --no-install`:
  the pinned one), the bundle laid out as CI's (`pet-emit\`, `app\`) - then runs the bundle's
  `install.ps1`. One run at a time (`ClaudePet-build\run.lock`).
  It refuses a checkout missing commits on origin/main, as `scripts/check-main.sh` does on the Mac
  (`-Force` exists; don't use it on the user's behalf). The app is built in
  `%LOCALAPPDATA%\ClaudePet-build`, a copy of `windows\` and `Resources\pet` with its own
  node_modules: `npm ci` in the checkout deletes `windows\node_modules` first, and a dev electron
  another session runs from it holds files open (EBUSY halfway leaves it gutted - `electron`
  down to `dist\`). `uninstall.ps1` undoes an install.
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
- HQ on this machine has its own task root (`C:\Users\28332\claude-hq`, separate from the
  Mac's); the port's card here is T-030. The T-129 card lives on the Mac: the user carries
  progress there.
- Docs: a change to what works on Windows updates `docs/windows.md` and `docs/windows.zh-CN.md`,
  and the guide's "On Windows" / "Windows 版" sections when the board is concerned (the
  repo-root rule on keeping the guide in sync applies to Windows too).

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
- Electron 33 on Windows exits at once with 127 when an `http://` argument is followed by another
  argument (render-url.js takes the URL last). `electron -e …` isn't supported: it shows an
  "Error launching app" dialog on the user's screen. Git Bash's `timeout` can't run `npx` (127).
- A test client must send a body with `Content-Length`: Node's default chunked body is refused
  (400), as on the Mac.
- `PET_SHOT_JS` can drive preload.js: a `MouseEvent` dispatched on `window` from the page reaches
  its listeners (how the hover card was checked without a mouse).
- `hq/tests/test_hq.sh` runs in Git Bash (`py` on PATH): 587 pass, 68 fail, every one from the
  test side, not hq: paths compared as `C:/...` strings where hq answers `C:\...`, fake `claude`
  / `gh` / `security` written as sh scripts (python on Windows can't run them: WinError 193), and
  symlinks (Git Bash copies). It takes ~5 minutes. Not in Windows CI yet.
- Windows PowerShell 5.1's `Start-Process -PassThru` reports an empty `ExitCode` after
  `WaitForExit(ms)` unless `.Handle` was read right after the start.
- Python's `os.kill(pid, 0)` on Windows sends CTRL_C_EVENT (0) to the process group, and `$$`
  in Git Bash is an MSYS pid (`/proc/$$/winpid` is the Windows one).
- Electron started with `USERPROFILE` pointed elsewhere dies at once ("Failed to get 'userData'
  path", in a dialog on the user's screen): use `PET_HQ_HOME` for a scratch hq instead.
- A Windows checkout (`core.autocrlf`) gave the `.sh` scripts CRLF, which bash can't run:
  `.gitattributes` keeps them LF.
- A test claude started from this shell (Claude Code's own, inside Orca) inherits
  `CLAUDE_CODE_CHILD_SESSION` (no transcript, no `~\.claude\sessions` file) and `TERM_PROGRAM=Orca`:
  strip them first. To see what a session's tab shows, read its console screen
  (AttachConsole + ReadConsoleOutputCharacterW on `CONOUT$`); a node copy named `claude.exe`
  passes ProcessProbe.isClaude as a stand-in.
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
notices (and clicking one); the cat speaking up with real sessions (the away-and-back line,
the flashes; quota, context-long and struggling lines were checked against a scratch
`PET_HOME`); the hover card; the Finished group, its ✓ / Clear and row clicks,
scrolling the list with the wheel; snooze (the menu) and mute, Unmute All; the quota readout
with a real claude-hud reading; the taskbar on another edge.

## Next

The HQ board on Windows is done (hq, the board window, prompts, starting / resuming sessions,
typing into them, the cat opening the board; `/hq-onboard` was run on this machine). Later or
never: scheduled jobs (`--run-job`, Task Scheduler),
the secretary, feeds and autoclose (Keychain → Credential Manager), intake
(its `start_new_session` is ignored on Windows: a job's end would not spare the session).

Other backlog: jump to VS Code's terminal.
