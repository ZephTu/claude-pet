import Foundation

/// What happened while nobody was at the keyboard, said once on the way back.
///
/// Coming back to a desk full of sessions means opening each one to find out
/// which finished, which is stuck on a prompt and how much quota went. The pet
/// already knows all three; this puts them in one line at the one moment they
/// are wanted.
///
/// "Away" is measured from the machine's own input idle time, so it covers a
/// locked screen, a meeting and a lunch alike, and needs no permission.
public enum AwayReport {
    /// Shorter than this is reading something, not being away.
    public static let awayAfter: TimeInterval = 10 * 60
    /// Input within this long means the person is back.
    public static let backWithin: TimeInterval = 5

    /// One waiting session, as the report names it.
    public struct Waiting: Sendable, Equatable {
        public let name: String
        public let waited: TimeInterval

        public init(name: String, waited: TimeInterval) {
            self.name = name
            self.waited = waited
        }
    }

    /// - Parameters:
    ///   - away: how long nobody touched the machine.
    ///   - finished: turns that ended in that time.
    ///   - waiting: sessions blocked on the user right now, longest first.
    ///   - quotaUsed: five-hour quota points spent while away, nil when unknown.
    /// - Returns: nil when nothing happened worth a line — coming back to "you
    ///   were away 40m" and nothing else is noise.
    public static func line(away: TimeInterval, finished: Int, waiting: [Waiting],
                            quotaUsed: Int?) -> String? {
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        if let first = waiting.first {
            var part = "\(first.name) waiting \(span(first.waited))"
            if waiting.count > 1 { part += " (+\(waiting.count - 1))" }
            parts.append(part)
        }
        if let quotaUsed, quotaUsed > 0 { parts.append("quota +\(quotaUsed)%") }
        guard !parts.isEmpty else { return nil }
        return "While you were away (\(span(away))): " + parts.joined(separator: " · ")
    }

    /// "42m", "1h 5m" — the same wording as every other duration the pet says.
    static func span(_ interval: TimeInterval) -> String {
        Chatter.duration(until: Date(timeIntervalSinceReferenceDate: interval),
                         now: Date(timeIntervalSinceReferenceDate: 0))
    }
}
