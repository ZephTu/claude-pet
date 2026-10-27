import Foundation

/// A session going round in circles: working on paper, failing in fact.
///
/// The pet could already say a session was busy and for how long. What it could
/// not say is that the last several things it tried all failed — the same test
/// run, the same build, again — which looks exactly like steady work from the
/// corner of the screen and is exactly when a person should step in.
///
/// Measured from what Claude Code itself reports: consecutive PostToolUseFailure
/// events with no success between them. Nothing is inferred from output.
public enum Struggle {
    /// Three in a row is an ordinary red-green loop; four starts to be a rut.
    public static let threshold = 4

    public static func isStruggling(_ s: SessionState) -> Bool {
        s.state == .busy && s.failStreak >= threshold
    }

    /// Sessions that crossed the line since the last render — the moment worth
    /// one line, not every render they stay over it.
    public static func justStarted(previous: GlobalState, current: GlobalState) -> [SessionState] {
        let before = Dictionary(previous.sessions.map { ($0.sessionId, $0.failStreak) },
                                uniquingKeysWith: { a, _ in a })
        return current.sessions.filter { session in
            isStruggling(session) && (before[session.sessionId] ?? 0) < threshold
        }
    }

    /// "tg-server: 4 failed in a row — Bash npm test"
    public static func line(_ session: SessionState, name: String) -> String {
        let what = session.failTarget.isEmpty ? "" : " — " + session.failTarget
        return "\(name): \(session.failStreak) failed in a row\(what)"
    }
}
