import Foundation
import ClaudePetCore

/// Owns the on-disk record of finished turns and the user's acknowledgements.
///
/// Everything with a rule in it lives in `CompletionQueue` / `ReadMarks`; this
/// is the part that touches the filesystem, which is also the part that cannot
/// be unit-tested without a disk.
@MainActor
final class CompletionStore {
    private let eventsDirectory: URL
    private let readFile: URL

    private(set) var events: [CompletionEvent] = []
    private(set) var read: Set<String> = []

    /// Unread finishes that had to be thrown away to stay under the cap. Read
    /// once by the panel and cleared: the user is told, not nagged.
    private(set) var pendingDropNotice = 0

    /// Skips re-reading hundreds of files on a timer when nothing has changed.
    private var lastDirectoryStamp: Date?

    init(petHome: URL) {
        eventsDirectory = petHome.appending(path: "events")
        readFile = petHome.appending(path: "read.json")
    }

    var unread: [CompletionEvent] { CompletionQueue.unread(events, read: read) }

    /// Re-reads the queue if the directory changed, then ages it out.
    func reload(now: Date, force: Bool = false) {
        guard force || directoryChanged() else { return }

        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: eventsDirectory,
                                                includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        let blobs = urls.compactMap { try? Data(contentsOf: $0) }

        let decoded = CompletionQueue.dedupe(CompletionQueue.decode(blobs))
        read = ReadMarks.decode((try? Data(contentsOf: readFile)) ?? Data())

        let pruned = CompletionQueue.prune(decoded, read: read, now: now)
        events = pruned.keep
        if pruned.droppedUnread > 0 { pendingDropNotice += pruned.droppedUnread }

        // Delete the files behind whatever aged out, so the directory tracks the
        // queue rather than growing under it.
        if pruned.keep.count != decoded.count {
            let keeping = Set(pruned.keep.map(CompletionQueue.fileName(for:)))
            for url in urls where !keeping.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }

        let compacted = ReadMarks.compact(read, keeping: events)
        if compacted != read {
            read = compacted
            persistRead()
        }
    }

    func markRead(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        read.formUnion(ids)
        persistRead()
    }

    func markAllRead() {
        markRead(events.map(\.eventId))
    }

    func takeDropNotice() -> Int {
        defer { pendingDropNotice = 0 }
        return pendingDropNotice
    }

    private func persistRead() {
        let data = ReadMarks.encode(read)
        guard !data.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: readFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Unique temp name, same reasoning as pet-emit's writes.
        let tmp = URL(fileURLWithPath: readFile.path
            + ".tmp.\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max))")
        guard (try? data.write(to: tmp)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(readFile, withItemAt: tmp)) == nil {
            if (try? FileManager.default.moveItem(at: tmp, to: readFile)) == nil {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    /// A directory's modification date changes when a file is added or removed,
    /// which is exactly when this queue changes.
    private func directoryChanged() -> Bool {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: eventsDirectory.path))?[.modificationDate] as? Date
        guard stamp != lastDirectoryStamp else { return false }
        lastDirectoryStamp = stamp
        return true
    }
}
