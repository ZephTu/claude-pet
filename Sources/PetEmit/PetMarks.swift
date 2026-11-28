import ClaudePetCore
import Foundation

/// Muted and snoozed sessions for a shell that is not the Mac app (the Windows spike). The Mac
/// app keeps the same marks in its defaults (hiddenSessions.v1, snoozedSessions); here they are
/// files beside the rest of the pet's data, so the watcher and the commands a click runs share
/// them:
///   muted.json    {"muted": {sessionId: seconds since 1970}}   HiddenSessions.mark
///   snoozed.json  Snooze.encode
/// The Mac app does not use it.
enum PetMarks {
    static var mutedFile: URL { HookEmit.baseDirectory.appending(path: "muted.json") }
    static var snoozedFile: URL { HookEmit.baseDirectory.appending(path: "snoozed.json") }
    private static var lockFile: URL { HookEmit.baseDirectory.appending(path: ".marks.lock") }

    /// A number, not CompletionQueue.format's whole seconds: the mark is compared with
    /// `lastPromptAt` (HiddenSessions.isHidden), and must not come out a fraction earlier.
    static func muted() -> [String: Date] {
        guard let data = try? Data(contentsOf: mutedFile),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = doc["muted"] as? [String: Any]
        else { return [:] }
        return entries.compactMapValues { ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
    }

    static func snoozed() -> [String: Snooze.Mark] {
        (try? Data(contentsOf: snoozedFile)).map(Snooze.decode) ?? [:]
    }

    private static func encode(muted marks: [String: Date]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["muted": marks.mapValues { $0.timeIntervalSince1970 }],
                                     options: [.sortedKeys])) ?? Data()
    }

    /// Changes one file under the lock, from what it holds now: the watcher prunes while a
    /// click adds. Replaced as read.json is (PetFinished.markRead): the watcher reads these
    /// files every second and a scanner may hold them, and Portable.replaceItem retries where a
    /// plain atomic write would fail once and lose the click.
    static func update(_ file: URL, _ change: () -> Data?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: HookEmit.baseDirectory, withIntermediateDirectories: true)
        Portable.withFileLock(lockFile.path, attempts: 200, interval: 0.005) {
            guard let data = change(), !data.isEmpty else { return }
            let tmp = HookEmit.baseDirectory.appending(
                path: "\(file.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max))")
            guard (try? data.write(to: tmp)) != nil else { return }
            do {
                if fm.fileExists(atPath: file.path) {
                    try Portable.replaceItem(at: file, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: file)
                }
            } catch {
                FileHandle.standardError.write(Data("pet-emit: could not write \(file.lastPathComponent): \(error)\n".utf8))
                try? fm.removeItem(at: tmp)
            }
        }
    }

    /// The watcher's tidy-up, as the Mac's pruneHidden and render do: marks of sessions that
    /// are gone, and snoozes that ran out or whose wait is over. Writes only when something
    /// went.
    static func prune(all: [SessionState], live: [SessionState], now: Date) {
        if FileManager.default.fileExists(atPath: mutedFile.path) {
            update(mutedFile) {
                let marks = muted()
                let kept = HiddenSessions.pruned(marks, keeping: all)
                return kept.count == marks.count ? nil : encode(muted: kept)
            }
        }
        if FileManager.default.fileExists(atPath: snoozedFile.path) {
            update(snoozedFile) {
                let marks = snoozed()
                let kept = Snooze.pruned(marks, keeping: live, now: now)
                return kept.count == marks.count ? nil : Snooze.encode(kept)
            }
        }
    }

    /// `pet-emit --mute <session>`: the row's ×. Back as soon as the user types into it.
    /// `pet-emit --unmute-all`: the tray's "Unmute All".
    /// `pet-emit --snooze <session> <minutes>`: the row's ⏱, one of Snooze.options.
    static func run(_ arguments: [String]) -> Int32 {
        func session(_ id: String) -> SessionState? {
            PetWatch.scan(HookEmit.sessionsDirectory).first { $0.sessionId == id }
        }
        switch (arguments.first, arguments.count) {
        case ("--mute", 2):
            guard let s = session(arguments[1]) else { return 1 }
            update(mutedFile) {
                var marks = muted()
                marks[s.sessionId] = HiddenSessions.mark(for: s)
                return encode(muted: marks)
            }
            return 0
        case ("--unmute-all", 1):
            update(mutedFile) { encode(muted: [:]) }
            return 0
        case ("--snooze", 3):
            guard let minutes = Int(arguments[2]), Snooze.options.contains(minutes) else { break }
            // Only a wait can be put off (the page offers ⏱ on waiting rows only).
            guard let s = session(arguments[1]), s.state == .waiting else { return 1 }
            update(snoozedFile) {
                var marks = snoozed()
                // Again replaces the delay, as on the Mac.
                marks[s.sessionId] = Snooze.mark(for: s, minutes: minutes, now: Date())
                return Snooze.encode(marks)
            }
            return 0
        default:
            break
        }
        FileHandle.standardError.write(Data(
            "usage: pet-emit --mute <session> | --unmute-all | --snooze <session> \(Snooze.options.map(String.init).joined(separator: "|"))\n".utf8))
        return 2
    }
}
