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
    public static func lines(
        session: SessionState,
        insight: SessionInsight?,
        lastActivity: ActivityEntry?,
        now: Date
    ) -> [String] {
        var out: [String] = []

        let place = home(session.cwd)
        let where_ = [place, insight?.worktree ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if !where_.isEmpty { out.append(where_) }

        if let insight, insight.isFresh(now: now) {
            var second: [String] = []
            if let percent = insight.contextPercent {
                second.append("context \(percent)%")
            }
            if !insight.modelName.isEmpty { second.append(insight.modelName) }
            if !second.isEmpty { out.append(second.joined(separator: " · ")) }
        }

        var clocks = ["turn " + Chatter.duration(until: now, now: session.since)]
        let quiet = now.timeIntervalSince(session.updatedAt)
        // Only worth saying once it is longer than the turn is old, i.e. once
        // the session has actually gone quiet rather than merely started.
        if quiet >= 30 {
            clocks.append("quiet " + Chatter.duration(until: now, now: session.updatedAt))
        }
        out.append(clocks.joined(separator: " · "))

        if let lastActivity {
            out.append("last: " + lastActivity.line())
        }
        return out
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
