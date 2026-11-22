import Foundation

/// Finding a terminal tab a session can be resumed in, instead of opening a second one.
///
/// Orca and Terminal.app both keep their tabs across a restart, and Stop leaves the tab behind
/// at a shell prompt. Resume looks for such a tab — same title as the session, nothing running
/// in it — and types the resume command there. Every check here errs towards "busy": a tab that
/// might be running a program is never typed into; the board opens a new tab instead.
/// Pure and AppKit-free so it can be tested without either terminal.
public enum IdleTab {
    /// An Orca terminal (from `orca terminal list --json`) titled `title`, connected and writable,
    /// with no agent in it — neither by Orca's own `agentIdentity` nor by a live Claude Code
    /// session recorded there (`occupied` holds those handles) — whose last line is a shell prompt.
    public static func orca(terminals: [[String: Any]], title: String, occupied: Set<String>) -> String? {
        for t in terminals {
            guard let handle = t["handle"] as? String, !handle.isEmpty,
                  (t["title"] as? String) == title,
                  t["connected"] as? Bool == true, t["writable"] as? Bool == true,
                  t["orphaned"] as? Bool != true,
                  ((t["agentIdentity"] as? String) ?? "").isEmpty, !(t["agentIdentity"] is [String: Any]),
                  !occupied.contains(handle),
                  atShellPrompt(t["preview"] as? String ?? "") else { continue }
            return handle
        }
        return nil
    }

    /// Does the last non-empty line of a terminal's output look like an interactive shell
    /// waiting for a command? `%` (zsh), `$` (bash/sh), `#` (root), `❯` / `➜` (common themes).
    /// Claude Code's own screen also ends in `%` sometimes ("Context ▓▓░ 12%"), so lines with its
    /// box-drawing or bar characters never count, and neither do lines whose prompt character
    /// follows `=`/`-`/`#`/`(`, or a `%` that follows a digit — a progress bar ("100.0%"), a psql prompt
    /// ("postgres=#", "postgres-#"). A remote shell over ssh still looks like a prompt; that is
    /// the one case only the user can rule out.
    public static func atShellPrompt(_ preview: String) -> Bool {
        guard let last = preview.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }), last.count < 300 else { return false }
        let tui: Set<Character> = ["│", "█", "░", "▓", "╭", "╰", "─", "⏵", "✻", "⎿"]
        if last.contains(where: { tui.contains($0) }) || last.contains("Context") || last.contains("##") { return false }
        guard let end = last.last, ["%", "$", "#", "❯", "➜"].contains(end) else { return false }
        if let before = last.dropLast().last, "=-#(".contains(before) || (end == "%" && before.isNumber) { return false }
        return true
    }

    /// Lists every Terminal.app tab as `tty<TAB>custom title<TAB>busy<TAB>process,process…`.
    public static let terminalListScript = """
    set out to ""
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          set ttl to ""
          try
            set ttl to custom title of t
          end try
          set procs to ""
          try
            set AppleScript's text item delimiters to ","
            set procs to (processes of t) as text
            set AppleScript's text item delimiters to ""
          end try
          set out to out & (tty of t) & tab & ttl & tab & ((busy of t) as text) & tab & procs & linefeed
        end repeat
      end repeat
    end tell
    return out
    """

    /// The tty of a Terminal.app tab titled `title` that runs nothing but its shell, from
    /// `terminalListScript`'s output.
    public static func terminalApp(listing: String, title: String, occupied: Set<String>) -> String? {
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "login"]
        for row in listing.components(separatedBy: .newlines) {
            let f = row.components(separatedBy: "\t")
            guard f.count >= 4, f[1] == title, f[2] == "false", !occupied.contains(f[0]) else { continue }
            let procs = f[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let last = procs.last, shells.contains(last) else { continue }
            return f[0]
        }
        return nil
    }

    /// `s` as the inside of an AppleScript string literal.
    public static func appleScriptLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func inTab(_ tty: String, _ body: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(appleScriptLiteral(tty))" then
        \(body)
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    /// Runs a shell line in the Terminal.app tab on `tty` (which is at a prompt), optionally
    /// bringing it forward.
    public static func terminalRunScript(tty: String, line: String, focus: Bool) -> String {
        inTab(tty, """
                do script "\(appleScriptLiteral(line))" in t
        \(focus ? "        set selected of t to true\n        set index of w to 1\n        activate" : "")
        """)
    }

    /// Types `text` into the Terminal.app tab on `tty` and presses Return (a carriage return, as
    /// the key sends) — for a message to the Claude Code session running there.
    ///
    /// `do script` delivers everything in one write, and Claude Code takes a burst of text that
    /// ends in a Return as a paste, the Return becoming a newline in its input. So the text goes
    /// in as an explicit bracketed paste (`BoardSend.bracketedPaste`) and the carriage return
    /// after the end marker is read as the Return key. That carriage return is kept although
    /// `do script` adds a line ending of its own: which character Terminal adds is not
    /// documented, and a line feed is Ctrl+J — a newline, not a submit — in Claude Code. The
    /// extra ending lands after the submit, in an empty input: a carriage return there does
    /// nothing, a line feed at worst leaves an empty line — better than a message left unsent.
    /// `text` should have been through `BoardSend.typeable`.
    public static func terminalTypeScript(tty: String, text: String) -> String {
        inTab(tty, """
                do script (\(BoardSend.bracketedPaste(literal: appleScriptLiteral(text))) & return) in t
        """)
    }
}
