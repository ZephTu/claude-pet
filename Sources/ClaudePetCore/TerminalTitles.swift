import Foundation

/// Parsing for the terminal-tab titles that name a session.
///
/// The panel shows a project, which is just the directory's name — and three
/// sessions open in the same directory all render as the same word. The tab
/// title is the thing that actually distinguishes them ("customer-a regression triage"
/// vs "20260916-email reply"), so it is what the pet shows on hover.
///
/// Claude Code does not record a session name anywhere of its own: its
/// transcripts carry no summary record and there is no metadata file beside
/// them. The terminal is the only place this name exists, which is why this has
/// to go out and ask the terminal for it.
public enum TerminalTitles {
    /// Pulls handle → title out of `orca terminal list --json`.
    ///
    /// Returns an empty map for anything unexpected. This is another app's CLI
    /// contract, so a changed shape must degrade to "no titles on hover" rather
    /// than to an error the user cannot act on.
    public static func parseOrca(_ stdout: Data) -> [String: String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let terminals = result["terminals"] as? [[String: Any]]
        else { return [:] }

        var titles: [String: String] = [:]
        for terminal in terminals {
            guard
                let handle = terminal["handle"] as? String,
                let title = terminal["title"] as? String
            else { continue }
            let cleaned = clean(title)
            if !cleaned.isEmpty { titles[handle] = cleaned }
        }
        return titles
    }

    /// Parses the tab-separated `id<TAB>title` lines the iTerm2 AppleScript
    /// prints, one per session.
    public static func parseITerm(_ stdout: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let id = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let title = clean(String(parts[1]))
            if !id.isEmpty, !title.isEmpty { titles[id] = title }
        }
        return titles
    }

    /// A title the user would not learn anything from is worse than none: it
    /// costs a hover and a bubble to say "Terminal 1".
    public static func isUseless(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        // Default names from the terminals themselves.
        if t.hasPrefix("Terminal ") || t == "Terminal" { return true }
        if t == "bash" || t == "zsh" || t == "login" { return true }
        return false
    }

    /// Strips the leading activity glyph terminals prepend (✳, ◐ and friends)
    /// plus surrounding whitespace. The pet already shows that state with its
    /// own dot, and the glyph animates, so keeping it would make the same
    /// session look like it renamed itself every second.
    static func clean(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespaces)
        let markers: Set<Character> = ["✳", "◐", "◓", "◑", "◒", "·", "✻", "✽", "*"]
        while let first = s.first, markers.contains(first) || first.isWhitespace {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The AppleScript that lists every iTerm2 session's id and its tab title.
    /// A session has no title of its own in iTerm2's dictionary — the tab does —
    /// so this pairs each session id with its containing tab's title.
    public static let iTermListScript = """
    set out to ""
    tell application "iTerm2"
      repeat with w in windows
        repeat with t in tabs of w
          set tabTitle to ""
          try
            set tabTitle to title of t
          end try
          repeat with s in sessions of t
            set out to out & (id of s as text) & tab & tabTitle & linefeed
          end repeat
        end repeat
      end repeat
    end tell
    return out
    """
}
