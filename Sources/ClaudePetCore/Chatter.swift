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
        case struggling
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

    /// How long each "this one finished" notice stays up, unless the user
    /// picked another of `noticeHoldChoices` under Settings.
    ///
    /// These used to be ONE sticky bubble, and that is how they got lost: two
    /// sessions finishing a few seconds apart shared the bubble, the second
    /// replaced the first, and a third inside the 20s cooldown was never said
    /// at all. Each finish now gets its own notice in a small stack above the
    /// pet (see window.notify), and each keeps it for this long whatever
    /// arrives after it. The Finished list still holds every one of them.
    public static let noticeHold: TimeInterval = 30
    public static let noticeHoldChoices: [TimeInterval] = [10, 30, 60]

    /// How many notices can be up at once, unless the user picked fewer.
    public static let noticeCount = 3
    public static let noticeCountChoices = [1, 2, 3]

    /// A stored hold, or the default when it is missing or not one on offer —
    /// a hand-edited preference must not leave a notice up for an hour.
    public static func noticeHold(stored: Double) -> TimeInterval {
        noticeHoldChoices.contains(stored) ? stored : noticeHold
    }

    public static func noticeCount(stored: Int) -> Int {
        noticeCountChoices.contains(stored) ? stored : noticeCount
    }

    /// Which kind of message window a line belongs in.
    ///
    /// The bubble is ONE element with one variant class at a time, rather than
    /// three components competing for the same corner — the pet has one mouth.
    /// Naming the variant here, next to the kinds themselves, is what stops the
    /// page from having to re-derive "is this an alarm or a pleasantry" out of
    /// the text it was handed.
    ///
    /// The order below is the priority order, and it is the same one the page
    /// enforces: an alert is never replaced by a notice, a notice never by
    /// chatter. `alert` is absent because nothing in `Kind` can produce one —
    /// intervention comes from the mood, not from a spoken line.
    public enum Bubble: String, Sendable, Equatable {
        /// Quota past a threshold, or about to roll over.
        case warn
        /// A turn or a session came to rest.
        case notice
        /// Remarks on work running long.
        case chat
    }

    /// Does this kind of message step aside while the session list is open?
    ///
    /// The bubble hangs above the pet and the list opens to the pet's left, so
    /// with enough rows on screen the two share a corner — which is how a
    /// completion notice ended up sitting on the list's own top-right, its text
    /// tangled with the `clear` control underneath it.
    ///
    /// Yielding rather than moving, for the two kinds whose news the list is
    /// already carrying: a finished turn IS a row in Finished, and chatter is
    /// not news at all. A quota warning stays, because nothing in the list says
    /// it; so does the alarm, which outranks everything by definition.
    ///
    /// Yielding is a DISPLAY decision and nothing more. Nothing is marked read,
    /// no queue is touched, and the line is not recorded as having been said —
    /// so when the list closes, the next render decides again from the state of
    /// the world at that moment rather than replaying something stale.
    public static func yieldsToList(_ bubble: Bubble) -> Bool {
        switch bubble {
        case .notice, .chat: return true
        case .warn: return false
        }
    }

    public static func bubble(for kind: Kind) -> Bubble {
        switch kind {
        case .quotaHigh, .quotaResetting, .struggling: return .warn
        case .finished, .sessionDone: return .notice
        case .longRun: return .chat
        }
    }

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
        // Per kind, not per session: a second session falling into a rut ten
        // minutes later is worth hearing about, the same one every render is not.
        case .struggling: return 10 * 60
        }
    }

    /// Say something when the five-hour window is this close to rolling over.
    public static let resetSoon: TimeInterval = 15 * 60
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
        names: [String: String] = [:],
        quotaAlarm: QuotaAlarm.Alarm? = nil
    ) -> Utterance? {
        // The bubble belongs to the alarm while something is actually blocked,
        // and a session waiting on the user is not a moment for small talk.
        guard state.mood != .urgent, state.mood != .waiting else { return nil }

        // Finishing sessions are announced separately, one notice each — see
        // `doneNotices`. Here they only stop the generic "Done" from saying the
        // same thing again in the main bubble.
        let finishedNow = previous.map { justFinished(previous: $0, current: state) } ?? []
        // A session that has just failed four times running is the other thing
        // worth breaking the global gap for: it is the moment to step in.
        let stuck = previous.map { Struggle.justStarted(previous: $0, current: state) } ?? []
        let hasTrouble = !stuck.isEmpty && Self.ready(.struggling, lastSpoken: lastSpoken, now: now)
        if !hasTrouble, let lastAnything,
           now.timeIntervalSince(lastAnything) < globalCooldown {
            return nil
        }

        func ready(_ kind: Kind) -> Bool { Self.ready(kind, lastSpoken: lastSpoken, now: now) }

        if hasTrouble, let first = stuck.first {
            let name = names[first.sessionId] ?? first.project
            return Utterance(kind: .struggling, text: Struggle.line(first, name: name),
                             emphasis: name)
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
            // Quota warnings are decided by QuotaAlarm, which fires on CROSSING
            // a threshold rather than on sitting above one. They are handed in
            // by the caller because saying one has to be recorded, and Chatter
            // is pure.
            if let alarm = quotaAlarm {
                return Utterance(kind: .quotaHigh, text: alarm.text)
            }
        }

        guard let previous else { return nil }

        // Everything below is a transition, so it needs a previous state to
        // compare against.
        if ready(.finished), finishedNow.isEmpty, previous.mood == .busy, state.mood == .idle,
           !onlyWentQuiet(previous: previous, current: state, now: now) {
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
        var rows: [QuotaRow] = []
        // A window that has rolled over is not shown as a number. The reading
        // describes a window that no longer exists, and the honest replacement
        // is not 0% — the user may have spent plenty of the new one since.
        if !usage.fiveHourWindowRolledOver(now: now) {
            rows.append(QuotaRow(label: "5h", percent: clampPercent(usage.fiveHourPercent),
                                 resetsIn: duration(until: usage.fiveHourResetAt, now: now)))
        }
        if !usage.sevenDayWindowRolledOver(now: now) {
            rows.append(QuotaRow(label: "week", percent: clampPercent(usage.sevenDayPercent),
                                 resetsIn: duration(until: usage.sevenDayResetAt, now: now)))
        }
        return rows
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

    /// Did the busy sessions merely fall silent, rather than come to rest?
    ///
    /// Going quiet drops the mood out of busy exactly the way finishing does, so
    /// this is what tells the two apart. A session that ended, or that went away
    /// with its terminal, is a finish and keeps its line; one still sitting at
    /// `busy` that has simply stopped saying anything is a turn somebody
    /// interrupted, and announcing "all done" about it is the same lie the row
    /// was telling before any of this.
    private static func onlyWentQuiet(previous: GlobalState, current: GlobalState,
                                      now: Date) -> Bool {
        let wasBusy = previous.sessions.filter { $0.state == .busy }
        guard !wasBusy.isEmpty else { return false }
        return wasBusy.allSatisfy { old in
            guard let still = current.sessions.first(where: { $0.sessionId == old.sessionId })
            else { return false }
            return still.state == .busy && StateAggregator.isQuiet(still, now: now)
        }
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
    /// How much of Claude's last line the bubble repeats. The bubble is a
    /// corner of the screen, not a row; the full line is in the list.
    public static let summaryInBubble = 60

    /// A "this session finished" notice, and which session it is about — so a
    /// click on it can go there.
    public struct DoneNotice: Sendable, Equatable {
        public let sessionId: String
        public let text: String
        public let emphasis: String
    }

    /// One notice per session that just came to rest, oldest first.
    ///
    /// Not rate-limited: each is a real transition and cannot run away on its
    /// own, and a cooldown here is exactly what used to swallow the second of
    /// two sessions finishing close together.
    public static func doneNotices(previous: GlobalState?, current: GlobalState,
                                   names: [String: String] = [:],
                                   summaries: [String: String] = [:]) -> [DoneNotice] {
        guard let previous else { return [] }
        return justFinished(previous: previous, current: current).map { session in
            let name = names[session.sessionId] ?? session.project
            return DoneNotice(sessionId: session.sessionId,
                              text: doneText(session, name: name,
                                             summary: summaries[session.sessionId] ?? ""),
                              emphasis: name)
        }
    }

    /// - Parameter summary: the first line of what Claude said last. Said
    ///   instead of a bare "done", because "tests pass" and "I am stuck" are
    ///   the difference between needing to look and not.
    public static func doneText(_ session: SessionState, name: String, summary: String) -> String {
        guard !summary.isEmpty else { return name + " done" }
        let short = summary.count > summaryInBubble
            ? String(summary.prefix(summaryInBubble - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : summary
        return name + ": " + short
    }

    // MARK: - Wording

    private static func finishedLine(count: Int) -> String {
        count > 1 ? "All \(count) done" : "Done"
    }

    /// The session that has been busy longest — skipping any that has gone
    /// quiet, because "still at it after half an hour" is a claim about work in
    /// progress and a silent session is not evidence of any.
    private static func longestBusy(_ sessions: [SessionState], now: Date) -> SessionState? {
        sessions
            .filter { $0.state == .busy && !StateAggregator.isQuiet($0, now: now) }
            .min { $0.since < $1.since }
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
