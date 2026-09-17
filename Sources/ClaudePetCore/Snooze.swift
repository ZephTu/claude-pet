import Foundation

/// Putting one blocked session off for a while.
///
/// Distinct from muting, and the difference matters. Muting says "not this
/// session, not until I talk to it again" and takes it out of the panel
/// entirely. Snoozing says "yes, I know, not right now" — the item stays
/// visible and stays on the list; what stops is the pet waving about it.
///
/// The record is tied to the ITEM, not to the session: a mark stores the
/// `since` of the wait it was applied to. A session that resolves one approval
/// and then blocks on a different one is a new item and gets no inherited
/// delay — being quiet about the thing the user postponed must not make the pet
/// quiet about the next thing.
public enum Snooze {
    public struct Mark: Sendable, Equatable {
        /// When the delay expires.
        public let until: Date
        /// The `since` of the wait this was applied to. A different `since`
        /// means a different item.
        public let waitingSince: Date

        public init(until: Date, waitingSince: Date) {
            self.until = until
            self.waitingSince = waitingSince
        }
    }

    /// The choices offered, in minutes.
    public static let options = [5, 15, 30]

    public static func mark(for session: SessionState, minutes: Int, now: Date) -> Mark {
        Mark(until: now.addingTimeInterval(Double(minutes) * 60), waitingSince: session.since)
    }

    /// Is this session's current wait postponed?
    public static func isSnoozed(_ session: SessionState, marks: [String: Mark], now: Date) -> Bool {
        guard let mark = marks[session.sessionId] else { return false }
        // A new wait is a new item, whatever was postponed before.
        guard mark.waitingSince == session.since else { return false }
        return now < mark.until
    }

    /// How much longer, for the panel to show beside a postponed row. Empty
    /// when it is not postponed: a row with no remaining delay says nothing
    /// rather than saying "0m".
    public static func remaining(_ session: SessionState, marks: [String: Mark], now: Date) -> String {
        guard isSnoozed(session, marks: marks, now: now), let mark = marks[session.sessionId]
        else { return "" }
        return Chatter.duration(until: mark.until, now: now)
    }

    /// Marks worth keeping: the session still exists, the wait it was applied to
    /// is still the current one, and it has not expired.
    ///
    /// Expiry is decided against `now` each time rather than by a timer, which
    /// is what makes sleeping through a snooze harmless: the machine wakes up,
    /// the mark is simply already past, and nothing is replayed.
    public static func pruned(
        _ marks: [String: Mark],
        keeping sessions: [SessionState],
        now: Date
    ) -> [String: Mark] {
        let index = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        return marks.filter { id, mark in
            guard let session = index[id] else { return false }
            return mark.waitingSince == session.since && now < mark.until
        }
    }

    // MARK: - Storage

    public static func decode(_ data: Data) -> [String: Mark] {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let root = raw as? [String: Any],
            let entries = root["snoozed"] as? [String: [String: Any]]
        else { return [:] }

        var marks: [String: Mark] = [:]
        for (id, entry) in entries {
            guard
                let untilText = entry["until"] as? String,
                let until = CompletionQueue.parseDate(untilText),
                let sinceText = entry["waitingSince"] as? String,
                let since = CompletionQueue.parseDate(sinceText)
            else { continue }
            marks[id] = Mark(until: until, waitingSince: since)
        }
        return marks
    }

    public static func encode(_ marks: [String: Mark]) -> Data {
        var entries: [String: [String: String]] = [:]
        for (id, mark) in marks {
            entries[id] = [
                "until": CompletionQueue.format(mark.until),
                "waitingSince": CompletionQueue.format(mark.waitingSince),
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: ["snoozed": entries])) ?? Data()
    }
}
