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
- The tray icon's menu is laid out as the Mac's: Task Board…; **Quick Note…**; **Take a Nap** / **Wake Up**
  (the cat sleeps with an empty list, no notices and no badge; what finished meanwhile is not
  announced when it wakes, a question that came up on the HQ board is); **Keep List Open**;
  Unmute All while something is muted; show / hide and back to the corner. Under **Settings**:
  launch at login, the two shortcuts (below), clicking a session opens (its terminal or its task),
  **Bubble Duration** (10 / 30 / 60 seconds) and **Bubbles at Once** (1–3) for finish notices,
  **Character** (Cat or Cultivator), language, **Connection Status…** and the log. The settings
  are kept across restarts; a nap is not, as on the Mac.
- **Shortcuts**, off until you tick them under tray → **Settings** (the Mac's ⌃⌥⌘N and ⌃⌥⌘J):
  - **Ctrl+Alt+N** opens the quick-note box (also tray → **Quick Note…**), on the screen the
    pointer is on. Enter files the note into the HQ inbox, Shift+Enter starts a new line, a
    pasted screenshot shows as a thumbnail (✕ takes it out), Esc closes. The cat then says
    where the note went, or that it waits in Needs you. A note that couldn't be filed comes
    back in the box.
  - **Ctrl+Alt+J** goes to the session that has waited on you longest (snoozed ones are
    skipped), where a click on it goes: its terminal or its task. With none, the cat says so.
  - A shortcut another app already holds stays unticked, and the cat says it is taken. On
    keyboard layouts where Ctrl+Alt is AltGr (Polish, say), AltGr+N / AltGr+J stop typing
    their character while it is on.
- **Connection Status…** checks what the pet depends on: Claude Code and its version, the
  hooks in `settings.json`, the last event, sessions running versus reporting, which terminals
  a row can jump to (and the last jump that failed), where the quota comes from, and the
  pet's state files. **Copy** puts a summary on the clipboard, with your home folder as `~`,
  to paste into an issue. When the install is broken (hooks missing, `pet-emit.exe` gone, or the
  pet's folder not writable), a ⚠ line at the top of the tray menu opens it, and the cat says
  so once.
- From the session list:
  - **Allow** or **Deny** a permission prompt.
  - Read finish notices and the **Finished** group.
  - See the questions waiting on the HQ board (the **Asks** group at the top; a click opens the
    board at that task). They count in the badge, and a new one pops a notice, "T-012 asks: …",
    for 25 seconds.
  - Snooze and mute sessions.
  - Rest the pointer on a row for its detail card.
- Each row shows what it does on the Mac: the HQ task it is bound to, how many turns it has had,
  its context (`210k·70%`), and "N in background" when commands it started are still running
  after its turn. A row is named by Claude Code's own name for the session (`/rename`), else its
  folder.
- Hover the cat to see your quota; the task board shows it too, on the right of its status bar. This needs a statusline that saves it, for example
  claude-hud with `display.externalUsageWritePath` set to
  `%USERPROFILE%\.claude\pet\hud-usage.json`.
- **The cat speaks up**, as on the Mac: when the 5-hour or weekly quota crosses a warning line
  (once per line per window, remembered across restarts) or is about to reset; when a session's
  context passes two thirds of its auto-compact threshold; when a session has failed four times
  in a row; when one has been working for over 20 minutes; and, after 10 minutes with no keyboard
  or mouse input, a one-line summary of what finished, what is waiting and how much quota went
  while you were away. It briefly strikes its "finished" pose when a turn ends and flashes a
  warning mark when a tool call fails. Napping, it does none of this. While a hover card is up
  its remarks wait (the away summary and the reactions still come), and so do the less urgent
  ones while the list is open.
- **Jump (↗) to a session's terminal:**
  - an **Orca** tab;
  - a **Windows Terminal** tab (the right tab among several);
  - a **console window** (PowerShell or cmd in the classic window; it is restored if
    minimized).

**The Task Board.** Double-click the cat, or use tray → **Task Board…**. All of these work as
on the Mac:

- Focus, Projects & duties, and Needs you.
- The board updates itself as things change: a card edited in a terminal, a question answered,
  a session starting, finishing or waiting on you.
- The task drawer, the session list, and Peek.
- Answering prompts from the board: Allow / Deny, **Answer…** for multiple-choice questions,
  and approving a plan or sending feedback on it.
- Starting and resuming sessions in three places:
  - **Windows Terminal** opens a new tab in it;
  - **Orca** opens a new Orca tab;
  - **Background** runs `claude --bg`.
- **Resume** goes back to a tab when it can, as on the Mac: in Orca, the tab Orca keeps the
  session in (switched to when it runs there; woken after an Orca restart, and Orca resumes
  the session there itself; at a shell prompt, it is typed in there), then a tab of the
  session's name at a shell prompt. A tab you opened yourself, where the session ended (Stop,
  `/exit`) and that still shows Claude Code's `claude --resume <id>` line above the prompt, is
  reused in Orca and in Windows Terminal alike. Tabs the board opens close with their session.
  Only failing all that does it open a new tab.
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
- **If the cat shows no sessions,** open tray → Settings → **Connection Status…** first.
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
