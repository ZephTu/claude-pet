import Foundation

/// The one line a finished turn is remembered by: the first thing Claude said
/// in its last message, cut down to fit a row.
///
/// The pet used to know only THAT a turn ended. Whether it ended on "all tests
/// pass, PR opened" or on "I am stuck, which of these do you want?" is the
/// difference between needing to look and not, and the Stop hook hands over
/// the message that says which.
///
/// This is the one place the pet keeps any of Claude's words, so it keeps as
/// few as will do: a single line, stripped of formatting, clamped to `limit`.
/// Never the prompt, never the rest of the message.
public enum TurnSummary {
    public static let limit = 140

    public static func headline(_ message: String) -> String {
        var inFence = false
        for raw in message.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Code blocks say nothing a row can use, and their first line is
            // usually a shell prompt or an import.
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let line = plain(trimmed)
            // A table rule or a horizontal rule is all punctuation.
            guard line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return clamp(line)
        }
        return ""
    }

    /// Markdown down to the words: heading marks, list bullets, quote bars,
    /// emphasis and inline code ticks, and link targets.
    static func plain(_ line: String) -> String {
        var s = Substring(line)
        while let first = s.first, "#>".contains(first) { s = s.dropFirst() }
        s = s.drop { $0 == " " }
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            s = s.dropFirst(bullet.count)
        }
        // "1. " / "12) "
        if let end = s.firstIndex(where: { !$0.isNumber }), end != s.startIndex,
           s[end...].hasPrefix(". ") || s[end...].hasPrefix(") ") {
            s = s[s.index(end, offsetBy: 2)...]
        }
        // [label](target) → label
        let text = String(s)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                  options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clamp(_ line: String) -> String {
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
