import Foundation

/// What to show when the pointer rests on a session row.
///
/// The row itself is one line and already says the name, what is running and
/// how long that call has taken. Hovering used to repeat the name, which stopped
/// being useful the moment the first column started showing it. So this answers
/// the questions the row has no space for: WHERE this session is, how full its
/// context is, how the three different clocks compare, and what it last did.
public enum SessionDetail {
    /// Three clocks that are routinely confused for each other:
    ///
    /// - how long this turn has been going
    /// - how long the current tool call has been going (already in the row)
    /// - how long since anything happened at all
    ///
    /// The third is the one that answers "is this stuck?", and it is the one a
    /// single number cannot express alongside the others.
    /// Structured, not a paragraph: the page draws a meter for the context and
    /// gives each kind of fact its own weight. Handing over a sentence made the
    /// reader parse all of it to find any of it.
    public struct Detail: Sendable, Equatable {
        public var path = ""
        public var worktree = ""
        /// 0-100, or nil when no statusline is wired up or its reading is stale.
        public var contextPercent: Int?
        public var model = ""
        public var turn = ""
        /// Only set once the session has actually gone quiet.
        public var quiet = ""
        public var last = ""
        /// The last call was interrupted, so the marker beside it warns.
        public var lastBad = false

        public var isEmpty: Bool {
            path.isEmpty && contextPercent == nil && model.isEmpty
                && turn.isEmpty && last.isEmpty
        }
    }

    public static func detail(
        session: SessionState,
        insight: SessionInsight?,
        lastActivity: ActivityEntry?,
        now: Date
    ) -> Detail {
        var d = Detail()
        d.path = home(session.cwd)

        if let insight, insight.isFresh(now: now) {
            d.worktree = insight.worktree
            d.contextPercent = insight.contextPercent
            d.model = insight.modelName
        }

        d.turn = Chatter.duration(until: now, now: session.since)
        // Only worth reporting once the session has actually gone quiet, rather
        // than merely started.
        if now.timeIntervalSince(session.updatedAt) >= 30 {
            d.quiet = Chatter.duration(until: now, now: session.updatedAt)
        }

        if let lastActivity {
            d.last = lastActivity.line()
            d.lastBad = lastActivity.result == .interrupted
        }
        return d
    }

    /// Collapses the user's home directory. A hover bubble is 300pt wide and
    /// `/Users/somebody/Documents/...` spends a third of it saying nothing.
    public static func home(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/", path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
