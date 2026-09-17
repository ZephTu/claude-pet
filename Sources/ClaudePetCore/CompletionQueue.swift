import Foundation

/// One session finishing one turn of work.
///
/// Recorded by pet-emit the moment the `Stop` hook fires, rather than inferred
/// by the app from the difference between two renders. That difference was the
/// only record there used to be, and it was lost in two everyday situations:
/// when another session was blocked (the pet suppresses chatter then) and when
/// the speech cooldown was still running. In both the app advanced its
/// `lastState` anyway, so the finish was gone for good rather than delayed.
public struct CompletionEvent: Sendable, Equatable {
    public let sessionId: String
    /// Identifies WHICH turn finished. Derived from the session's
    /// `lastPromptAt` — the moment the user last spoke — because that is the
    /// one stable marker Claude Code already gives us for a turn.
    public let turnKey: String
    public let project: String
    /// What the session was called when it finished. Stored rather than looked
    /// up later: a terminal tab that has since closed still has a name here.
    public let displayName: String
    public let finishedAt: Date

    public init(sessionId: String, turnKey: String, project: String,
                displayName: String, finishedAt: Date) {
        self.sessionId = sessionId
        self.turnKey = turnKey
        self.project = project
        self.displayName = displayName
        self.finishedAt = finishedAt
    }

    /// Stable across redeliveries of the same turn, and distinct between turns.
    ///
    /// Deliberately NOT a random UUID: a fresh id per write would make every
    /// redelivery look like a new finish, which is exactly the duplicate this
    /// is meant to collapse.
    public var eventId: String { sessionId + "#" + turnKey }
}

/// Reading, de-duplicating and ageing out the recorded finishes.
///
/// Pure, because every rule here is one that only shows itself days later on
/// somebody else's machine: what survives a restart, what is dropped when the
/// queue is full, and whether dropping it was allowed to be silent.
public enum CompletionQueue {
    /// How long a finish stays interesting.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// Hard ceiling on rows, so a machine left running for a month cannot grow
    /// the directory without bound.
    public static let hardLimit = 500

    public struct Pruned: Sendable, Equatable {
        public let keep: [CompletionEvent]
        public let droppedRead: Int
        /// Unread rows that had to go anyway. Non-zero means the user is being
        /// told something was thrown away — losing news quietly is the one
        /// outcome this whole type exists to prevent.
        public let droppedUnread: Int
    }

    /// Parses stored events, skipping anything unreadable.
    ///
    /// A single corrupt file must not take the queue with it: these are written
    /// by a hook that can be killed mid-write, so a truncated file is a normal
    /// event, not an exceptional one.
    public static func decode(_ blobs: [Data]) -> [CompletionEvent] {
        blobs.compactMap(decodeOne).sorted { $0.finishedAt < $1.finishedAt }
    }

    static func decodeOne(_ blob: Data) -> CompletionEvent? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: blob),
            let d = raw as? [String: Any],
            let sessionId = d["sessionId"] as? String, !sessionId.isEmpty,
            let turnKey = d["turnKey"] as? String, !turnKey.isEmpty,
            let stamp = d["finishedAt"] as? String,
            let finishedAt = parseDate(stamp)
        else { return nil }
        let project = d["project"] as? String ?? ""
        let name = d["displayName"] as? String ?? project
        return CompletionEvent(sessionId: sessionId, turnKey: turnKey, project: project,
                               displayName: name, finishedAt: finishedAt)
    }

    public static func encode(_ e: CompletionEvent) -> Data {
        let doc: [String: Any] = [
            "sessionId": e.sessionId,
            "turnKey": e.turnKey,
            "project": e.project,
            "displayName": e.displayName,
            "finishedAt": format(e.finishedAt),
        ]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }

    /// Collapses redeliveries of one turn, keeping the newest reading of it.
    /// Order is preserved by finish time.
    public static func dedupe(_ events: [CompletionEvent]) -> [CompletionEvent] {
        var latest: [String: CompletionEvent] = [:]
        for e in events {
            if let seen = latest[e.eventId], seen.finishedAt >= e.finishedAt { continue }
            latest[e.eventId] = e
        }
        return latest.values.sorted { $0.finishedAt < $1.finishedAt }
    }

    public static func unread(_ events: [CompletionEvent], read: Set<String>) -> [CompletionEvent] {
        events.filter { !read.contains($0.eventId) }
    }

    /// Ages the queue out: past the retention window first, then down to the
    /// hard cap, spending read rows before unread ones.
    public static func prune(_ events: [CompletionEvent], read: Set<String>, now: Date) -> Pruned {
        var droppedRead = 0
        var droppedUnread = 0

        func drop(_ e: CompletionEvent) {
            if read.contains(e.eventId) { droppedRead += 1 } else { droppedUnread += 1 }
        }

        let sorted = events.sorted { $0.finishedAt < $1.finishedAt }
        var live: [CompletionEvent] = []
        for e in sorted {
            if now.timeIntervalSince(e.finishedAt) > retention { drop(e) } else { live.append(e) }
        }

        guard live.count > hardLimit else {
            return Pruned(keep: live, droppedRead: droppedRead, droppedUnread: droppedUnread)
        }

        // Over the cap. Spend the oldest READ rows first — they have served
        // their purpose — and only then start on unread ones, oldest first.
        var over = live.count - hardLimit
        var survivors: [CompletionEvent] = []
        var reserve: [CompletionEvent] = []
        for e in live {
            if over > 0, read.contains(e.eventId) {
                drop(e); over -= 1
            } else {
                reserve.append(e)
            }
        }
        for e in reserve {
            if over > 0 { drop(e); over -= 1 } else { survivors.append(e) }
        }
        return Pruned(keep: survivors, droppedRead: droppedRead, droppedUnread: droppedUnread)
    }

    // MARK: - Time

    /// Matches the format pet-emit writes, and tolerates the fractional-second
    /// variant in case a future writer emits one.
    public static func parseDate(_ s: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// A file name for one event: stable per turn, so redelivering a turn
    /// overwrites its file instead of adding a second one, and safe as a path
    /// component whatever the session id contains.
    public static func fileName(for e: CompletionEvent) -> String {
        sanitise(e.sessionId) + "~" + sanitise(e.turnKey) + ".json"
    }

    static func sanitise(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = s.map { ok.contains($0) ? $0 : "_" }
        return String(mapped)
    }
}
