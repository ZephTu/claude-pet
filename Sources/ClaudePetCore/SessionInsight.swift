import Foundation

/// The per-session facts only a statusline gets told.
///
/// Hooks carry nothing about the conversation itself — no model, no context
/// size, no name. The statusline payload carries all three, keyed by
/// `session_id`, so wiring `pet-emit --statusline` in front of an existing
/// statusline is what makes these available. Without it the pet simply shows
/// less, which is why every field here is optional at the display end.
public struct SessionInsight: Sendable, Equatable {
    public let sessionId: String
    /// Set with Claude Code's own `/rename`. More authoritative than a terminal
    /// tab title, because the user named THE SESSION rather than the window.
    public let sessionName: String
    public let modelName: String
    /// How full the context window is, 0-100. Nil before the first API response,
    /// which is a real state and not the same as 0%.
    public let contextPercent: Int?
    /// The worktree this session sits in, when it is a linked one.
    public let worktree: String
    public let capturedAt: Date

    public init(sessionId: String, sessionName: String = "", modelName: String = "",
                contextPercent: Int? = nil, worktree: String = "", capturedAt: Date) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.modelName = modelName
        self.contextPercent = contextPercent
        self.worktree = worktree
        self.capturedAt = capturedAt
    }

    /// Context readings go stale the same way quota percentages do: the
    /// statusline only runs while Claude Code is drawing, so a session that has
    /// been quiet has a reading from whenever it last was not.
    public static let goesStaleAfter: TimeInterval = 30 * 60

    public func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= Self.goesStaleAfter
    }
}

/// Reading and writing what the statusline told us about one session.
public enum SessionInsights {
    public static func directory(petHome: URL) -> URL {
        petHome.appending(path: "insight")
    }

    public static func fileName(sessionId: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(sessionId.map { ok.contains($0) ? $0 : "_" }) + ".json"
    }

    /// Reads one out of a statusline payload. Nil when there is no session id to
    /// attach it to — an insight with no session is not an insight.
    public static func parse(_ data: Data, now: Date) -> SessionInsight? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = root["session_id"] as? String, !sessionId.isEmpty
        else { return nil }

        let context = root["context_window"] as? [String: Any]
        // `used_percentage` is documented as `number | null`, and null means "no
        // messages yet" — a different thing from 0% and reported as such.
        let percent: Int?
        if let raw = context?["used_percentage"] as? Double {
            percent = min(100, max(0, Int(raw.rounded())))
        } else if let raw = context?["used_percentage"] as? Int {
            percent = min(100, max(0, raw))
        } else {
            percent = nil
        }

        let workspace = root["workspace"] as? [String: Any]
        return SessionInsight(
            sessionId: sessionId,
            sessionName: root["session_name"] as? String ?? "",
            modelName: (root["model"] as? [String: Any])?["display_name"] as? String ?? "",
            contextPercent: percent,
            worktree: workspace?["git_worktree"] as? String ?? "",
            capturedAt: now)
    }

    public static func encode(_ i: SessionInsight) -> Data {
        var doc: [String: Any] = [
            "sessionId": i.sessionId,
            "sessionName": i.sessionName,
            "modelName": i.modelName,
            "worktree": i.worktree,
            "capturedAt": CompletionQueue.format(i.capturedAt),
        ]
        if let percent = i.contextPercent { doc["contextPercent"] = percent }
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }

    public static func decode(_ data: Data) -> SessionInsight? {
        guard
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = d["sessionId"] as? String, !sessionId.isEmpty,
            let captured = (d["capturedAt"] as? String).flatMap(CompletionQueue.parseDate)
        else { return nil }
        return SessionInsight(sessionId: sessionId,
                              sessionName: d["sessionName"] as? String ?? "",
                              modelName: d["modelName"] as? String ?? "",
                              contextPercent: d["contextPercent"] as? Int,
                              worktree: d["worktree"] as? String ?? "",
                              capturedAt: captured)
    }
}
