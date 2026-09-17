import Foundation

/// Telling the user their allowance is running down, without becoming the thing
/// they tune out.
///
/// The rule is CROSSING a threshold, not sitting above one. "Currently ≥ 80%"
/// plus a cooldown says the same sentence every hour for the rest of the
/// window, which is how a warning becomes wallpaper. Crossing fires once per
/// threshold per window, and a window that resets rearms by itself because the
/// reset instant is part of the key.
public enum QuotaAlarm {
    public enum Window: String, Sendable, Equatable, CaseIterable {
        case fiveHour
        case sevenDay

        public var label: String {
            switch self {
            case .fiveHour: return "5-hour"
            case .sevenDay: return "weekly"
            }
        }

        /// The weekly window warns earlier, because running it out costs days
        /// rather than hours. Same number, very different afternoon.
        public var thresholds: [Int] {
            switch self {
            case .fiveHour: return [80, 95]
            case .sevenDay: return [65, 85, 95]
            }
        }
    }

    public struct Alarm: Sendable, Equatable {
        public let window: Window
        public let threshold: Int
        public let percent: Int
        public let resetsIn: String

        public init(window: Window, threshold: Int, percent: Int, resetsIn: String) {
            self.window = window
            self.threshold = threshold
            self.percent = percent
            self.resetsIn = resetsIn
        }

        public var text: String {
            switch window {
            case .fiveHour:
                return "5-hour quota at \(percent)% — \(resetsIn) left in this window"
            case .sevenDay:
                // Named as the more expensive one to run out of, because it is.
                return "weekly quota at \(percent)% — \(resetsIn) until it resets"
            }
        }
    }

    public struct Decision: Sendable, Equatable {
        /// The one line to say, or nil for nothing. Always the highest threshold
        /// crossed: jumping 70% → 96% is one warning, not two.
        public let speak: Alarm?
        /// Every threshold to record as said, including ones skipped past. A
        /// threshold that was leapfrogged must not surface later as news.
        public let markSaid: Set<String>

        public init(speak: Alarm?, markSaid: Set<String>) {
            self.speak = speak
            self.markSaid = markSaid
        }
    }

    /// Identifies one threshold of one window of one reset period.
    ///
    /// The reset instant is in the key on purpose: when the window rolls over,
    /// every key changes, so the thresholds rearm without anything having to
    /// remember to clear them.
    public static func key(window: Window, resetAt: Date, threshold: Int) -> String {
        "\(window.rawValue)@\(Int(resetAt.timeIntervalSince1970))#\(threshold)"
    }

    /// - Parameters:
    ///   - alreadySaid: keys recorded by previous calls. Persisted, so a restart
    ///     does not replay warnings the user already saw.
    public static func evaluate(
        usage: UsageSnapshot?,
        alreadySaid: Set<String>,
        now: Date
    ) -> Decision {
        guard let usage, usage.percentagesUsable(now: now) else {
            return Decision(speak: nil, markSaid: [])
        }

        var toMark: Set<String> = []
        var best: Alarm?

        for window in Window.allCases {
            let percent: Int
            let resetAt: Date
            switch window {
            case .fiveHour:
                percent = usage.fiveHourPercent
                resetAt = usage.fiveHourResetAt
            case .sevenDay:
                percent = usage.sevenDayPercent
                resetAt = usage.sevenDayResetAt
            }
            // A window whose reset has passed describes a period that is over;
            // its percentage belongs to no window that still exists.
            guard now < resetAt else { continue }

            for threshold in window.thresholds where percent >= threshold {
                let id = key(window: window, resetAt: resetAt, threshold: threshold)
                guard !alreadySaid.contains(id) else { continue }
                toMark.insert(id)
                let alarm = Alarm(window: window, threshold: threshold, percent: percent,
                                  resetsIn: Chatter.duration(until: resetAt, now: now))
                // Weekly outranks five-hour at equal urgency; otherwise the
                // higher threshold wins.
                if let current = best {
                    if threshold > current.threshold
                        || (threshold == current.threshold && window == .sevenDay) {
                        best = alarm
                    }
                } else {
                    best = alarm
                }
            }
        }
        return Decision(speak: best, markSaid: toMark)
    }

    /// Drops keys for periods that have ended, so the store does not grow for
    /// ever. A key whose reset instant is in the past can never match again.
    public static func pruned(_ said: Set<String>, now: Date) -> Set<String> {
        said.filter { key in
            guard
                let at = key.split(separator: "@").last?.split(separator: "#").first,
                let seconds = Double(at)
            else { return false }
            return Date(timeIntervalSince1970: seconds) > now
        }
    }
}
