import Foundation
import ClaudePetCore

/// Watches the files the board's reads come from and tells the open boards when they change —
/// see BoardPush. The HQ root (cards, asks, focus, inbox, projects), hq's own folder (its config,
/// and which session is bound to which task) and the pet's state (each session's state file,
/// subagents, what has been read). One FSEvents stream for all of them, running for as long as the
/// app does: while nothing is written it costs nothing. What the board shows from the app's own
/// memory or settings rather than a file is pushed with `nudge`.
@MainActor
final class BoardEvents {
    static let shared = BoardEvents()
    /// Posted on the main thread once the stale reads are dropped; userInfo["n"] counts pushes.
    static let changed = Notification.Name("ClaudePetBoardChanged")

    private var stream: FSEventStreamRef?
    /// The trees the stream watches; set up again when hq's config names another root.
    private var watched: [String] = []
    private var gate = PushGate()
    private var pending: DispatchWorkItem?
    /// Looks once a minute for trees that came or went (hq set up after the pet started: its
    /// folder didn't exist to be watched), or a root changed without hq's config being seen.
    private var recheck: Timer?
    /// Pushes so far.
    private(set) var count = 0
    /// Whether the HQ root is watched: only then may a board rely on pushes and poll slowly.
    var running: Bool { stream != nil && Self.hqRoot().map { watched.contains($0) } == true }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private static var hqHome: String { home + "/.claude/hq" }

    /// The trees to watch: those that exist now. hq's folder is watched whole, so a root set up or
    /// changed while the pet runs is picked up (see `note`).
    static func roots() -> [String] {
        var roots = [hqHome, home + "/.claude/pet"]
        if let root = hqRoot() { roots.insert(root, at: 0) }
        return roots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Where hq keeps its cards: HQ_ROOT, as hq itself reads it first, or the installed config.
    static func hqRoot() -> String? {
        if let env = ProcessInfo.processInfo.environment["HQ_ROOT"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: hqHome + "/config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = obj["root"] as? String, !root.isEmpty else { return nil }
        return (root as NSString).expandingTildeInPath
    }

    func start() {
        if recheck == nil {
            recheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rewatchIfMoved() }
            }
        }
        guard stream == nil else { return }
        let paths = Self.roots()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            // UseCFTypes: the paths come as a CFArray of CFStrings.
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            let marks = (0..<count).map { UInt32(flags[$0]) }
            MainActor.assumeIsolated {
                Unmanaged<BoardEvents>.fromOpaque(info).takeUnretainedValue().note(list, flags: marks)
            }
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        watched = paths
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watched = []
    }

    /// Something the board shows changed without a file saying so (the pet's unread marks and
    /// dots, a setting saved from a board): push as a file change would.
    func nudge() { schedule() }

    private func note(_ paths: [String], flags: [UInt32]) {
        // hq's config was written (a root set up or moved, `hq/install.sh --root`): watch the new one.
        if paths.contains(where: { $0.hasSuffix("/.claude/hq/config.json") || $0 == Self.hqHome }), rewatchIfMoved() {
            return
        }
        let relevant = paths.indices.contains { BoardPush.relevant(paths[$0], flags: $0 < flags.count ? flags[$0] : 0) }
        if relevant { schedule() }
    }

    /// Watches the trees there are now, if they are not the ones watched; then the boards read
    /// again (the new root's cards). Whether it did.
    @discardableResult
    private func rewatchIfMoved() -> Bool {
        guard Self.roots() != watched else { return false }
        stop()
        start()
        schedule()
        return true
    }

    private func schedule() {
        let at = gate.note(Date())
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    private func fire() {
        pending = nil
        gate.fired(Date())
        count += 1
        let n = count
        Task { @MainActor in
            // Dropped first: a board told of the change must not be answered from before it.
            await SharedReads.shared.changed(BoardPush.staleReads)
            NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["n": n])
        }
    }
}
