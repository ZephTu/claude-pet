import Foundation
import ClaudePetCore

/// Branch names for session directories, resolved off the main thread and
/// remembered.
///
/// Reads `.git/HEAD` directly instead of running `git`: no subprocess, it works
/// the same inside a worktree (where `.git` is a file pointing elsewhere), and
/// it cannot block the UI on a repository that is busy.
///
/// Explicitly NOT done inside the hook. A hook runs on every event of every
/// session, and the pet is not allowed to tax the thing it is watching.
@MainActor
final class GitCache {
    /// How long a branch reading stays good. Branches change rarely, and a
    /// stale one for a minute is cheaper than reading a file every render.
    private static let ttl: TimeInterval = 60

    private struct Entry {
        let branch: String
        let readAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "claudepet.git", qos: .utility)

    /// Called when a reading arrives, so the panel can be redrawn.
    var onUpdate: (() -> Void)?

    /// The branch for this directory, or "" while it is still being read.
    /// Kicks off a read when the answer is missing or stale.
    func branch(for cwd: String, now: Date = Date()) -> String {
        guard !cwd.isEmpty else { return "" }
        if let entry = entries[cwd] {
            if now.timeIntervalSince(entry.readAt) < Self.ttl { return entry.branch }
        }
        load(cwd)
        return entries[cwd]?.branch ?? ""
    }

    private func load(_ cwd: String) {
        guard !inFlight.contains(cwd) else { return }
        inFlight.insert(cwd)
        queue.async {
            let branch = Self.readBranch(cwd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight.remove(cwd)
                    let previous = self.entries[cwd]?.branch
                    self.entries[cwd] = Entry(branch: branch, readAt: Date())
                    if previous != branch { self.onUpdate?() }
                }
            }
        }
    }

    /// Walks up from `cwd` looking for `.git`, then resolves it.
    ///
    /// nonisolated and pure-ish: it only touches the filesystem, so it can run
    /// on the utility queue.
    nonisolated private static func readBranch(_ cwd: String) -> String {
        let fm = FileManager.default
        var directory = URL(fileURLWithPath: cwd)
        // Bounded: a runaway symlink loop must not walk forever.
        for _ in 0..<24 {
            let dotGit = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir: URL
                if isDirectory.boolValue {
                    gitDir = dotGit
                } else {
                    // A worktree: `.git` is a file saying "gitdir: <path>".
                    guard
                        let text = try? String(contentsOf: dotGit, encoding: .utf8),
                        let path = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
                    else { return "" }
                    gitDir = URL(fileURLWithPath: String(path.dropFirst("gitdir:".count))
                        .trimmingCharacters(in: .whitespaces))
                }
                guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"),
                                             encoding: .utf8) else { return "" }
                return GitLabel.branch(fromHEAD: head)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return ""
    }
}
