import Foundation

/// How much of the Claude subscription's allowance is used, and when it resets.
public struct UsageSnapshot: Sendable, Equatable {
    public let planName: String
    /// Percent of the five-hour window used, 0-100.
    public let fiveHourPercent: Int
    /// Percent of the weekly window used, 0-100.
    public let sevenDayPercent: Int
    public let fiveHourResetAt: Date
    public let sevenDayResetAt: Date
    /// When this reading was taken, which is NOT when it was read.
    public let capturedAt: Date

    public init(
        planName: String,
        fiveHourPercent: Int,
        sevenDayPercent: Int,
        fiveHourResetAt: Date,
        sevenDayResetAt: Date,
        capturedAt: Date
    ) {
        self.planName = planName
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.fiveHourResetAt = fiveHourResetAt
        self.sevenDayResetAt = sevenDayResetAt
        self.capturedAt = capturedAt
    }

    /// Percentages go stale; reset times do not.
    ///
    /// The cache is refreshed by the statusline, so it only updates while the
    /// user has Claude Code open. After a quiet evening the percentages describe
    /// a window that has since rolled over, and announcing them would be worse
    /// than saying nothing. The reset timestamps are absolute instants, so they
    /// stay true regardless of when they were fetched.
    public static let percentagesGoStaleAfter: TimeInterval = 30 * 60

    public func percentagesUsable(now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= Self.percentagesGoStaleAfter
    }
}

/// Reads the usage cache that the claude-hud statusline plugin maintains.
///
/// Deliberately a READER of someone else's cache rather than a client of the
/// usage API. Calling the API would mean reading the user's OAuth token out of
/// ~/.claude/.credentials.json, spending their rate limit, and handling 429
/// backoff — all so a desktop toy could show a number that is already sitting
/// in a file, refreshed every five minutes by something they already run.
///
/// If the plugin is not installed the file does not exist, and everything that
/// depends on usage simply goes quiet.
public enum UsageReader {
    /// `~/.claude/plugins/claude-hud/.usage-cache.json`
    public static func cacheURL(claudeHome: URL) -> URL {
        claudeHome.appending(path: "plugins/claude-hud/.usage-cache.json")
    }

    /// Parses the cache. Returns nil for anything unexpected: this is another
    /// project's private file, so its shape can change without warning and a
    /// surprise must degrade to silence, never to a crash or a wrong number.
    public static func parse(_ data: Data) -> UsageSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `data` is the live reading; `lastGoodData` is what the plugin keeps
        // when a refresh fails. Preferring the former and falling back keeps a
        // transient API failure from blanking the display.
        let payload = (root["data"] as? [String: Any]) ?? (root["lastGoodData"] as? [String: Any])
        guard
            let payload,
            let fiveHour = payload["fiveHour"] as? Int,
            let sevenDay = payload["sevenDay"] as? Int,
            let fiveReset = payload["fiveHourResetAt"] as? String,
            let sevenReset = payload["sevenDayResetAt"] as? String,
            let fiveResetAt = iso8601(fiveReset),
            let sevenResetAt = iso8601(sevenReset)
        else { return nil }

        // Milliseconds since the epoch, per the plugin's own format.
        let capturedAt: Date
        if let ms = root["timestamp"] as? Double {
            capturedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            capturedAt = .distantPast
        }

        return UsageSnapshot(
            planName: payload["planName"] as? String ?? "",
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetAt: fiveResetAt,
            sevenDayResetAt: sevenResetAt,
            capturedAt: capturedAt
        )
    }

    /// The cache writes fractional seconds ("…:00.039Z"), which the plain
    /// ISO8601 formatter rejects, so both spellings are tried.
    private static func iso8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
