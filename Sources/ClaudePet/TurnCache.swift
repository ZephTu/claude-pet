import Foundation
import ClaudePetCore

/// Turn counts for the sessions on screen, read from their transcripts off the
/// main thread.
///
/// The first read of a long session goes through its whole transcript, which
/// can be a hundred megabytes; after that each read only covers what was
/// appended since — see TurnCount.
@MainActor
final class TurnCache {
    private var progress: [String: TurnCount.Progress] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "claudepet.turns", qos: .utility)

    /// Called when a count changes, so the panel can be redrawn.
    var onUpdate: (() -> Void)?

    /// sessionId → turns, for the sessions whose transcript has been read.
    /// Kicks off a read for each one, which costs nothing when the file has
    /// not grown.
    func turns(for sessions: [SessionState]) -> [String: Int] {
        var out: [String: Int] = [:]
        for session in sessions {
            let path = session.transcript.isEmpty
                ? TurnCount.defaultTranscript(cwd: session.cwd, sessionId: session.sessionId,
                                              home: NSHomeDirectory())
                : session.transcript
            if let turns = progress[path]?.turns, turns > 0 { out[session.sessionId] = turns }
            load(path)
        }
        return out
    }

    private func load(_ path: String) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let before = progress[path] ?? TurnCount.Progress()
        queue.async {
            // Mapped, not read: only the pages past `offset` are touched.
            let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            let after = data.map { TurnCount.advance(before, through: $0) } ?? before
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight.remove(path)
                    self.progress[path] = after
                    if after.turns != before.turns { self.onUpdate?() }
                }
            }
        }
    }
}
