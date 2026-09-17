import Foundation

/// Pulls quota numbers out of the JSON Claude Code feeds a statusline command.
///
/// **The exact shape of `rate_limits` has not been verified against a live
/// payload.** The field exists in Claude Code 2.1.274's binary and the docs
/// describe it, but this machine's statusline is claude-hud's, and wrapping it
/// to capture one payload would have meant editing a working `settings.json`
/// for a look. So the parser accepts several plausible spellings of the same
/// thing and returns nil when it recognises none of them — at which point the
/// pet falls back to the claude-hud cache exactly as before.
///
/// Returning nil is a supported outcome here, not a failure. Nothing depends on
/// this source existing.
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

        guard
            let five = window(in: limits, matching: ["five_hour", "fiveHour", "5h", "five"]),
            let week = window(in: limits, matching: ["seven_day", "sevenDay", "weekly", "week"])
        else { return nil }

        return UsageSnapshot(
            planName: root["plan"] as? String ?? (root["model"] as? [String: Any])?["display_name"] as? String ?? "",
            fiveHourPercent: five.percent,
            sevenDayPercent: week.percent,
            fiveHourResetAt: five.resetsAt ?? now,
            sevenDayResetAt: week.resetsAt ?? now,
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
        for key in ["used_pct", "usedPct", "used_percent", "percent", "used"] {
            if let n = raw[key] as? Int { return min(100, max(0, n)) }
            if let d = raw[key] as? Double { return min(100, max(0, Int(d.rounded()))) }
        }
        return nil
    }

    static func date(in raw: [String: Any]) -> Date? {
        for key in ["resets_at", "resetsAt", "reset_at", "resetAt"] {
            if let text = raw[key] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: text) { return d }
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                if let d = plain.date(from: text) { return d }
            }
            // Epoch seconds are the other common spelling.
            if let seconds = raw[key] as? Double { return Date(timeIntervalSince1970: seconds) }
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
