import Foundation

/// The decisions behind the board's Stop and its messages to background sessions, kept pure so
/// they can be tested without a running Claude Code. Every unclear case comes out as "don't":
/// a process that might be another session is not signalled, and a session that might be
/// mid-turn is not interrupted.
public enum SessionControl {
    /// The session a running Claude Code process is on now, from its own
    /// `~/.claude/sessions/<pid>.json`. That file follows /clear (the same process moves to a
    /// new session) and is rewritten by whichever process holds the pid, so it answers both
    /// "which session is this process" and "is this pid still the one we recorded".
    public static func currentSession(sessionsFile data: Data?) -> String? {
        guard let data, let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = doc["sessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    public static func currentSession(pid: Int32) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions/\(pid).json")
        return currentSession(sessionsFile: try? Data(contentsOf: file))
    }

    /// May the Claude Code process `pid` (already known to be Claude Code) be treated as
    /// `session`? Its sessions file decides when there is one. Without it, a command line that
    /// names a different session says no; one that names none leaves the pet's record to decide.
    /// `arguments` is the process's command line as one string.
    public static func processIsSession(_ session: String, sessionsFile: Data?, arguments: String?) -> Bool {
        if let current = currentSession(sessionsFile: sessionsFile) { return current == session }
        if let args = arguments, args.contains("--session-id") || args.contains("--resume") {
            return args.contains(session)
        }
        return true
    }

    /// What `claude agents --json` says about one session.
    public enum Listing: Equatable {
        /// The command failed or printed something unreadable — nothing is known.
        case unknown
        /// It ran, and the session is not among the running ones.
        case absent
        case running(status: String)
    }

    public static func listing(exitStatus: Int32, output: String, session: String) -> Listing {
        guard exitStatus == 0, let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return .unknown }
        guard let row = rows.first(where: { ($0["sessionId"] as? String) == session }) else { return .absent }
        return .running(status: ((row["status"] as? String) ?? (row["state"] as? String) ?? "").lowercased())
    }

    /// Only a session that says it is idle is between turns. "waiting" is a turn held open by a
    /// permission prompt or a question; stopping it there would throw that turn away.
    public static func betweenTurns(_ status: String) -> Bool { status.lowercased() == "idle" }
}
