import ClaudePetCore
import Foundation

/// Resume reuses a tab only when it is surely idle: same title, at a shell prompt, nobody in it.
enum IdleTabTests {
    static func run(_ t: Harness) {
        print("\n-- idle tabs (Resume reuses one instead of opening another)")

        t.check("a zsh prompt is a shell prompt", IdleTab.atShellPrompt("Last login: Sat\nzhefu@mac smart-agent % "))
        t.check("a bash prompt is a shell prompt", IdleTab.atShellPrompt("bash-5.2$ \n\n"))
        t.check("a themed prompt is a shell prompt", IdleTab.atShellPrompt("~/code on main ❯"))
        t.check("Claude Code's context bar is not", !IdleTab.atShellPrompt("  Context ▓▓░░░ 12%"))
        t.check("Claude Code's box is not", !IdleTab.atShellPrompt("╰──────────────────╯"))
        t.check("program output is not", !IdleTab.atShellPrompt("Compiling ClaudePet\nBuilding..."))
        t.check("an empty screen is not", !IdleTab.atShellPrompt("\n  \n"))
        t.check("a progress bar ending in % is not", !IdleTab.atShellPrompt("######## 100.0%"))
        t.check("a download percentage is not", !IdleTab.atShellPrompt("Downloading 42%"))
        t.check("a psql prompt is not", !IdleTab.atShellPrompt("postgres=#") && !IdleTab.atShellPrompt("postgres-#"))
        t.check("a root prompt still is", IdleTab.atShellPrompt("root@box:~# "))
        t.check("a macOS bash prompt still is", IdleTab.atShellPrompt("Mac:~ zhefu$ "))

        let idle: [String: Any] = ["handle": "term_a", "title": "T-071 claude-pet", "connected": true,
                                   "writable": true, "orphaned": false, "preview": "x % "]
        t.check("an idle Orca tab with the session's title is reused",
                IdleTab.orca(terminals: [idle], title: "T-071 claude-pet", occupied: []) == "term_a")
        t.check("a differently titled Orca tab is not",
                IdleTab.orca(terminals: [idle], title: "T-072 other", occupied: []) == nil)
        t.check("an Orca tab a live session is recorded in is not",
                IdleTab.orca(terminals: [idle], title: "T-071 claude-pet", occupied: ["term_a"]) == nil)
        var gone = idle; gone["orphaned"] = true
        var off = idle; off["connected"] = false
        var busy = idle; busy["preview"] = "Context ▓▓░ 40%"
        t.check("an orphaned, disconnected or busy Orca tab is not",
                IdleTab.orca(terminals: [gone, off, busy], title: "T-071 claude-pet", occupied: []) == nil)
        var agent = idle; agent["agentIdentity"] = "claude"
        t.check("an Orca tab Orca says has an agent in it is not",
                IdleTab.orca(terminals: [agent], title: "T-071 claude-pet", occupied: []) == nil)
        var noAgent = idle; noAgent["agentIdentity"] = NSNull()
        t.check("an Orca tab with a null agentIdentity is still idle",
                IdleTab.orca(terminals: [noAgent], title: "T-071 claude-pet", occupied: []) == "term_a")
        var other = idle; other["handle"] = "term_b"
        t.check("the first usable Orca tab wins",
                IdleTab.orca(terminals: [busy, other], title: "T-071 claude-pet", occupied: []) == "term_b")

        let listing = """
        /dev/ttys001\tT-071 claude-pet\ttrue\tlogin,-zsh,claude
        /dev/ttys002\tT-071 claude-pet\tfalse\tlogin,-zsh
        /dev/ttys003\tT-072 other\tfalse\tlogin,-zsh
        """
        t.check("an idle Terminal.app tab with the title is reused, a busy one skipped",
                IdleTab.terminalApp(listing: listing, title: "T-071 claude-pet", occupied: []) == "/dev/ttys002")
        t.check("a Terminal.app tab a live session is recorded in is not",
                IdleTab.terminalApp(listing: listing, title: "T-071 claude-pet", occupied: ["/dev/ttys002"]) == nil)
        t.check("a tab running something other than a shell is not",
                IdleTab.terminalApp(listing: "/dev/ttys004\tT\tfalse\tlogin,-zsh,vim", title: "T", occupied: []) == nil)
        t.check("a short row is ignored",
                IdleTab.terminalApp(listing: "/dev/ttys004\tT", title: "T", occupied: []) == nil)

        t.check("AppleScript literals escape quotes and backslashes",
                IdleTab.appleScriptLiteral(#"a "b" \c"#) == #"a \"b\" \\c"#)
        t.check("AppleScript literals cannot break a line",
                !IdleTab.appleScriptLiteral("a\nb\rc").contains(where: { $0 == "\n" || $0 == "\r" }))
        let typed = IdleTab.terminalTypeScript(tty: "/dev/ttys002", text: "say \"hi\"")
        let marked = #"(character id 27) & "[200~" & "say \"hi\"" & (character id 27) & "[201~""#
        t.check("Terminal: the tab is found by tty", typed.contains(#"if tty of t is "/dev/ttys002""#))
        t.check("Terminal: the text goes in as a bracketed paste, then the Return key",
                typed.contains("do script (\(marked) & return) in t"))
        t.check("Terminal: the paste markers are built outside the quoted literal",
                !typed.contains("\u{1B}") && typed.components(separatedBy: "character id 27").count == 3)
        let it = TerminalTarget.iTermTypeScript(uuid: "ABCD-1234", text: "say \"hi\" there")
        t.check("iTerm2: the text goes in as a bracketed paste, quoted, without a newline",
                it.contains(#"write text ((character id 27) & "[200~" & "say \"hi\" there" & (character id 27) & "[201~") newline no"#))
        t.check("iTerm2: Return goes in as its own write, a moment later, so it is not part of a paste",
                it.contains("delay 0.30") && it.contains("write text (character id 13) newline no")
                    && it.range(of: "[201~")!.lowerBound < it.range(of: "delay 0.30")!.lowerBound
                    && it.range(of: "delay 0.30")!.lowerBound < it.range(of: "character id 13")!.lowerBound)
        t.check("iTerm2: the session is found by its uuid", it.contains(#"contains "ABCD-1234""#))
        t.check("iTerm2: a long text waits longer before its Return",
                TerminalTarget.iTermTypeScript(uuid: "A", text: String(repeating: "x", count: 10_000)).contains("delay 0.80"))

        // What the board types: one line, nothing a terminal would act on.
        t.check("typeable: lines are joined with spaces", BoardSend.typeable("a\nb\r\nc") == "a b  c")
        t.check("typeable: ESC, ^C, ^D, NUL, BEL and DEL are removed",
                BoardSend.typeable("a\u{1B}[201~b\u{03}\u{04}\u{00}\u{07}c\u{7F}d") == "a[201~bcd")
        t.check("typeable: a tab is kept", BoardSend.typeable("a\tb") == "a\tb")
        t.check("typeable: ordinary and non-ASCII text is untouched",
                BoardSend.typeable("Fix it — 改一下 \"now\" 🙂") == "Fix it — 改一下 \"now\" 🙂")
        t.check("typeable: a message of nothing but control characters is empty",
                BoardSend.typeable("\u{1B}\u{03}").isEmpty)
        t.check("an injected end marker cannot close the paste early",
                !TerminalTarget.iTermTypeScript(uuid: "A", text: BoardSend.typeable("x\u{1B}[201~\ry")).contains("\u{1B}"))
        t.check("a prompt starts a turn the board can watch for", BoardSend.startsTurn("fix the tests"))
        t.check("a slash command or a ! line does not",
                !BoardSend.startsTurn("/compact") && !BoardSend.startsTurn("!git status"))
        t.check("the Return delay is 0.3 s for a short message", BoardSend.returnDelay(characters: 40) < 0.31)
        t.check("the Return delay grows about 1 s per 20k characters",
                abs(BoardSend.returnDelay(characters: 20_000) - 1.3) < 0.001)
        t.check("the Return delay stops at 1.5 s", BoardSend.returnDelay(characters: 1_000_000) == 1.5)
        t.check("the Return delay is an AppleScript number", BoardSend.returnDelayLiteral(characters: 5_000) == "0.55")
        t.check("a session waiting on a prompt is not typed into",
                BoardSend.refuses(state: .waiting) && !BoardSend.refuses(state: .busy)
                    && !BoardSend.refuses(state: .idle) && !BoardSend.refuses(state: nil))
        t.check("Esc goes only to a session mid-turn",
                BoardSend.mayInterrupt(state: .busy) && BoardSend.mayInterrupt(state: .waiting)
                    && !BoardSend.mayInterrupt(state: .idle) && !BoardSend.mayInterrupt(state: nil))
        t.check("…and not once Claude Code itself says the turn is over (a second Esc would open its rewind menu)",
                !BoardSend.mayInterrupt(state: .busy, claudeStatus: "idle")
                    && BoardSend.mayInterrupt(state: .busy, claudeStatus: "busy"))
        let escScript = TerminalTarget.iTermEscapeScript(uuid: "ABCD-1234")
        t.check("iTerm2's Esc is one ESC byte with no newline, to the session named",
                escScript.contains("write text (character id 27) newline no") && escScript.contains("\"ABCD-1234\"")
                    && !escScript.contains("character id 13"))
        t.check("the escape is the ESC byte", BoardSend.escape.unicodeScalars.map(\.value) == [27])
        t.check("/model alone opens a menu; with a name it doesn't",
                BoardSend.opensMenu("/model") && BoardSend.opensMenu(" /Model ")
                    && !BoardSend.opensMenu("/model opus") && !BoardSend.opensMenu("/compact"))
        let run = IdleTab.terminalRunScript(tty: "/dev/ttys002", line: "cd '/x' && claude", focus: false)
        t.check("running a line without focus does not activate Terminal",
                run.contains("do script") && !run.contains("activate"))
        t.check("running a line with focus brings the tab forward",
                IdleTab.terminalRunScript(tty: "/dev/ttys002", line: "ls", focus: true).contains("set selected of t to true"))
    }
}
