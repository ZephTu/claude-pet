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
