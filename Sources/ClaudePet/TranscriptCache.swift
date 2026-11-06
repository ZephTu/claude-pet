import Foundation
import ClaudePetCore

/// Turn counts and context fill for the sessions on screen, read from their
/// transcripts off the main thread.
///
/// The first read of a long session goes through its whole transcript, which
/// can be a hundred megabytes; after that each read only covers what was
/// appended since — see TranscriptStats.
@MainActor
final class TranscriptCache {
    private var progress: [String: TranscriptStats.Progress] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "claudepet.transcripts", qos: .utility)

    /// Called when a reading changes, so the panel can be redrawn.
    var onUpdate: (() -> Void)?

    /// sessionId → what its transcript says, for the ones read so far. Kicks
    /// off a read for each session, which costs nothing when the file has not
    /// grown.
    func stats(for sessions: [SessionState]) -> [String: TranscriptStats.Progress] {
        var out: [String: TranscriptStats.Progress] = [:]
        for session in sessions {
            let path = session.transcript.isEmpty
                ? TranscriptStats.defaultTranscript(cwd: session.cwd, sessionId: session.sessionId,
                                                    home: NSHomeDirectory())
                : session.transcript
            if let read = progress[path] { out[session.sessionId] = read }
            load(path)
        }
        return out
    }

    private func load(_ path: String) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let before = progress[path] ?? TranscriptStats.Progress()
        queue.async {
            // Mapped, not read: only the pages past `offset` are touched.
            let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            let after = data.map { TranscriptStats.advance(before, through: $0) } ?? before
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight.remove(path)
                    self.progress[path] = after
                    if after.turns != before.turns || after.contextPercent != before.contextPercent {
                        self.onUpdate?()
                    }
                }
            }
        }
    }
}
