import Foundation

/// One tool call that has finished.
public struct ActivityEntry: Sendable, Equatable {
    public enum Result: String, Sendable, Equatable {
        case ok
        /// Claude Code said the call was interrupted. This is the ONLY failure
        /// this type claims, because it is the only one the payload states
        /// outright — a non-empty stderr is not a failure, and guessing from it
        /// would label half a normal build as broken.
        case interrupted
        /// The payload did not say. Better than inventing a verdict.
        case unknown
    }

    public let tool: String
    /// Short and deliberately incomplete — see ActivitySummary.
    public let target: String
    public let finishedAt: Date
    public let durationMs: Int
    public let result: Result

    public init(tool: String, target: String, finishedAt: Date,
                durationMs: Int, result: Result) {
        self.tool = tool
        self.target = target
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.result = result
    }

    /// "Bash npm test · 2.9s"
    public func line() -> String {
        let phrase = ActivitySummary.phrase(toolName: tool, target: target)
        var text = phrase
        if durationMs > 0 { text += " · " + duration }
        if result == .interrupted { text += " · interrupted" }
        return text
    }

    private var duration: String {
        durationMs < 1000 ? "\(durationMs)ms"
            : String(format: "%.1fs", Double(durationMs) / 1000)
    }
}

/// Reading and ageing the per-session activity log.
///
/// Stored as one line of JSON per call, appended. Append-only because the
/// writer is a hook: it must finish fast and must survive being killed
/// mid-write, and a truncated last line costs exactly that line.
public enum ActivityLog {
    /// How many calls one session shows.
    public static let shown = 20
    /// How long a call stays in the log.
    public static let retention: TimeInterval = 24 * 60 * 60
    /// Total across all sessions, so a machine left running cannot grow the
    /// directory without bound.
    public static let totalCap = 2000

    public static func encode(_ e: ActivityEntry) -> Data {
        let doc: [String: Any] = [
            "tool": e.tool,
            "target": e.target,
            "at": CompletionQueue.format(e.finishedAt),
            "ms": e.durationMs,
            "result": e.result.rawValue,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: doc) else { return Data() }
        data.append(0x0A)   // newline: one call per line
        return data
    }

    /// Parses a log file, newest last. Unreadable lines are skipped — the last
    /// one is routinely half-written, because the process that writes it can be
    /// killed at any moment.
    public static func decode(_ text: String) -> [ActivityEntry] {
        text.split(separator: "\n").compactMap { decodeLine(String($0)) }
    }

    static func decodeLine(_ line: String) -> ActivityEntry? {
        guard
            let data = line.data(using: .utf8),
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let at = d["at"] as? String,
            let finishedAt = CompletionQueue.parseDate(at)
        else { return nil }
        let result = ActivityEntry.Result(rawValue: d["result"] as? String ?? "") ?? .unknown
        return ActivityEntry(tool: d["tool"] as? String ?? "",
                             target: d["target"] as? String ?? "",
                             finishedAt: finishedAt,
                             durationMs: d["ms"] as? Int ?? 0,
                             result: result)
    }

    /// The most recent calls still inside the retention window, newest first.
    public static func recent(_ entries: [ActivityEntry], now: Date,
                              limit: Int = shown) -> [ActivityEntry] {
        entries
            .filter { now.timeIntervalSince($0.finishedAt) <= retention }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// How many entries each session may keep so the total stays under the cap.
    ///
    /// Shared out evenly rather than first-come: one chatty session must not be
    /// able to push every other session's history out of the log.
    public static func perSessionBudget(sessionCount: Int) -> Int {
        guard sessionCount > 0 else { return totalCap }
        return max(shown, totalCap / sessionCount)
    }
}
