import Foundation

/// Turns a `PermissionRequest` hook payload into the one short phrase the pet
/// can show in its bubble.
///
/// The point is to answer "should I go deal with this?" without going to deal
/// with it. "api-server needs you" costs a context switch to act on; "api-server:
/// rm -rf build/" usually does not.
///
/// This also replaces a genuinely fragile check. Waiting used to be inferred
/// from the text of a `Notification` message — `contains("waiting for your
/// input")` — which depends on Claude Code's English copy staying byte-identical
/// forever, and fails silently the day it does not. `PermissionRequest` is a
/// structured event and cannot rot that way.
public enum PermissionSummary {
    /// Longest phrase worth putting in a 170pt bubble. Past this it is truncated
    /// with an ellipsis: the goal is recognition, not reading.
    public static let maxLength = 48

    /// - Parameters:
    ///   - toolName: the hook's `tool_name`.
    ///   - toolInput: the hook's `tool_input`, whose shape is tool-specific.
    /// A tool whose permission prompt IS the question: the user answers by
    /// picking options on the card, and Claude Code passes the picks on as the
    /// tool's input. Allowing it from outside hands over no picks at all —
    /// Claude Code itself marks these "one-tap Approve/Deny must not be
    /// offered" — so the pet treats them as a question to go and answer. The
    /// board answers it with the picks (`PermissionDecision.Answer.answers`).
    public static func isQuestion(toolName: String) -> Bool {
        toolName == "AskUserQuestion"
    }

    /// ExitPlanMode: a plan to approve. Claude Code ignores a hook's "allow" for it
    /// (measured 2026-11-24: the dialog stays up), so it is no permission the pet can
    /// grant — the board approves it with the Enter key, and sends a "keep planning"
    /// as a denial carrying the user's feedback, which Claude Code does honour.
    public static func isPlan(toolName: String) -> Bool {
        toolName == "ExitPlanMode"
    }

    /// The `askKind` a PermissionRequest for this tool is: "question", "plan", or "" for a
    /// permission.
    public static func askKind(toolName: String) -> String {
        isQuestion(toolName: toolName) ? "question" : isPlan(toolName: toolName) ? "plan" : ""
    }

    /// The longest plan kept in the session file for the board, in characters.
    public static let planLimit = 40_000

    /// "2 questions to answer": what a question prompt says in its row, without
    /// repeating any of the questions themselves.
    public static func questionNote(toolInput: [String: Any]) -> String {
        let n = (toolInput["questions"] as? [Any])?.count ?? 0
        return n > 1 ? "\(n) questions to answer" : "a question to answer"
    }

    /// What a plan prompt says in its row.
    public static let planNote = "a plan to approve"

    public static func describe(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            // The command is what the user is actually deciding about.
            if let command = toolInput["command"] as? String {
                return clamp(collapse(command))
            }
        case "Edit", "Write", "NotebookEdit":
            // A full path eats the bubble; the file name is what identifies it.
            if let path = toolInput["file_path"] as? String {
                return clamp(toolName + " " + lastComponent(path))
            }
        case "Read":
            if let path = toolInput["file_path"] as? String {
                return clamp("Read " + lastComponent(path))
            }
        case "WebFetch":
            if let url = toolInput["url"] as? String {
                return clamp("WebFetch " + host(of: url))
            }
        default:
            break
        }
        // Any tool whose shape we do not special-case still names itself, which
        // beats "needs you" even without the argument.
        return clamp(toolName.isEmpty ? "permission" : toolName)
    }

    /// Longest text `full` returns. Past this a person is not reading it on a board either.
    public static let fullMaxLength = 2000

    /// Everything the prompt would allow, for a place with room to show it (the board's Approve
    /// box): the whole command as written, the whole path or URL, and for any other tool its
    /// name and arguments. Nothing is collapsed or shortened below `fullMaxLength`.
    public static func full(toolName: String, toolInput: [String: Any]) -> String {
        var text: String
        switch toolName {
        case "Bash" where toolInput["command"] is String:
            text = toolInput["command"] as! String
        case "Edit", "Write", "NotebookEdit", "Read":
            text = toolName + " " + ((toolInput["file_path"] as? String) ?? (toolInput["notebook_path"] as? String) ?? "")
        case "WebFetch" where toolInput["url"] is String:
            text = "WebFetch " + (toolInput["url"] as! String)
        default:
            let args = (try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            text = (toolName.isEmpty ? "permission" : toolName) + (args.isEmpty || args == "{}" ? "" : " " + args)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > fullMaxLength ? String(text.prefix(fullMaxLength - 1)) + "…" : text
    }

    /// Collapses whitespace so a multi-line heredoc does not become a
    /// multi-line bubble.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clamp(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }

    static func lastComponent(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }
}
