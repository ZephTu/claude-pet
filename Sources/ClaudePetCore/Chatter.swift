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
        case sessionDone
        case longRun
    }

    public struct Utterance: Sendable, Equatable {
        public let kind: Kind
        public let text: String
        /// A substring of `text` the page should set apart — the session or
        /// project being reported on. Empty when the line names nothing in
        /// particular, such as a quota reminder.
        public let emphasis: String

        public init(kind: Kind, text: String, emphasis: String = "") {
            self.kind = kind
            self.text = text
            self.emphasis = emphasis
        }
    }

    /// Minimum gap between any two lines, whatever they are about. Without this
    /// a burst of events would produce a burst of speech.
    public static let globalCooldown: TimeInterval = 5 * 60

    /// Lines that do not take themselves away.
    ///
    /// "Which session just came to rest" is the one line here the user is
    /// actively waiting for, and they wait for it in a terminal window, not in
    /// the corner of the screen. Giving it a timer makes noticing it depend on
    /// already looking at the pet — which is the exact thing the pet exists to
    /// save them from. So it stays until something replaces it, or until they
    /// go back to work (see `justStarted`), at which point it is no longer news.
    public static func isSticky(_ kind: Kind) -> Bool { kind == .sessionDone }

    public static func cooldown(for kind: Kind) -> TimeInterval {
        switch kind {
        case .quotaResetting: return 30 * 60
        case .quotaHigh: return 60 * 60
        case .finished: return 10 * 60
        // Short on purpose: "this one just finished" is the line the user
        // actually asked for, and it is only ever emitted by a real transition,
        // so it cannot run away on its own.
        case .sessionDone: return 20
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
        lastAnything: Date?,
        names: [String: String] = [:]
    ) -> Utterance? {
        // The bubble belongs to the alarm while something is actually blocked,
        // and a session waiting on the user is not a moment for small talk.
        guard state.mood != .urgent, state.mood != .waiting else { return nil }

        // A finishing session is news with a short shelf life, so it is exempt
        // from the global gap — otherwise a quota line said four minutes ago
        // would swallow it. Its own 20s cooldown is what keeps it in check.
        let finishedNow = previous.map { justFinished(previous: $0, current: state) } ?? []
        let hasNews = !finishedNow.isEmpty && Self.ready(.sessionDone, lastSpoken: lastSpoken, now: now)
        if !hasNews, let lastAnything,
           now.timeIntervalSince(lastAnything) < globalCooldown {
            return nil
        }

        func ready(_ kind: Kind) -> Bool { Self.ready(kind, lastSpoken: lastSpoken, now: now) }

        // Which session just came to rest outranks everything else: it is the
        // one thing here the user is actively waiting to hear.
        if hasNews {
            let labels = finishedNow.map { names[$0.sessionId] ?? $0.project }
            return Utterance(
                kind: .sessionDone,
                text: doneLine(finishedNow, names: names),
                // Only a single name can be picked out of the sentence; with two
                // the styled run would be discontiguous.
                emphasis: labels.count == 1 ? labels[0] : ""
            )
        }

        // Quota lines first: they are time-critical in a way the others are not.
        if let usage {
            let untilReset = usage.fiveHourResetAt.timeIntervalSince(now)
            if ready(.quotaResetting), untilReset > 0, untilReset <= resetSoon {
                return Utterance(
                    kind: .quotaResetting,
                    text: "5-hour quota resets in \(minutes(untilReset))m"
                )
            }
            if ready(.quotaHigh), usage.percentagesUsable(now: now) {
                if usage.sevenDayPercent >= highWaterMark {
                    return Utterance(
                        kind: .quotaHigh,
                        text: "Weekly quota at \(usage.sevenDayPercent)% — go easy"
                    )
                }
                if usage.fiveHourPercent >= highWaterMark {
                    return Utterance(
                        kind: .quotaHigh,
                        text: "5-hour quota at \(usage.fiveHourPercent)%, resets \(clockHint(usage.fiveHourResetAt, now: now))"
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
            return Utterance(
                kind: .longRun,
                text: "\(longest.project) has been at it for \(mins)m",
                emphasis: longest.project
            )
        }

        return nil
    }

    /// One row of the hover readout: a labelled meter.
    public struct QuotaRow: Sendable, Equatable {
        public let label: String
        /// 0-100.
        public let percent: Int
        /// "1h 44m", "4d 14h".
        public let resetsIn: String

        public init(label: String, percent: Int, resetsIn: String) {
            self.label = label
            self.percent = percent
            self.resetsIn = resetsIn
        }
    }

    /// The readout shown while the pointer rests on the pet. Always available and
    /// never rate-limited: the user asked for this one.
    ///
    /// Returns rows rather than a sentence so the page can draw meters. Prose is
    /// the wrong shape for two numbers that are being compared — a bar is read at
    /// a glance, "5h 28% · week 39%, resets at 15:30" has to be parsed.
    public static func quotaRows(usage: UsageSnapshot?, now: Date) -> [QuotaRow] {
        guard let usage, usage.percentagesUsable(now: now) else { return [] }
        return [
            QuotaRow(label: "5h", percent: clampPercent(usage.fiveHourPercent),
                     resetsIn: duration(until: usage.fiveHourResetAt, now: now)),
            QuotaRow(label: "week", percent: clampPercent(usage.sevenDayPercent),
                     resetsIn: duration(until: usage.sevenDayResetAt, now: now)),
        ]
    }

    /// Shown when there is no usable quota reading — claude-hud is not installed,
    /// or its cache has gone stale.
    public static func fallbackLine(state: GlobalState) -> String {
        state.sessions.isEmpty ? "No live sessions" : "\(state.sessions.count) sessions running"
    }

    private static func clampPercent(_ p: Int) -> Int { min(100, max(0, p)) }

    /// "44m", "1h 44m", "4d 14h" — coarse on purpose; nobody needs the seconds.
    public static func duration(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return hours == 0 ? "\(minutes)m" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }

    static func ready(_ kind: Kind, lastSpoken: [Kind: Date], now: Date) -> Bool {
        guard let last = lastSpoken[kind] else { return true }
        return now.timeIntervalSince(last) >= cooldown(for: kind)
    }

    /// Sessions that were busy a moment ago and are not any more.
    ///
    /// Matched by session id rather than by count: two sessions swapping states
    /// in one render must not read as "nothing happened".
    public static func justFinished(previous: GlobalState, current: GlobalState) -> [SessionState] {
        let nowBusy = Set(
            current.sessions.filter { $0.state == .busy }.map(\.sessionId)
        )
        return previous.sessions
            .filter { $0.state == .busy && !nowBusy.contains($0.sessionId) }
            // A session that vanished entirely (closed, muted) did not "finish".
            .filter { p in current.sessions.contains { $0.sessionId == p.sessionId } }
    }

    /// Sessions that were not busy a moment ago and are now.
    ///
    /// The mirror of `justFinished`, and what retires a sticky "done" line: once
    /// the user has typed at something again, being told the previous round
    /// finished has stopped being useful.
    public static func justStarted(previous: GlobalState, current: GlobalState) -> [SessionState] {
        let wasBusy = Set(
            previous.sessions.filter { $0.state == .busy }.map(\.sessionId)
        )
        return current.sessions.filter { $0.state == .busy && !wasBusy.contains($0.sessionId) }
    }

    /// - Parameter names: sessionId → the terminal tab title, when known. The
    ///   project is only a directory name, so several sessions share it; the tab
    ///   title is what identifies the one that just finished.
    public static func doneLine(_ finished: [SessionState], names: [String: String]) -> String {
        let labels = finished.map { names[$0.sessionId] ?? $0.project }
        switch labels.count {
        case 1: return labels[0] + " done"
        case 2: return labels.joined(separator: ", ") + " done"
        default: return "\(labels.count) sessions done"
        }
    }

    // MARK: - Wording

    private static func finishedLine(count: Int) -> String {
        count > 1 ? "All \(count) done" : "Done"
    }

    private static func longestBusy(_ sessions: [SessionState], now: Date) -> SessionState? {
        sessions.filter { $0.state == .busy }.min { $0.since < $1.since }
    }

    private static func minutes(_ interval: TimeInterval) -> Int {
        max(1, Int((interval / 60).rounded()))
    }

    /// "in 42m" for something imminent, "at 15:40" for something further off —
    /// a countdown is useful within the hour and useless beyond it.
    private static func clockHint(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "any moment" }
        if delta < 60 * 60 { return "in \(minutes(delta))m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "at " + formatter.string(from: date)
    }
}
