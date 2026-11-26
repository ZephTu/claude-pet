import Foundation
import ClaudePetCore

/// Watches the files the board's reads come from and tells the open boards when they change —
/// see BoardPush. The HQ root (cards, asks, focus, inbox, projects), hq's own state (which session
/// is bound to which task) and the pet's state (each session's state file, subagents, what has
/// been read). One FSEvents stream for all of them, running for as long as the app does: while
/// nothing is written it costs nothing.
@MainActor
final class BoardEvents {
    static let shared = BoardEvents()
    /// Posted on the main thread once the stale reads are dropped; userInfo["n"] counts pushes.
    static let changed = Notification.Name("ClaudePetBoardChanged")

    private var stream: FSEventStreamRef?
    private var gate = PushGate()
    /// Pushes so far.
    private(set) var count = 0
    var running: Bool { stream != nil }

    /// The trees to watch: those that exist now. (A root set up later is picked up next launch.)
    static func roots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = [home + "/.claude/hq/state", home + "/.claude/pet"]
        if let root = hqRoot() { roots.insert(root, at: 0) }
        return roots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Where hq keeps its cards: HQ_ROOT, as hq itself reads it first, or the installed config.
    static func hqRoot() -> String? {
        if let env = ProcessInfo.processInfo.environment["HQ_ROOT"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/hq/config.json")
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = obj["root"] as? String, !root.isEmpty else { return nil }
        return (root as NSString).expandingTildeInPath
    }

    func start() {
        guard stream == nil else { return }
        let paths = Self.roots()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // UseCFTypes: the paths come as a CFArray of CFStrings.
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            _ = count
            MainActor.assumeIsolated {
                Unmanaged<BoardEvents>.fromOpaque(info).takeUnretainedValue().note(list)
            }
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    private func note(_ paths: [String]) {
        guard paths.contains(where: BoardPush.relevant), let at = gate.note(Date()) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow)) { [self] in
            MainActor.assumeIsolated { fire() }
        }
    }

    private func fire() {
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
