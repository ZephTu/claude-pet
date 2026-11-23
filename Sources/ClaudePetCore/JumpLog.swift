import Foundation

/// One line per ↗ Jump, written to ~/.claude/pet/jumps.jsonl.
///
/// The point is measurement: which states send the user back to a terminal, and
/// from where. A week of these decides what the board should learn to do in the
/// terminal's place (HQ task T-075, conclusions to T-086). Nothing in the pet
/// reads the file back; `hq jumps` summarises it.
///
/// Local only, and nothing beyond what the pet already shows on screen: no
/// prompt text, no paths beyond the project's name.
public enum JumpLog {
    /// What the session was doing at the moment of the jump. Strings rather than
    /// an enum in the file, so a later pet adding a state does not break older
    /// summaries.
    public enum State: String, Sendable, CaseIterable {
        /// Running a turn, tool calls in flight or the model writing.
        case working
        /// Its turn is over and a background agent it dispatched is doing the work.
        case agent
        /// A permission prompt is up.
        case permission
        /// Waiting on typing: a question, a plan to approve, anything that is not a permission.
        case question
        /// Finished a turn and said something; waiting on the next instruction.
        case replied
        /// Open, nothing said since the last turn, or never spoken to.
        case idle
        /// Busy on paper but stopped: the user pressed Esc, or a tool call came
        /// back interrupted.
        case interrupted
        /// The pet no longer has it as a live session (a finished row whose
        /// session has since closed, or a stale board).
        case gone
    }

    /// The state `s` is in, the same way its row in the pet and on the board
    /// reads. `quiet` is `StateAggregator.isQuiet`, passed in because it reads
    /// Claude Code's own status file.
    public static func state(of s: SessionState?, quiet: Bool) -> State {
        guard let s else { return .gone }
        switch s.state {
        case .waiting:
            return s.waitingOn.isEmpty ? .question : .permission
        case .busy:
            // An interrupted call during this stretch of work, or work that went
            // silent the way only an interrupt does.
            if quiet || (s.troubleAt.map { $0 >= s.since } ?? false) { return .interrupted }
            if s.phase == "awaiting-agent" || !s.backgroundAgents.isEmpty { return .agent }
            return .working
        case .idle:
            return s.detail.isEmpty ? .idle : .replied
        }
    }

    public struct Event: Sendable, Equatable {
        public let at: Date
        public let session: String
        /// Where the click was: "board-card", "board-sessions", "board-peek",
        /// "board-context", "pet-list", "pet-finished", "pet-notice", "hotkey".
        public let source: String
        public let state: State
        /// The board tab that was showing, for board sources ("today", "all", …).
        public let view: String
        public let task: String?
        public let project: String
        /// Context used against its auto-compact window, 0-999.
        public let context: Int?
        /// Seconds in its current state.
        public let waited: Int?
        /// Seconds since its Peek was last opened on the board, nil when it has
        /// not been since the pet started.
        public let peekedAgo: Int?
        /// "orca", "iterm2", … — some jumps land on the tab, an editor only on the window.
        public let terminal: String

        public init(at: Date, session: String, source: String, state: State, view: String = "",
                    task: String? = nil, project: String = "", context: Int? = nil,
                    waited: Int? = nil, peekedAgo: Int? = nil, terminal: String = "") {
            self.at = at
            self.session = session
            self.source = source
            self.state = state
            self.view = view
            self.task = task
            self.project = project
            self.context = context
            self.waited = waited
            self.peekedAgo = peekedAgo
            self.terminal = terminal
        }
    }

    /// One JSON line, newline included. Keys sorted so the file diffs and greps
    /// predictably; absent values left out rather than written as null.
    public static func line(_ e: Event) -> String {
        var o: [String: Any] = [
            "at": e.at.formatted(.iso8601),
            "session": e.session,
            "source": e.source,
            "state": e.state.rawValue,
        ]
        if !e.view.isEmpty { o["view"] = e.view }
        if let task = e.task, !task.isEmpty { o["task"] = task }
        if !e.project.isEmpty { o["project"] = e.project }
        if let v = e.context { o["context"] = v }
        if let v = e.waited { o["waited"] = v }
        if let v = e.peekedAgo { o["peekedAgo"] = v }
        if !e.terminal.isEmpty { o["terminal"] = e.terminal }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Appends one event. Errors are dropped: a measurement must never get in
    /// the way of the jump it measures.
    public static func append(_ e: Event, to file: URL) {
        let text = line(e)
        guard !text.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
