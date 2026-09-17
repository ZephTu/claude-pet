import Foundation

/// One line in the panel's "finished" group.
///
/// Several turns of one session collapse into a single row: a session that
/// finished four times while the user was away is one thing to look at, not
/// four. Marking it read marks all of them, which is why it carries every id.
public struct CompletionRow: Sendable, Equatable {
    public let sessionId: String
    /// Every event this row stands for, newest last.
    public let eventIds: [String]
    /// What to call it: the live terminal's tab title when there is one, else
    /// the name recorded at the time it finished.
    public let label: String
    public let latestAt: Date
    /// How many turns are folded in here.
    public var count: Int { eventIds.count }
    /// The session is gone. The row stays — the work still happened — but it
    /// cannot be jumped to and says so rather than failing on click.
    public let sessionClosed: Bool
    public let terminal: TerminalRef?

    public init(sessionId: String, eventIds: [String], label: String, latestAt: Date,
                sessionClosed: Bool, terminal: TerminalRef?) {
        self.sessionId = sessionId
        self.eventIds = eventIds
        self.label = label
        self.latestAt = latestAt
        self.sessionClosed = sessionClosed
        self.terminal = terminal
    }

    public var canJump: Bool {
        guard let terminal, !sessionClosed else { return false }
        return TerminalTarget.canJump(kind: terminal.kind)
    }
}

/// How the expanded panel is laid out.
///
/// Pure, and separate from the session list, because the two answer different
/// questions: the session list is what is happening now, the finished list is
/// what happened while you were not looking. The second one cannot be derived
/// from the first — that was the bug.
public enum PanelModel {
    /// Sessions that want the user to do something, in the order they should be
    /// dealt with: longest wait first.
    public static func needsYou(_ sessions: [SessionState]) -> [SessionState] {
        sessions.filter { $0.state == .waiting }.sorted { $0.since < $1.since }
    }

    /// Everything else that is live.
    public static func others(_ sessions: [SessionState]) -> [SessionState] {
        sessions.filter { $0.state != .waiting }
    }

    /// Folds unread finishes into one row per session, newest session first.
    ///
    /// - Parameters:
    ///   - unread: the finishes the user has not acknowledged.
    ///   - live: sessions still running, used to decide whether a row can be
    ///     jumped to and whether to mark it as closed.
    ///   - titles: terminal handle → tab title, so a row is named the same way
    ///     its session row is.
    public static func completionRows(
        _ unread: [CompletionEvent],
        live: [SessionState],
        titles: [String: String] = [:]
    ) -> [CompletionRow] {
        let bySession = Dictionary(grouping: unread, by: \.sessionId)
        let index = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })

        var rows: [CompletionRow] = []
        for (sessionId, events) in bySession {
            let ordered = events.sorted { $0.finishedAt < $1.finishedAt }
            guard let newest = ordered.last else { continue }
            let session = index[sessionId]
            rows.append(CompletionRow(
                sessionId: sessionId,
                eventIds: ordered.map(\.eventId),
                label: label(for: newest, session: session, titles: titles),
                latestAt: newest.finishedAt,
                sessionClosed: session == nil,
                terminal: session?.terminal
            ))
        }
        return rows.sorted { $0.latestAt > $1.latestAt }
    }

    /// The tab title when the session is still there to have one, otherwise the
    /// name recorded when it finished. A closed session keeps the name it had.
    static func label(for event: CompletionEvent, session: SessionState?,
                      titles: [String: String]) -> String {
        if let handle = session?.terminal?.handle,
           let title = titles[handle], !TerminalTitles.isUseless(title) {
            return title
        }
        let recorded = event.displayName.isEmpty ? event.project : event.displayName
        return recorded.isEmpty ? event.sessionId : recorded
    }

    /// Where a "take me to the next thing" shortcut should land.
    ///
    /// The oldest unresolved wait that is not postponed — the one that has been
    /// ignored longest. Deliberately NOT "the oldest one we can jump to": if the
    /// most neglected session is in a terminal we cannot address, the honest
    /// answer is to say so, not to quietly send the user somewhere else and let
    /// them believe that was the thing waiting.
    public static func jumpTarget(
        _ sessions: [SessionState],
        snoozed: [String: Snooze.Mark],
        now: Date
    ) -> SessionState? {
        needsYou(sessions)
            .first { !Snooze.isSnoozed($0, marks: snoozed, now: now) }
    }

    /// Should the row repeat the session's name on its second line?
    ///
    /// Only when the first column is not already showing it. This predates the
    /// first column being able to choose its own name: back then it was always
    /// a directory, so three sessions in one repo needed the title spelled out
    /// underneath. Now the title usually IS the first column, and printing it
    /// again underneath was simply saying it twice.
    ///
    /// - Parameters:
    ///   - displayed: what the first column ended up showing.
    ///   - title: the terminal tab title, if there is a usable one.
    ///   - ambiguous: whether this session's project is shared with another.
    public static func shouldShowNameInline(displayed: String, title: String,
                                            ambiguous: Bool) -> Bool {
        guard ambiguous, !title.isEmpty, !TerminalTitles.isUseless(title) else { return false }
        return displayed != title
    }

    /// What the pet wears on its chest: how many sessions want something, and
    /// how many finishes have not been looked at.
    ///
    /// Zero is not a badge — an empty count still draws the eye, and the whole
    /// point of this pet is to be quiet when there is nothing to say.
    public static func badge(needsYou: Int, unreadFinishes: Int) -> String {
        let n = needsYou + unreadFinishes
        if n <= 0 { return "" }
        return n > 99 ? "99+" : String(n)
    }
}

/// The user's acknowledgement of finished turns.
public enum ReadMarks {
    public static func decode(_ data: Data) -> Set<String> {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let ids = (raw as? [String: Any])?["read"] as? [String]
        else { return [] }
        return Set(ids)
    }

    public static func encode(_ ids: Set<String>) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["read": ids.sorted()])) ?? Data()
    }

    /// Drops marks for events that no longer exist.
    ///
    /// Without this the file grows forever: every finish ever acknowledged would
    /// keep its id long after the event itself aged out of the queue.
    public static func compact(_ ids: Set<String>, keeping events: [CompletionEvent]) -> Set<String> {
        let alive = Set(events.map(\.eventId))
        return ids.intersection(alive)
    }
}
