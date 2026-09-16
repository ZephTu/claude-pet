import Foundation
import ClaudePetCore

/// Watches ~/.claude/pet/sessions/ and re-reads every state file when it changes.
///
/// Re-reading the whole directory on any event is deliberate — it is immune to
/// missed events — but it is only cheap because this class also *reaps* the
/// directory: a session file whose `updatedAt` is older than the dead-session
/// timeout is deleted on sight (design doc section 3: the pet app reaps them).
/// Without that, the design doc's own figure of 51 session files per 10 hours
/// turns into thousands a month, all of them re-read on every burst.
///
/// The read/decode/delete pass runs off the main thread; only the callback hops
/// back. The whole class is MainActor-isolated on purpose: the FSEvents stream
/// is pumped on the main queue and every caller is on the main thread already.
/// Without the isolation, Swift 6 rejects the callback with
/// "sending 'self' risks causing data races" — verified, not theoretical.
@MainActor
final class SessionWatcher {
    private let directory: URL
    private let onChange: ([SessionState]) -> Void
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    /// Scans run concurrently; only the newest result may be delivered.
    private var generation = 0

    init(directory: URL, onChange: @escaping ([SessionState]) -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // Safe: the stream is dispatched on the main queue a few lines below.
            MainActor.assumeIsolated {
                Unmanaged<SessionWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleRescan()
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,  // coalesce bursts; hooks fire in clusters
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }

        rescan()  // pick up sessions that were already running
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Coalesce rapid-fire hook writes into one rescan.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        generation &+= 1
        let mine = generation
        let dir = directory
        let now = Date()
        Task.detached(priority: .utility) {
            let states = Self.scan(directory: dir, now: now)
            await MainActor.run { self.deliver(states, from: mine) }
        }
    }

    private func deliver(_ states: [SessionState], from generation: Int) {
        guard generation == self.generation else { return }  // a newer scan already landed
        onChange(states)
    }

    /// Reads every state file and deletes the dead ones. Runs off the main thread.
    nonisolated private static func scan(directory: URL, now: Date) -> [SessionState] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        var states: [SessionState] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let state = SessionState.decode(from: data)
            else {
                // A file we cannot parse is only reaped once it is older than any
                // live session could be, so a file caught mid-write is never lost.
                if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                   now.timeIntervalSince(modified) > StateAggregator.deadAfter {
                    try? fm.removeItem(at: url)
                }
                continue
            }

            // Same rule as StateAggregator, so the panel and the directory can
            // never disagree about which sessions exist. Crucially this now asks
            // whether the process is alive: reaping on elapsed time deleted the
            // files of sessions that were merely sitting idle, and a deleted file
            // does not come back when the user starts typing again.
            if !StateAggregator.isLive(state, now: now) {
                try? fm.removeItem(at: url)
                continue
            }
            states.append(state)
        }
        return states
    }
}
