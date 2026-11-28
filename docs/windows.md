# Claude Pet on Windows

**English** · [中文](windows.zh-CN.md)

The same cat and the same Task Board as on the Mac, on Windows 10 / 11 (x64). The page is the
Mac's, shown in a small Electron app; the hook (`pet-emit.exe`) and HQ are the same code, built
for Windows. Some board features are still Mac only. See [Not on Windows yet](#not-on-windows-yet).

## Install

You need:

- Windows 10 or 11, x64.
- [Claude Code](https://claude.com/claude-code) from its native installer, so `claude.exe` is
  on your PATH (see [Good to know](#good-to-know) for npm's `claude.cmd`).
- Git for Windows. Claude Code needs its Git Bash anyway, and runs hooks in it.
- For the Task Board, Python 3.9+ from python.org, or `winget install Python.Python.3.12`. The
  Microsoft Store stand-in that `python3` opens doesn't count.

No administrator rights are needed.

**1. Get the bundle.** CI builds it on every push to `main` and keeps it for 90 days as the
artifact `ClaudePet-windows`. Download it from the latest green run of the **Windows** workflow
on GitHub's Actions page (signed in), or with `gh`:

```powershell
$id = gh run list --repo ZephTu/claude-pet --workflow windows.yml --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId'
gh run download $id --repo ZephTu/claude-pet -n ClaudePet-windows -D ClaudePet-windows
```

**2. Install the pet.** In PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File ClaudePet-windows\install.ps1
```

The installer does three things, then starts the cat:

- It copies `pet-emit.exe`, and the Swift runtime DLLs it needs, to `%USERPROFILE%\.claude\pet`.
- It appends the pet's hooks to `%USERPROFILE%\.claude\settings.json`. The file is backed up
  first, and your own settings and hooks are kept.
- It installs the app to `%LOCALAPPDATA%\Programs\ClaudePet`, with a Start menu shortcut.

The app isn't signed, so SmartScreen may warn the first time. Choose **More info → Run anyway**.
The installer has already removed the "downloaded from the internet" mark from every file in
the bundle.

**3. Install the Task Board (optional).** Open Git Bash in a clone of this repo and run the
same command as on the Mac:

```bash
hq/install.sh --root ~/claude-hq
```

It lists every change it will make and asks first. On Windows it also does two things:

- It finds a real Python (`py -3`, then `python`).
- It writes `~/.claude/hq/bin/hq` as a small sh script that runs `hq.py` in UTF-8, so Chinese
  and other text survives the console's code page.

Your task root is local to this machine. A Mac and a PC keep separate boards.

**4. Restart the sessions you want to see.** Hooks load when a session starts.

**Uninstall:** run `uninstall.ps1` from the bundle. It removes only the pet's hooks, the app,
the binaries and the pet's data folders. For the board, run `hq/uninstall.sh` in Git Bash; your
task cards are kept.

## What works

**The pet**

- The cat sits in the corner of the screen, always on top. Clicks beside it go through to the
  window underneath, and you can drag the cat to another screen.
- The tray icon's menu is laid out as the Mac's: Task Board…; **Take a Nap** / **Wake Up**
  (the cat sleeps with an empty list, no notices and no badge; what finished meanwhile is not
  announced when it wakes); **Keep List Open**; Unmute All while something is muted; show / hide
  and back to the corner. Under **Settings**: launch at login, clicking a session opens (its
  terminal or its task), **Bubble Duration** (10 / 30 / 60 seconds) and **Bubbles at Once**
  (1–3) for finish notices, **Character** (Cat or Cultivator), language, and the log. The
  settings are kept across restarts; a nap is not, as on the Mac.
- From the session list:
  - **Allow** or **Deny** a permission prompt.
  - Read finish notices and the **Finished** group.
  - Snooze and mute sessions.
  - Rest the pointer on a row for its detail card.
- Each row shows what it does on the Mac: the HQ task it is bound to, how many turns it has had,
  its context (`210k·70%`), and "N in background" when commands it started are still running
  after its turn. A row is named by Claude Code's own name for the session (`/rename`), else its
  folder.
- Hover the cat to see your quota; the task board shows it too, on the right of its status bar. This needs a statusline that saves it, for example
  claude-hud with `display.externalUsageWritePath` set to
  `%USERPROFILE%\.claude\pet\hud-usage.json`.
- **Jump (↗) to a session's terminal:**
  - an **Orca** tab;
  - a **Windows Terminal** tab (the right tab among several);
  - a **console window** (PowerShell or cmd in the classic window; it is restored if
    minimized).

**The Task Board.** Double-click the cat, or use tray → **Task Board…**. All of these work as
on the Mac:

- Focus, Projects & duties, and Needs you.
- The task drawer, the session list, and Peek.
- Answering prompts from the board: Allow / Deny, **Answer…** for multiple-choice questions,
  and approving a plan or sending feedback on it.
- Starting and resuming sessions in three places:
  - **Windows Terminal** opens a new tab in it;
  - **Orca** opens a new Orca tab;
  - **Background** runs `claude --bg`.
- Typing into a session: messages, **Esc** to interrupt, and **■** to stop.
  - These work in Windows Terminal, console windows and Orca.
  - A background session gets your message between turns; the board continues it.
  - The text arrives as a paste, so a `/` or `@` in it opens no menu.
  - The tab doesn't have to be in front.
- `/task`, `/board` and `/hq-onboard` in any session.

**Phone access.** The board on your phone's browser, as on the Mac. Turn it on in the board's
**Settings (⚙) → Phone access**, press **Pair a phone** and scan the QR code. Paired phones can
be removed there.

- **On the same Wi-Fi.** The pet listens on port 8790 and lists this PC's addresses on the local
  network. The first time, Windows Firewall asks whether ClaudePet may accept connections: allow
  it on **Private networks**. If Windows has your home Wi-Fi as a Public network, the phone can't
  connect: set that Wi-Fi to Private (Settings → Network & internet → Wi-Fi → its properties).
  Don't allow Public networks: then anyone on a café's Wi-Fi could reach the board's door.
- **Away from home, over Tailscale.** With Tailscale on both the PC and the phone, logged in as
  the same user, also tick **Also over Tailscale**. Then press **Pair over Tailscale** and pair
  once more. The address is the PC's Tailscale name, for example
  `http://my-pc.tailxxxx.ts.net:8790`. Only devices of the PC's own Tailscale user get in. On a
  company tailnet, colleagues' devices and tagged servers are turned away even when they can
  reach the PC.
- Another port: set `"boardServerPort": 8791` in `%APPDATA%\ClaudePet\prefs.json`, then turn
  phone access off and on.

## Not on Windows yet

- **The secretary** and **Scheduled jobs.** The board answers "not on Windows yet".
- **Feeds** (Zulip, Jira) and **ticking finished todos.** Their credentials live in the macOS
  Keychain.
- **The quick-note shortcut** (⌃⌥⌘N).
- **The cat's remarks**, such as quota warnings and "this context is getting long".
- **Resume** always opens a new tab. It doesn't reuse an idle one.
- **VS Code's terminal**: sessions there get no ↗.

## Good to know

- **Use the native `claude.exe`, not npm's `claude.cmd`.** The board starts sessions only with
  `claude.exe`. A `.cmd` runs through cmd.exe, which would read `&` and `%…%` in a title or a
  prompt as its own syntax. A session that runs under `node.exe` (an npm install) records no
  Claude Code process, so its row can't jump or take messages.
- **A Windows Terminal started from inside Orca** (`wt` typed in an Orca terminal) inherits
  Orca's variables. Its sessions then show as that Orca tab. Start Windows Terminal from the
  Start menu instead.
- **Restart sessions** that were already open when you installed.
- **If the cat doesn't start, or the board doesn't open,** the log is at
  `%APPDATA%\ClaudePet\pet.log` (tray → the log).

## Building from source

You need Swift 6.1.2 for Windows (with the Visual Studio Build Tools it asks for) and
Node 20+. The build steps, the dev loop and how each piece maps to the Mac's code are in
[windows/CLAUDE.md](../windows/CLAUDE.md).

To build this checkout and install it in one go (instead of downloading the bundle), run
`powershell -ExecutionPolicy Bypass -File windows\scripts\install-local.ps1`. It builds
what CI builds, runs CI's checks and then the bundle's `install.ps1`. It refuses a checkout that
is missing commits on `origin/main`.
