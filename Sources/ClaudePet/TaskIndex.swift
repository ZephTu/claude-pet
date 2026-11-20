import Foundation

/// What the pet needs from HQ (the task board), read straight from its files: which task each
/// session is bound to, the questions waiting for an answer, and today's focus list.
///
/// Reads are cheap — a few dozen small files — but the pet renders often, so a snapshot is
/// kept for a few seconds. With HQ not installed everything is empty and nothing changes.
@MainActor
final class TaskIndex {
    struct Ask: Equatable {
        let id: String
        let task: String
        let text: String
        let session: String
    }

    struct Snapshot {
        /// sessionId → "T-062 Claude-pet Dashboard"
        var taskBySession: [String: String] = [:]
        /// sessionId → that task's status (active, blocked, waiting-on-me, done, abandoned)
        var statusBySession: [String: String] = [:]
        /// taskId → status
        var statusByTask: [String: String] = [:]
        var openAsks: [Ask] = []
        var focusToday: [String] = []
        /// Open tasks from the last day that had picks, not yet on today's list.
        var carry: [String] = []
        var installed = false
    }

    private var cached = Snapshot()
    private var readAt = Date.distantPast
    private let ttl: TimeInterval = 8

    func snapshot(now: Date = Date()) -> Snapshot {
        if now.timeIntervalSince(readAt) < ttl { return cached }
        readAt = now
        cached = Self.read(now: now)
        return cached
    }

    // MARK: - Reading

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func read(now: Date) -> Snapshot {
        var snap = Snapshot()
        let hq = home.appending(path: ".claude/hq")
        guard let config = json(hq.appending(path: "config.json")) as? [String: Any],
              let rootPath = config["root"] as? String else { return snap }
        snap.installed = true
        let tasksDir = URL(fileURLWithPath: rootPath).appending(path: "tasks")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path)) ?? []

        var titles: [String: String] = [:]
        var statuses: [String: String] = [:]
        for dir in dirs where dir.hasPrefix("T-") {
            let folder = tasksDir.appending(path: dir)
            let id = String(dir.split(separator: "-").prefix(2).joined(separator: "-"))
            if let head = try? String(contentsOf: folder.appending(path: "TASK.md"), encoding: .utf8) {
                for line in head.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
                    if line.hasPrefix("title:") { titles[id] = clean(line.dropFirst(6)) }
                    if line.hasPrefix("status:") { statuses[id] = clean(line.dropFirst(7)) }
                }
            }
            snap.openAsks += asks(in: folder, task: id)
        }

        snap.statusByTask = statuses
        if let state = json(hq.appending(path: "state/sessions.json")) as? [String: [String: Any]] {
            for (sid, entry) in state {
                guard let task = entry["task"] as? String else { continue }
                snap.taskBySession[sid] = titles[task].map { "\(task) \($0)" } ?? task
                if let st = statuses[task] { snap.statusBySession[sid] = st }
            }
        }

        // The Focus list (hq keeps it until you take a task off). An older per-day file reads as
        // its latest day's list, as hq reads it.
        if let focus = json(URL(fileURLWithPath: rootPath).appending(path: "focus.json")) as? [String: Any] {
            if let list = focus["focus"] as? [String] {
                snap.focusToday = list
            } else if let days = focus["days"] as? [String: [String]], let last = days.keys.max() {
                snap.focusToday = days[last] ?? []
            }
        }

        return snap
    }

    /// A frontmatter value without its quotes or a trailing template comment.
    private static func clean(_ raw: Substring) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") {
            v.removeFirst()
            if let end = v.lastIndex(of: "\"") { v = String(v[..<end]) }
        } else if let hash = v.range(of: "  #") {
            v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    /// `2026-11-21T00:00:00` as written by `hq ask snooze` — local time, no zone.
    private static func localTime(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// The asks ledger is an event log; fold it into the ones still open.
    private static func asks(in folder: URL, task: String) -> [Ask] {
        guard let text = try? String(contentsOf: folder.appending(path: "asks.jsonl"), encoding: .utf8) else { return [] }
        var open: [String: Ask] = [:]
        var seen: [String: Ask] = [:]
        var order: [String] = []
        var resolved: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = e["id"] as? String else { continue }
            switch e["type"] as? String {
            case "open":
                let ask = Ask(id: id, task: task, text: e["text"] as? String ?? "", session: e["session"] as? String ?? "")
                open[id] = ask
                seen[id] = ask
                order.append(id)
            case "resolve":
                open[id] = nil
                resolved.insert(id)
            case "reopen":
                open[id] = seen[id]
                resolved.remove(id)
            case "snooze":
                // "Later" on the board: still open, but out of the badge until it comes back.
                let until = (e["until"] as? String).flatMap(Self.localTime)
                if let until, until > Date() { open[id] = nil } else if open[id] == nil, let a = seen[id], !resolved.contains(id) { open[id] = a }
            default:
                break
            }
        }
        return order.compactMap { open[$0] }.reduce(into: [Ask]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
