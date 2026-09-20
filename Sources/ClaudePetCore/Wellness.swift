import Foundation

/// The two things the pet says about the person instead of about the work: one
/// line to start the day on, and a nudge when nobody has left their chair in
/// hours.
///
/// This is the one corner of the pet where the governing rule in `Chatter` —
/// that speech needs an OCCASION and nothing fires on a timer alone — is under
/// real pressure, because "you have been sitting too long" is a clock by
/// nature. The way out is to make the clock an OBSERVATION: `DeskClock` is not
/// a countdown, it is how long the machine has had someone at it without a
/// break, measured from the sessions themselves. A pet that spent the morning
/// on a closed laptop has nothing to say about your morning.
///
/// Pure, like `Chatter`, and for the same reason: every threshold below is a
/// test case, and none of them can be checked by looking at them.
public enum Wellness {
    /// How long every session may go without a sign of life before whoever was
    /// here counts as having got up and walked away.
    ///
    /// Half an hour is long on purpose. The only evidence available is session
    /// activity, so an hour spent reading code with Claude untouched looks
    /// exactly like an hour spent at lunch. Erring long means a reminder
    /// sometimes arrives late; erring short means the pet tells an empty chair
    /// to stretch, and then tells its owner they have been sitting for twenty
    /// minutes when they have been sitting for three hours.
    public static let breakAfter: TimeInterval = 30 * 60

    /// How long unbroken at the desk before it is worth mentioning.
    public static let sitLongAfter: TimeInterval = 2 * 3600

    /// One unbroken stretch at the desk.
    ///
    /// A value type that is replaced rather than mutated, so a render that
    /// decides nothing still leaves the previous reading intact.
    public struct DeskClock: Sendable, Equatable {
        /// When the current stretch began, or nil when nobody is here.
        public let startedAt: Date?
        /// The newest sign of life seen so far, which is what the next gap is
        /// measured from.
        public let lastActive: Date?

        public init(startedAt: Date? = nil, lastActive: Date? = nil) {
            self.startedAt = startedAt
            self.lastActive = lastActive
        }

        public func sitting(now: Date) -> TimeInterval {
            guard let startedAt else { return 0 }
            return max(0, now.timeIntervalSince(startedAt))
        }
    }

    /// The newest moment any session showed a sign of life — as close as this
    /// app gets to watching a keyboard.
    ///
    /// Takes the raw session list rather than a `GlobalState` on purpose. The
    /// clock is a claim about the person, and the person is still at their desk
    /// while the pet is paused or while every session is muted — both of which
    /// hand the renderer a state with no sessions in it.
    public static func lastSign(_ sessions: [SessionState]) -> Date? {
        sessions.map(\.updatedAt).max()
    }

    /// Fold one render into the stretch, returning a new clock.
    ///
    /// Two ways a break can be spotted, and both are needed. A pet that ran
    /// throughout sees the gap grow against `now` while the chair is empty. A
    /// pet that was paused, asleep or shut down sees nothing at all and then one
    /// fresh sign of life — so the gap between two consecutive signs is checked
    /// as well, and the stretch is not allowed to swallow the hours in between.
    public static func advance(_ clock: DeskClock, sessions: [SessionState],
                               now: Date) -> DeskClock {
        guard let sign = lastSign(sessions), now.timeIntervalSince(sign) <= breakAfter else {
            return DeskClock()
        }
        guard let startedAt = clock.startedAt, let lastActive = clock.lastActive else {
            return DeskClock(startedAt: sign, lastActive: sign)
        }
        if sign.timeIntervalSince(lastActive) > breakAfter {
            return DeskClock(startedAt: sign, lastActive: sign)
        }
        return DeskClock(startedAt: startedAt, lastActive: max(lastActive, sign))
    }

    /// A line the pet has earned the right to say, for `Chatter` to place
    /// against everything else competing for the bubble.
    public struct Nudge: Sendable, Equatable {
        public let kind: Chatter.Kind
        public let text: String

        public init(kind: Chatter.Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Local day number since the epoch. What makes the day's line stable from
    /// one render to the next and different tomorrow, without a random seed that
    /// would make it untestable.
    public static func day(_ date: Date, calendar: Calendar = .current) -> Int {
        Int((calendar.startOfDay(for: date).timeIntervalSince1970 / 86400).rounded(.down))
    }

    /// - Parameters:
    ///   - working: is any session actually working right now? The greeting is
    ///     attached to this rather than to the instant a session starts, because
    ///     a transition lives for exactly one render and would be lost the
    ///     moment anything else — a cooldown, a quota line — got in front of it.
    ///     As a condition it simply waits until the bubble is free.
    ///   - greetedDay: the day number already greeted, persisted across
    ///     restarts. Nil means the pet has not greeted anyone yet.
    ///   - quotes: the corpus from `quotes.json`; empty falls back to built-ins.
    public static func nudge(
        clock: DeskClock,
        working: Bool,
        greetedDay: Int?,
        quotes: [String],
        language: Phrases.Language,
        now: Date,
        calendar: Calendar = .current
    ) -> Nudge? {
        let today = day(now, calendar: calendar)
        if working, greetedDay != today {
            return Nudge(kind: .greeting,
                         text: Phrases.greeting(quotes: quotes, day: today, language: language))
        }

        let sitting = clock.sitting(now: now)
        guard sitting >= sitLongAfter else { return nil }
        // Bucketed by the nudge's own cooldown so two consecutive nudges land in
        // different buckets and therefore ask for different things.
        let bucket = Int(now.timeIntervalSince1970 / Chatter.cooldown(for: .sitLong))
        return Nudge(
            kind: .sitLong,
            text: Phrases.sitLong(hours: Int(sitting / 3600), variant: bucket, language: language)
        )
    }
}
