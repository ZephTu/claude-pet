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

    /// …with one kind of shell added: one that is plainly a wait. Claude often
    /// ends a turn on "the build is queued, I'll check once it has a number",
    /// leaving a shell that sleeps or polls until then — and its finishing wakes
    /// the session for the next round. Counted on the pet since 2026-11-21: 82
    /// turns started that way, 55 of their shells described as "Wait …"; one
    /// release run flashed "done" five times. A dev server or a watcher left for
    /// the afternoon is not described or written like this, so it still counts
    /// as finished. Read from the description and command only to decide this —
    /// neither is kept (see `Task.label`).
    static func isWait(description: String, command: String) -> Bool {
        let d = description.trimmingCharacters(in: .whitespaces)
        if d.range(of: #"^(wait|waiting|poll|polling|watch for|check (again|back|once))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if d.hasPrefix("等") { return true }
        // `sleep 600 && check`, `until …; do sleep 30; done`, `while …; sleep …`
        return command.range(of: #"\bsleep\s+\d"#, options: .regularExpression) != nil
    }

    /// The label a waiting shell goes by: it has no structural name of its own.
    public static let shellLabel = "shell"

    /// How long a waiting shell may hold a session's finish. A wait that never
    /// returns must not hide the finish forever — that is the one failure this
    /// project cares about most — so past this the session counts as idle.
    public static let shellWaitLimit: TimeInterval = 20 * 60

    public struct Task: Sendable, Equatable {
        public let id: String
        public let type: String
        public let status: String
        /// A structural name — the agent type or the workflow name — never the
        /// free-text description or the shell command, both of which carry
        /// whatever the user was working on. See `ActivitySummary` for the same
        /// rule applied to tool calls.
        public let label: String

        /// A shell that is waiting for something this turn is to pick up.
        public let waits: Bool

        public init(id: String, type: String, status: String, label: String, waits: Bool = false) {
            self.id = id
            self.type = type
            self.status = status
            self.label = label
            self.waits = waits
        }

        public var wakesSession: Bool { wakingTypes.contains(type) || waits }
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
            let waits = type == "shell" && isWait(description: row["description"] as? String ?? "",
                                                  command: row["command"] as? String ?? "")
            return Task(
                id: row["id"] as? String ?? "",
                type: type,
                status: row["status"] as? String ?? "",
                label: waits ? shellLabel : label(type: type, row: row),
                waits: waits)
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
        if !labels.isEmpty, labels.allSatisfy({ $0 == shellLabel }) {
            return labels.count == 1 ? L("waiting for a background command", "在等后台命令")
                : L("waiting for \(labels.count) background commands", "在等 \(labels.count) 个后台命令")
        }
        switch labels.count {
        case 0: return ""
        case 1: return L("waiting for \(labels[0])", "在等 \(labels[0])")
        default: return L("waiting for \(labels.count) background agents", "在等 \(labels.count) 个后台 agent")
        }
    }
}
