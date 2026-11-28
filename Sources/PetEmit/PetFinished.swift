import ClaudePetCore
import Foundation

/// The list's Finished group for a shell that is not the Mac app (the Windows spike): what the
/// Mac's CompletionStore does, over the same files — `events/` (one file per finished turn, written
/// by the hook) and `read.json` (the turns the user has seen). The Mac app does not use it.
enum PetFinished {
    static var readFile: URL { HookEmit.baseDirectory.appending(path: "read.json") }
    private static var lockFile: URL { HookEmit.baseDirectory.appending(path: ".read.lock") }

    static func events() -> [CompletionEvent] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: HookEmit.eventsDirectory, includingPropertiesForKeys: nil)) ?? []
        return CompletionQueue.dedupe(CompletionQueue.decode(
            urls.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }))
    }

    /// The marks; empty when there is no file yet, nil when there is one that can't be read
    /// right now (a scan, a replace in progress). Nil must not be taken for "nothing read":
    /// that would bring back every finish of the week.
    static func read() -> Set<String>? {
        guard FileManager.default.fileExists(atPath: readFile.path) else { return [] }
        guard let data = try? Data(contentsOf: readFile),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              doc["read"] is [Any]
        else { return nil }
        return ReadMarks.decode(data)
    }

    /// Adds `ids` to the marks, and drops marks of events that are gone (ReadMarks.compact,
    /// against the events as they are now, inside the lock). The watcher (a reply typed after a
    /// finish) and `--mark-read` (a click) both write, so under a lock.
    static func markRead(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: HookEmit.baseDirectory, withIntermediateDirectories: true)
        Portable.withFileLock(lockFile.path, attempts: 200, interval: 0.005) {
            guard let marks = read() else { return }
            let data = ReadMarks.encode(ReadMarks.compact(marks.union(ids), keeping: events()))
            let tmp = HookEmit.baseDirectory.appending(
                path: "read.json.tmp.\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max))")
            guard (try? data.write(to: tmp)) != nil else { return }
            do {
                if fm.fileExists(atPath: readFile.path) {
                    try Portable.replaceItem(at: readFile, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: readFile)
                }
            } catch {
                try? fm.removeItem(at: tmp)
            }
        }
    }

    /// `pet-emit --mark-read --all | --session <id> | -`: the list's "Clear", a notice that was
    /// opened, and (`-`, one event id per line on stdin, as a row can stand for hundreds of
    /// turns, past the command line's length) a row's ✓ or a finished row that was opened.
    static func runMarkRead(_ arguments: [String]) -> Int32 {
        let all = events()
        guard let marks = read() else {
            FileHandle.standardError.write(Data("pet-emit: read.json can't be read right now\n".utf8))
            return 1
        }
        let unread = CompletionQueue.unread(all, read: marks)
        let ids: [String]
        switch arguments.first {
        case "--all" where arguments.count == 1:
            ids = unread.map(\.eventId)
        case "--session" where arguments.count == 2:
            ids = unread.filter { $0.sessionId == arguments[1] }.map(\.eventId)
        case "-" where arguments.count == 1:
            // Only ids of events that exist: anything else would be compacted away anyway.
            let known = Set(all.map(\.eventId))
            let given = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            // Windows PowerShell 5.1 pipes a UTF-8 byte order mark ahead of the text.
            ids = given.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(["\u{FEFF}"])) }
                .filter(known.contains)
        default:
            FileHandle.standardError.write(Data("usage: pet-emit --mark-read --all | --session <id> | -\n".utf8))
            return 2
        }
        markRead(ids)
        return 0
    }

    /// The events, re-read only when `events/` changed (a file added, replaced or removed
    /// renames an entry, which moves the folder's time) or every half minute regardless.
    struct Cache {
        private var stamp: Date?
        private var readAt = Date.distantPast
        private(set) var events: [CompletionEvent] = []

        mutating func reload(now: Date) {
            let changed = (try? FileManager.default.attributesOfItem(
                atPath: HookEmit.eventsDirectory.path))?[.modificationDate] as? Date
            guard changed != stamp || now.timeIntervalSince(readAt) > 30 else { return }
            stamp = changed
            readAt = now
            events = PetFinished.events()
        }
    }
}
