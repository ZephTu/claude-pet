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
        t.check("typing into a tab finds it by tty and presses Return",
                typed.contains(#"if tty of t is "/dev/ttys002""#) && typed.contains(#"("say \"hi\"" & return)"#))
        let it = TerminalTarget.iTermTypeScript(uuid: "ABCD-1234", text: "say \"hi\"\nthere")
        t.check("iTerm2: the text goes in without a newline, quoted and on one line",
                it.contains(#"write text "say \"hi\" there" newline no"#))
        t.check("iTerm2: Return goes in as its own write, a moment later, so it is not part of a paste",
                it.contains("delay 0.3") && it.contains("write text (character id 13) newline no")
                    && it.range(of: "newline no")!.lowerBound < it.range(of: "character id 13")!.lowerBound)
        t.check("iTerm2: the session is found by its uuid", it.contains(#"contains "ABCD-1234""#))
        let run = IdleTab.terminalRunScript(tty: "/dev/ttys002", line: "cd '/x' && claude", focus: false)
        t.check("running a line without focus does not activate Terminal",
                run.contains("do script") && !run.contains("activate"))
        t.check("running a line with focus brings the tab forward",
                IdleTab.terminalRunScript(tty: "/dev/ttys002", line: "ls", focus: true).contains("set selected of t to true"))
    }
}
