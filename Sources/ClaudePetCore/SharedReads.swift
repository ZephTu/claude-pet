import Foundation

/// The board's polled reads, shared. The Mac's window and every phone's board each ask for
/// `hq board`, `hq sessions` and `claude agents` every few seconds; without this each of them
/// started its own copies. A read already running is joined, and a finished one answers again for
/// a short while (`ttl`), so however many boards are open, each read runs about once per interval.
///
/// Anything the board does besides reading (`changes`) may change what hq says, so it drops what
/// is kept, before it runs and again once it is done: the read the board makes right after a save
/// starts afresh and sees the save.
public actor SharedReads {
    public static let shared = SharedReads()

    /// What a read answered: hq's stdout, or the error to show.
    public struct Answer: Sendable, Equatable {
        public let text: String?
        public let error: String?
        public init(text: String?, error: String?) {
            self.text = text
            self.error = error
        }
    }

    /// How long a finished read answers again, by op; nil for an op that isn't shared.
    /// `claude agents` starts a whole Claude Code and changes only when a background session
    /// starts or ends (a launch from the board drops it at once), so it is kept longer.
    public static func ttl(_ op: String) -> TimeInterval? {
        switch op {
        case "board", "sessions", "status": return 2
        case "agents": return 20
        default: return nil
        }
    }

    /// Ops that only read: they leave what is kept alone. Any other op — including one added
    /// later and not listed here — is taken to change something.
    public static let readOnly: Set<String> = [
        "board", "sessions", "status", "agents", "pet", "peek", "seen", "commands", "peek-tool",
        "history", "prompt", "read-doc", "remote", "phrase-suggest", "jobs", "job-detail",
        "job-preview", "secretary", "intake-job",
    ]
    public static func changes(_ op: String) -> Bool { !readOnly.contains(op) }

    private struct Entry {
        let task: Task<Answer, Never>
        /// When it finished; nil while it runs.
        var done: Date?
    }
    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The answer for `key`: the one running, or one finished less than `ttl` ago, or a new read.
    /// A failed read isn't kept — the next one tries again.
    public func read(_ key: String, ttl: TimeInterval,
                     _ fetch: @escaping @Sendable () async -> Answer) async -> Answer {
        if let e = entries[key], e.done.map({ now().timeIntervalSince($0) < ttl }) ?? true {
            return await e.task.value
        }
        let task = Task { await fetch() }
        entries[key] = Entry(task: task, done: nil)
        let answer = await task.value
        // Still the kept one: a change while it ran dropped it, and a newer read may have replaced it.
        if entries[key]?.task == task {
            if answer.error == nil { entries[key]?.done = now() } else { entries[key] = nil }
        }
        return answer
    }

    /// Something may have changed what the reads say: none of the kept answers serves again, and a
    /// read still running is not joined (its answer may be from before the change).
    public func changed() {
        entries.removeAll()
    }

    /// Only these reads may have changed (a file the board reads from was written — BoardPush).
    public func changed(_ keys: Set<String>) {
        for key in keys { entries[key] = nil }
    }
}
