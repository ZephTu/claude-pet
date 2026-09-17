import Foundation

/// Pulls quota numbers out of the JSON Claude Code feeds a statusline command.
///
/// The shape comes from Claude Code's own statusline documentation, which ships
/// inside the binary (2.1.274):
///
///     "rate_limits": {
///       "five_hour": { "used_percentage": number, "resets_at": number },
///       "seven_day": { "used_percentage": number, "resets_at": number },
///       "spend_limit": { "used_percentage": number, "resets_at": number }
///     }
///
/// `resets_at` is Unix epoch SECONDS, not a string. An earlier version of this
/// parser guessed at the spelling and listed `used_pct`, `usedPct`,
/// `used_percent`, `percent` and `used` — every plausible name except the real
/// one, so it would have recognised nothing. The alternates are kept as a
/// cushion against the shape changing, but `used_percentage` is the documented
/// key and the one that works.
///
/// Returning nil is a supported outcome here, not a failure: a window is absent
/// whenever the API has not reported it, and nothing depends on this source.
public enum StatuslineUsage {
    /// Where the captured reading is kept, so the app can read it without
    /// knowing anything about statuslines.
    public static func cacheURL(petHome: URL) -> URL {
        petHome.appending(path: "usage.json")
    }

    public static func parse(_ data: Data, now: Date) -> UsageSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = root["rate_limits"] as? [String: Any]
        else { return nil }

        // Each window is independently optional — the docs say a window is
        // "present only while the API reports it and its resets_at has not
        // passed". Requiring both meant a user with only a five-hour limit got
        // nothing at all.
        let five = window(in: limits, matching: ["five_hour", "fiveHour", "5h", "five"])
        let week = window(in: limits, matching: ["seven_day", "sevenDay", "weekly", "week"])
        guard five != nil || week != nil else { return nil }

        // A missing window is reported as already reset rather than as 0% used:
        // `quotaRows` drops a window whose reset has passed, so an absent one
        // simply does not draw a meter. Claiming 0% would be inventing a number.
        return UsageSnapshot(
            planName: (root["model"] as? [String: Any])?["display_name"] as? String ?? "",
            fiveHourPercent: five?.percent ?? 0,
            sevenDayPercent: week?.percent ?? 0,
            fiveHourResetAt: five?.resetsAt ?? now.addingTimeInterval(-1),
            sevenDayResetAt: week?.resetsAt ?? now.addingTimeInterval(-1),
            capturedAt: now,
            source: "statusline")
    }

    struct Window {
        let percent: Int
        let resetsAt: Date?
    }

    /// Finds one window under any of several plausible key spellings.
    static func window(in limits: [String: Any], matching keys: [String]) -> Window? {
        for key in keys {
            guard let raw = limits[key] as? [String: Any] else { continue }
            guard let percent = percent(in: raw) else { continue }
            return Window(percent: percent, resetsAt: date(in: raw))
        }
        return nil
    }

    static func percent(in raw: [String: Any]) -> Int? {
        // used_percentage first: it is the documented name.
        for key in ["used_percentage", "usedPercentage", "used_pct", "usedPct",
                    "used_percent", "percent", "used"] {
            if let n = raw[key] as? Int { return min(100, max(0, n)) }
            if let d = raw[key] as? Double { return min(100, max(0, Int(d.rounded()))) }
        }
        return nil
    }

    static func date(in raw: [String: Any]) -> Date? {
        for key in ["resets_at", "resetsAt", "reset_at", "resetAt"] {
            // Epoch seconds is what Claude Code actually sends.
            if let seconds = raw[key] as? Double { return Date(timeIntervalSince1970: seconds) }
            if let seconds = raw[key] as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
            if let text = raw[key] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: text) { return d }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                if let d = plain.date(from: text) { return d }
            }
        }
        return nil
    }

    /// Serialises a captured reading for the app to pick up.
    public static func encode(_ s: UsageSnapshot) -> Data {
        let doc: [String: Any] = [
            "planName": s.planName,
            "fiveHourPercent": s.fiveHourPercent,
            "sevenDayPercent": s.sevenDayPercent,
            "fiveHourResetAt": CompletionQueue.format(s.fiveHourResetAt),
            "sevenDayResetAt": CompletionQueue.format(s.sevenDayResetAt),
            "capturedAt": CompletionQueue.format(s.capturedAt),
        ]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }

    public static func decode(_ data: Data) -> UsageSnapshot? {
        guard
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let five = d["fiveHourPercent"] as? Int,
            let week = d["sevenDayPercent"] as? Int,
            let fiveReset = (d["fiveHourResetAt"] as? String).flatMap(CompletionQueue.parseDate),
            let weekReset = (d["sevenDayResetAt"] as? String).flatMap(CompletionQueue.parseDate),
            let captured = (d["capturedAt"] as? String).flatMap(CompletionQueue.parseDate)
        else { return nil }
        return UsageSnapshot(planName: d["planName"] as? String ?? "",
                             fiveHourPercent: five, sevenDayPercent: week,
                             fiveHourResetAt: fiveReset, sevenDayResetAt: weekReset,
                             capturedAt: captured, source: "statusline")
    }
}
