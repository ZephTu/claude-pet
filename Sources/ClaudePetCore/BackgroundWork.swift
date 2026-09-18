import Foundation

/// Work a session parked in the background, and whether it means the turn
/// ending is a finish or only a pause.
///
/// `Stop` fires when Claude stops TALKING, which is not the same as the work
/// being over. A session that dispatched a background agent and then said "it's
/// running, I'll report back" ends its turn immediately — and the pet, reading
/// Stop as a finish, put a red dot on it. The user walked over to a session that
/// had done nothing yet.
///
/// Claude Code sends the answer in the Stop payload. Its own description of the
/// field (2.1.274) says what it is for:
///
///     "background_tasks": [ { id, type, status, description,
///                             command?, agent_type?, server?, tool?, name? } ]
///     In-flight background work (running/pending + backgrounded) registered in
///     this session. Lets hooks distinguish "session is done" from "session is
///     paused waiting for background work to wake it". Empty array when nothing
///     is in flight.
///
/// `type` is a friendly label — 'shell', 'subagent', 'monitor', 'workflow' —
/// falling back to the raw discriminant for kinds that do not exist yet.
public enum BackgroundWork {
    /// The kinds that mean "not finished".
    ///
    /// Deliberately NOT every in-flight task. A backgrounded shell is as often a
    /// dev server the user parked for the afternoon as it is work this turn
    /// depends on, and treating it as unfinished would silence the finish notice
    /// for that session for the rest of the day — the one failure this project
    /// cares about most. The same goes for an armed monitor.
    ///
    /// This list is exactly what Claude Code itself counts when its REPL prints
    /// "Waiting for N background agents to finish" instead of "Done in Ns", so
    /// the pet agrees with the terminal the user is looking at.
    public static let wakingTypes: Set<String> = ["subagent", "workflow"]

    public struct Task: Sendable, Equatable {
        public let id: String
        public let type: String
        public let status: String
        /// A structural name — the agent type or the workflow name — never the
        /// free-text description or the shell command, both of which carry
        /// whatever the user was working on. See `ActivitySummary` for the same
        /// rule applied to tool calls.
        public let label: String

        public init(id: String, type: String, status: String, label: String) {
            self.id = id
            self.type = type
            self.status = status
            self.label = label
        }

        public var wakesSession: Bool { wakingTypes.contains(type) }
    }

    /// Reads the raw `background_tasks` value out of a hook payload.
    ///
    /// Absent decodes to empty, which is the pre-2.1 behaviour: every Stop is a
    /// finish. That is the right fallback — an older Claude Code has no
    /// background agents to be confused by.
    public static func parse(_ raw: Any?) -> [Task] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let type = (row["type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty else { return nil }
            return Task(
                id: row["id"] as? String ?? "",
                type: type,
                status: row["status"] as? String ?? "",
                label: label(type: type, row: row))
        }
    }

    static func label(type: String, row: [String: Any]) -> String {
        let structural = (row["agent_type"] as? String)
            ?? (row["name"] as? String)
            ?? (row["tool"] as? String)
            ?? ""
        let trimmed = structural.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? type : trimmed
    }

    /// The subset that will produce another turn on its own.
    public static func waking(_ tasks: [Task]) -> [Task] {
        tasks.filter(\.wakesSession)
    }

    /// What the session row says while it waits.
    ///
    /// Named after what the user sees in their own terminal — "Waiting for 1
    /// background agent to finish" — rather than inventing a second vocabulary
    /// for the same thing.
    public static func phrase(_ labels: [String]) -> String {
        switch labels.count {
        case 0: return ""
        case 1: return "waiting for \(labels[0])"
        default: return "waiting for \(labels.count) background agents"
        }
    }
}
