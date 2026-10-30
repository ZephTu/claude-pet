import Foundation

/// Claude Code's own account of what a session is doing, from the file it keeps
/// for each running process at `~/.claude/sessions/<pid>.json`.
///
/// Some waits end without a single hook. A dialog Claude Code opens for a slash
/// command — /auto-mode-setup's proposal, say — sends a Notification typed
/// `permission_prompt` when it appears and nothing at all when the user
/// answers it, so the row went on saying "Awaiting reply" until the next
/// prompt. Claude Code rewrites `status` the moment the dialog closes, which
/// makes this file the one place that end is written down.
///
/// It is another program's private file, so anything unexpected reads as "no
/// reading" and the pet falls back to what the hooks said.
public enum ClaudeSessionStatus {
    public struct Reading: Sendable, Equatable {
        /// "busy", "idle" or "waiting".
        public let status: String
        public let at: Date

        public init(status: String, at: Date) {
            self.status = status
            self.at = at
        }
    }

    /// Nil when the file belongs to another session — a reused pid, or /clear
    /// starting a new one in the same process — or carries no status.
    public static func parse(_ data: Data, sessionId: String) -> Reading? {
        guard
            let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            doc["sessionId"] as? String == sessionId,
            let status = doc["status"] as? String, !status.isEmpty,
            let ms = doc["statusUpdatedAt"] as? Double
        else { return nil }
        return Reading(status: status, at: Date(timeIntervalSince1970: ms / 1000))
    }

    public static func read(pid: Int32, sessionId: String) -> Reading? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parse(data, sessionId: sessionId)
    }
}
