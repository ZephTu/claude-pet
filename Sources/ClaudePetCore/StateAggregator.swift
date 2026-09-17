import Foundation

/// Collapses N session states into the one mood the pet shows.
/// Pure: `now` is injected so timeout behaviour is testable.
public enum StateAggregator {
    /// Fallback timeout, used ONLY for state files that carry no pid — ones
    /// written by a pet-emit older than process-based liveness. Sessions that do
    /// carry a pid ignore this entirely and stay listed for as long as their
    /// process is running, however long they sit idle.
    public static let deadAfter: TimeInterval = 900

    /// How long a session may sit in `waiting` before the pet escalates.
    public static let urgentAfter: TimeInterval = 60

    /// Is this session still running?
    ///
    /// Asking the kernel beats watching the clock: a session sitting at a prompt
    /// with nobody typing produces no hooks at all, so judging by `updatedAt`
    /// made open sessions disappear from the panel after fifteen minutes. A
    /// closed terminal, meanwhile, takes its process with it and is detected
    /// immediately instead of after the timeout.
    public static func isLive(_ s: SessionState, now: Date) -> Bool {
        guard let pid = s.pid else {
            // No pid recorded: an older state file, so the clock is all we have.
            return now.timeIntervalSince(s.updatedAt) <= deadAfter
        }
        return ProcessProbe.isRunning(pid: pid, named: ProcessProbe.claudeProcessName)
    }

    /// `isLive` is injectable so tests can decide liveness without spawning
    /// processes; the default asks the kernel.
    /// - Parameter hidden: sessionId → mute mark. Muted sessions are removed
    ///   before anything else happens, so they affect neither the list nor the
    ///   pet's mood: a muted session stuck on a permission prompt must not leave
    ///   the pet waving at something the user cannot see in the panel.
    /// - Parameter snoozed: sessionId → postponement. A snoozed session stays in
    ///   the list — the user asked to be reminded later, not to forget — but it
    ///   does not drive the mood, so the pet stops waving about it.
    public static func aggregate(
        _ all: [SessionState],
        now: Date,
        hidden: [String: Date] = [:],
        snoozed: [String: Snooze.Mark] = [:],
        isLive: (SessionState, Date) -> Bool = Self.isLive
    ) -> GlobalState {
        let live = all.filter { isLive($0, now) }
        let alive = live.filter { !HiddenSessions.isHidden($0, marks: hidden) }
        let hiddenCount = live.count - alive.count

        let waiting = alive
            .filter { $0.state == .waiting && !Snooze.isSnoozed($0, marks: snoozed, now: now) }
            .sorted { $0.since < $1.since }

        if let longest = waiting.first {
            let waited = now.timeIntervalSince(longest.since)
            return GlobalState(
                mood: waited > urgentAfter ? .urgent : .waiting,
                sessions: ordered(alive),
                waitingProject: longest.project,
                hiddenCount: hiddenCount,
                waitingOn: longest.waitingOn
            )
        }

        let mood: GlobalMood = alive.contains { $0.state == .busy } ? .busy : .idle
        return GlobalState(
            mood: mood, sessions: ordered(alive), waitingProject: nil, hiddenCount: hiddenCount
        )
    }

    /// Projects with more than one live session, i.e. the ones whose rows are
    /// indistinguishable without a session name.
    ///
    /// The panel's first column is a directory name, so three sessions open in
    /// one repo render as the same word three times. Naming them costs a second
    /// line per row, which is why it is spent only where there is genuine
    /// ambiguity rather than on every row.
    public static func ambiguousProjects(_ sessions: [SessionState]) -> Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for session in sessions {
            if !seen.insert(session.project).inserted { repeated.insert(session.project) }
        }
        return repeated
    }

    /// Waiting first, then busy, then idle; oldest `since` first inside each group,
    /// so the expanded panel lists the most neglected session at the top.
    private static func ordered(_ sessions: [SessionState]) -> [SessionState] {
        func rank(_ s: SessionActivity) -> Int {
            switch s {
            case .waiting: return 0
            case .busy: return 1
            case .idle: return 2
            }
        }
        return sessions.sorted {
            rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.since < $1.since
        }
    }
}
