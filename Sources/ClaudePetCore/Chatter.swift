import Foundation

/// Decides whether the pet has anything worth saying right now.
///
/// Pure, and that is the point: "when does a desktop toy get to interrupt you"
/// is exactly the kind of rule that is impossible to get right by trying it and
/// impossible to verify by looking at it. Every cooldown and precedence rule
/// here is a test case.
///
/// The governing rule is that speech needs an OCCASION. Nothing here fires on a
/// timer alone — each line is attached to something that actually happened: a
/// quota window about to roll over, work finishing, work running long.
public enum Chatter {
    /// What a line is about. Cooldowns are per-kind, so a quota reminder does
    /// not silence a "finished" line an hour later.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case quotaResetting
        case quotaHigh
        case finished
        case longRun
    }

    public struct Utterance: Sendable, Equatable {
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Minimum gap between any two lines, whatever they are about. Without this
    /// a burst of events would produce a burst of speech.
    public static let globalCooldown: TimeInterval = 5 * 60

    public static func cooldown(for kind: Kind) -> TimeInterval {
        switch kind {
        case .quotaResetting: return 30 * 60
        case .quotaHigh: return 60 * 60
        case .finished: return 10 * 60
        case .longRun: return 20 * 60
        }
    }

    /// Say something when the five-hour window is this close to rolling over.
    public static let resetSoon: TimeInterval = 15 * 60
    /// Say something when a window is at least this full.
    public static let highWaterMark = 80
    /// A single session busy for this long is worth remarking on.
    public static let longRunAfter: TimeInterval = 20 * 60

    /// - Parameters:
    ///   - state: the mood and sessions being displayed right now.
    ///   - previous: the previous render's state, for spotting transitions. Nil
    ///     on the very first render, which suppresses transition-based lines so
    ///     the pet does not greet a fresh launch with "all done".
    ///   - usage: quota reading, or nil when claude-hud is not installed.
    ///   - lastSpoken: kind → when a line of that kind was last said.
    ///   - lastAnything: when the pet last said anything at all.
    public static func next(
        state: GlobalState,
        previous: GlobalState?,
        usage: UsageSnapshot?,
        now: Date,
        lastSpoken: [Kind: Date],
        lastAnything: Date?
    ) -> Utterance? {
        // The bubble belongs to the alarm while something is actually blocked,
        // and a session waiting on the user is not a moment for small talk.
        guard state.mood != .urgent, state.mood != .waiting else { return nil }

        if let lastAnything, now.timeIntervalSince(lastAnything) < globalCooldown {
            return nil
        }

        func ready(_ kind: Kind) -> Bool {
            guard let last = lastSpoken[kind] else { return true }
            return now.timeIntervalSince(last) >= cooldown(for: kind)
        }

        // Quota lines first: they are time-critical in a way the others are not.
        if let usage {
            let untilReset = usage.fiveHourResetAt.timeIntervalSince(now)
            if ready(.quotaResetting), untilReset > 0, untilReset <= resetSoon {
                return Utterance(
                    kind: .quotaResetting,
                    text: "五小时额度还有 \(minutes(untilReset)) 分钟回血"
                )
            }
            if ready(.quotaHigh), usage.percentagesUsable(now: now) {
                if usage.sevenDayPercent >= highWaterMark {
                    return Utterance(
                        kind: .quotaHigh,
                        text: "周额度用了 \(usage.sevenDayPercent)%，悠着点"
                    )
                }
                if usage.fiveHourPercent >= highWaterMark {
                    return Utterance(
                        kind: .quotaHigh,
                        text: "五小时额度用了 \(usage.fiveHourPercent)%，\(clockHint(usage.fiveHourResetAt, now: now))回血"
                    )
                }
            }
        }

        guard let previous else { return nil }

        // Everything below is a transition, so it needs a previous state to
        // compare against.
        if ready(.finished), previous.mood == .busy, state.mood == .idle {
            return Utterance(kind: .finished, text: finishedLine(count: previous.sessions.count))
        }

        if ready(.longRun), state.mood == .busy,
           let longest = longestBusy(state.sessions, now: now),
           now.timeIntervalSince(longest.since) >= longRunAfter {
            let mins = minutes(now.timeIntervalSince(longest.since))
            return Utterance(kind: .longRun, text: "\(longest.project) 这活干了 \(mins) 分钟了")
        }

        return nil
    }

    /// The line the pet shows when the pointer rests on it. Always available,
    /// never rate-limited: the user asked for this one.
    public static func onDemand(usage: UsageSnapshot?, state: GlobalState, now: Date) -> String {
        guard let usage else {
            return state.sessions.isEmpty ? "没有活跃的 session" : "\(state.sessions.count) 个 session 在跑"
        }
        var parts: [String] = []
        if usage.percentagesUsable(now: now) {
            parts.append("五小时 \(usage.fiveHourPercent)% · 周 \(usage.sevenDayPercent)%")
        }
        parts.append("\(clockHint(usage.fiveHourResetAt, now: now))回血")
        return parts.joined(separator: "，")
    }

    // MARK: - Wording

    private static func finishedLine(count: Int) -> String {
        count > 1 ? "\(count) 个都干完了" : "干完了"
    }

    private static func longestBusy(_ sessions: [SessionState], now: Date) -> SessionState? {
        sessions.filter { $0.state == .busy }.min { $0.since < $1.since }
    }

    private static func minutes(_ interval: TimeInterval) -> Int {
        max(1, Int((interval / 60).rounded()))
    }

    /// "42 分钟后" for something imminent, "15:40" for something further off —
    /// a countdown is useful within the hour and useless beyond it.
    private static func clockHint(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "随时" }
        if delta < 60 * 60 { return "\(minutes(delta)) 分钟后" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
