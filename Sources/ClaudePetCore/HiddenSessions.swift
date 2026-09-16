import Foundation

/// Which sessions the user has muted, and when they come back.
///
/// Muting is not a toggle the user has to remember to undo. A muted session
/// reappears the moment the user types into it again — that is the whole design:
/// "I don't want to see this one until I'm actually talking to it again". The
/// session doing things on its own (running tools, finishing a turn) must NOT
/// bring it back, or a long-running job would un-mute itself immediately.
///
/// The record is the session's `lastPromptAt` AT THE MOMENT IT WAS MUTED, not
/// the time of muting. Comparing against the user's own last utterance is what
/// makes "has the user spoken since?" answerable at all — wall-clock time would
/// un-mute a session the instant the user typed anywhere, including before
/// muting it.
public enum HiddenSessions {
    /// Stands in for "this session had never been typed into when it was muted",
    /// so that any prompt at all is later seen as newer.
    public static let neverPrompted = Date(timeIntervalSince1970: 0)

    /// The value to store when muting `session`.
    public static func mark(for session: SessionState) -> Date {
        session.lastPromptAt ?? neverPrompted
    }

    /// Should this session be kept out of the panel and out of the pet's mood?
    ///
    /// - Parameter marks: sessionId → the mark recorded when it was muted.
    public static func isHidden(_ session: SessionState, marks: [String: Date]) -> Bool {
        guard let mark = marks[session.sessionId] else { return false }
        guard let spokenAt = session.lastPromptAt else {
            // Muted, and still never been spoken to.
            return true
        }
        // Strictly newer: re-muting a session records its current prompt time, so
        // equality has to mean "still muted" or muting would not stick.
        return spokenAt <= mark
    }

    /// Drops marks for sessions that no longer exist, so the store does not grow
    /// without bound as sessions come and go. Sessions are addressed by uuid, so
    /// a departed id is never reused and its mark can never apply again.
    public static func pruned(
        _ marks: [String: Date],
        keeping sessions: [SessionState]
    ) -> [String: Date] {
        let live = Set(sessions.map(\.sessionId))
        return marks.filter { live.contains($0.key) }
    }
}
