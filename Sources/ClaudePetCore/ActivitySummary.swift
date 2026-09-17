import Foundation

/// Turns a tool call into a phrase short enough for a panel row.
///
/// Separate from `PermissionSummary`, and the difference is the point.
/// `PermissionSummary` describes something the user is about to approve, so it
/// must show the command as it really is — a redacted `rm -rf` is worse than
/// useless when the question is whether to allow it. This one describes what
/// already ran, it is written to disk and kept for a day, and nobody needs the
/// full text to recognise it. So it keeps to what a tool call structurally IS,
/// and never carries an argument it did not deliberately choose to carry.
public enum ActivitySummary {
    public static let maxLength = 40

    /// The object of the call: a file name, a host, a program. Empty when the
    /// tool takes nothing worth naming.
    public static func target(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return safeCommand(toolInput["command"] as? String ?? "")
        case "Edit", "Write", "NotebookEdit", "Read":
            return lastComponent(toolInput["file_path"] as? String ?? "")
        case "Glob", "Grep":
            // The pattern is the user's own text and can be long; the path it
            // was run against says more about where the session is working.
            return lastComponent(toolInput["path"] as? String ?? "")
        case "WebFetch":
            return host(of: toolInput["url"] as? String ?? "")
        case "Task":
            return clamp(toolInput["subagent_type"] as? String ?? "")
        default:
            return ""
        }
    }

    /// A phrase for one call: "Read PetLayout.swift", "Bash npm test".
    public static func phrase(toolName: String, target: String) -> String {
        guard !toolName.isEmpty else { return target }
        return target.isEmpty ? toolName : clamp(toolName + " " + target)
    }

    /// What to show when several calls are in flight at once.
    public static func concurrent(_ count: Int) -> String {
        count > 1 ? "\(count) tools running" : ""
    }

    /// A shell command reduced to the part that identifies it.
    ///
    /// Allow-listed by structure rather than scrubbed by pattern: the program
    /// name, plus following words only until something arrives that could be a
    /// value — a flag, an assignment, a quoted string, a pipe. A denylist of
    /// "password|token|secret" only removes the secrets somebody thought to
    /// name, and this string is written to disk and kept for a day.
    ///
    /// `npm test` and `git status` survive intact, which covers most of what is
    /// worth recognising; `curl -H "Authorization: Bearer …"` becomes `curl …`.
    public static func safeCommand(_ command: String) -> String {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let program = words.first else { return "" }

        var kept = [lastComponent(program)]
        for word in words.dropFirst() {
            guard let safe = keepable(word) else {
                kept.append("…")
                break
            }
            kept.append(safe)
            if kept.count >= 3 { break }
        }
        return clamp(kept.joined(separator: " "))
    }

    /// The form of `word` that is safe to keep, or nil to stop here.
    ///
    /// A long path is kept as its last component rather than dropped. `cd
    /// /Users/me/Documents/Code_Projects/claude-pet` used to summarise to
    /// `cd …` — technically safe and practically useless. The basename says
    /// which directory without saying where it lives.
    static func keepable(_ word: String) -> String? {
        if isPlainWord(word) { return word }
        guard word.contains("/") else { return nil }
        let name = lastComponent(word)
        return isPlainWord(name) ? name : nil
    }

    /// A bare word: letters, digits and the punctuation that shows up in
    /// subcommands and paths. Anything else — a flag, an `=`, a quote, a
    /// redirect, a pipe — might be carrying a value.
    static func isPlainWord(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= 24 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        guard word.allSatisfy({ allowed.contains($0) }) else { return false }
        // A leading dash is a flag, and a flag's next word is usually its value.
        return !word.hasPrefix("-")
    }

    static func clamp(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }

    static func lastComponent(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? clamp(urlString)
    }
}
