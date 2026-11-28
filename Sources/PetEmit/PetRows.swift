import ClaudePetCore
import Foundation
#if os(Windows)
import WinSDK
#endif

/// What the Mac app gathers for each row besides the session file (AppMain.render, handed to
/// WebBridge.pushSessions), kept across `--watch` ticks:
/// - turns and context from the transcript (the Mac's TranscriptCache and readContext): only
///   what was appended since the last read, at most `perTick` bytes a tick in all, so a first
///   read of long transcripts can't hold up the line (the Mac reads off the main thread); a
///   transcript shows its numbers once it has been read to the end;
/// - the HQ task a session is bound to and its status, and the questions open on the board (the
///   Mac's TaskIndex), every 8 s;
/// - commands an idle session left running (the Mac's findBackgroundShells);
/// - Claude Code's own name for the session (`~/.claude/sessions/<pid>.json`), in place of the
///   Mac's terminal tab title, which Windows terminals don't give out.
/// The Mac app does not use it.
struct PetRows {
    struct Extra {
        var turns: Int?
        var context: ContextBudget.Reading?
        var task: String?
        var taskStatus: String?
        var background = 0
        var name = ""
    }

    private var progress: [String: TranscriptStats.Progress] = [:]
    /// Transcripts read to their end at least once.
    private var loaded: Set<String> = []
    /// The size each was last read to the end at.
    private var lastSize: [String: Int] = [:]
    static let perTick = 64 << 20
    private var settings = ContextBudget.Settings()
    private var settingsStamp: Date?
    /// HQ's bindings and open asks as last read (every 8 s).
    private(set) var tasks = Tasks()
    private var tasksAt = Date.distantPast
    private var names: [Int32: String] = [:]

    /// sessionId → what its row adds. Reads what changed since the last call. `all` (muted ones
    /// included) keeps the transcripts' progress for sessions not shown right now.
    mutating func extras(for sessions: [SessionState], all: [SessionState], now: Date) -> [String: Extra] {
        reloadSettings()
        if now.timeIntervalSince(tasksAt) >= 8 {
            tasksAt = now
            tasks = Tasks.read(now: now)
            names = Self.names(of: sessions)
        }
        var out: [String: Extra] = [:]
        var budget = Self.perTick
        for s in sessions {
            var e = Extra()
            let path = Self.transcriptPath(s)
            let read = advance(path, budget: &budget)
            // Still catching up: no numbers yet, rather than ones that climb for a few seconds.
            if loaded.contains(path) {
                if read.turns > 0 { e.turns = read.turns }
                if read.contextTokens > 0 {
                    e.context = ContextBudget.Reading(tokens: read.contextTokens,
                                                      budget: ContextBudget.budget(model: read.model, settings: settings))
                } else if let percent = Self.statuslinePercent(s.sessionId, now: now) {
                    e.context = ContextBudget.Reading(percentOnly: percent)
                }
            }
            if let task = tasks.taskBySession[s.sessionId] {
                e.task = task
                e.taskStatus = tasks.statusBySession[s.sessionId] ?? ""
            }
            // Only idle sessions: while a turn runs, its own foreground Bash call is a shell of
            // the same shape.
            if s.state == .idle, let pid = s.pid { e.background = BackgroundShells.running(under: pid).count }
            if let pid = s.pid { e.name = names[pid] ?? "" }
            out[s.sessionId] = e
        }
        let keep = Set(all.map(Self.transcriptPath))
        progress = progress.filter { keep.contains($0.key) }
        loaded = loaded.filter { keep.contains($0) }
        lastSize = lastSize.filter { keep.contains($0.key) }
        return out
    }

    static func transcriptPath(_ s: SessionState) -> String {
        s.transcript.isEmpty
            ? TranscriptStats.defaultTranscript(cwd: s.cwd, sessionId: s.sessionId, home: NSHomeDirectory())
            : s.transcript
    }

    /// The transcript's reading, advanced over what was appended since the last one (as much of
    /// it as `budget` allows; the rest next tick).
    private mutating func advance(_ path: String, budget: inout Int) -> TranscriptStats.Progress {
        var before = progress[path] ?? TranscriptStats.Progress()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        else { return before }
        // Shorter than what was read: not the file that was read.
        if size < before.offset {
            before = TranscriptStats.Progress()
            loaded.remove(path)
            lastSize[path] = nil
        }
        // Read to the end at this size already (an unfinished last line stays past `offset`).
        if lastSize[path] == size { return before }
        let want = size - before.offset
        let chunk = min(want, max(0, budget))
        guard chunk > 0, let tail = Self.read(path, from: before.offset, count: chunk) else {
            if want == 0 { loaded.insert(path); lastSize[path] = size }
            return before
        }
        budget -= tail.count
        // TranscriptStats.advance reads `data` from `offset`: hand it the new bytes alone.
        var rebased = before
        rebased.offset = 0
        var after = TranscriptStats.advance(rebased, through: tail)
        after.offset += before.offset
        progress[path] = after
        if before.offset + tail.count >= size {
            loaded.insert(path)
            lastSize[path] = size
        }
        return after
    }

    /// `count` bytes of the file from `offset`, opened so that Claude Code can go on appending
    /// to it meanwhile (a plain open on Windows lets others only read).
    static func read(_ path: String, from offset: Int, count: Int) -> Data? {
        #if os(Windows)
        let file = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0x8000_0000) /* GENERIC_READ */,
                        DWORD(0x7) /* FILE_SHARE_READ | WRITE | DELETE */, nil,
                        DWORD(3) /* OPEN_EXISTING */, DWORD(0x80) /* FILE_ATTRIBUTE_NORMAL */, nil)
        }
        guard let file, file != HANDLE(bitPattern: -1) else { return nil }
        defer { CloseHandle(file) }
        var at = LARGE_INTEGER()
        at.QuadPart = LONGLONG(offset)
        guard SetFilePointerEx(file, at, nil, DWORD(0) /* FILE_BEGIN */) else { return nil }
        var data = Data(count: count)
        var got: DWORD = 0
        let ok = data.withUnsafeMutableBytes { ReadFile(file, $0.baseAddress, DWORD(count), &got, nil) }
        guard ok else { return nil }
        return data.prefix(Int(got))
        #else
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return (try? handle.read(upToCount: count)) ?? Data()
        #endif
    }

    /// `/autocompact` writes the user settings file: re-read it when it changes.
    private mutating func reloadSettings() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard stamp != settingsStamp else { return }
        settingsStamp = stamp
        settings = (try? Data(contentsOf: url)).map(ContextBudget.parse) ?? ContextBudget.Settings()
    }

    /// A fresh statusline percentage, for a session whose transcript has no reply yet.
    private static func statuslinePercent(_ sessionId: String, now: Date) -> Int? {
        let url = SessionInsights.directory(petHome: HookEmit.baseDirectory)
            .appending(path: SessionInsights.fileName(sessionId: sessionId))
        guard let insight = (try? Data(contentsOf: url)).flatMap(SessionInsights.decode),
              insight.isFresh(now: now) else { return nil }
        return insight.contextPercent
    }

    /// pid → the name Claude Code shows for that session (`/rename`, or the one it gave it).
    private static func names(of sessions: [SessionState]) -> [Int32: String] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/sessions")
        var out: [Int32: String] = [:]
        for s in sessions {
            guard let pid = s.pid,
                  let data = try? Data(contentsOf: dir.appending(path: "\(pid).json")),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  doc["sessionId"] as? String == s.sessionId,
                  let name = doc["name"] as? String, !name.isEmpty
            else { continue }
            out[pid] = name
        }
        return out
    }

    /// The part of the Mac's TaskIndex the pet needs, read straight from HQ's files: the task
    /// root from `~/.claude/hq/config.json`, each card's title and status from the top of its
    /// TASK.md, its open questions from `asks.jsonl`, and the bindings from `state/sessions.json`.
    /// Empty without HQ. `PET_HQ_HOME` stands in for the home folder, as for board.js.
    struct Tasks {
        struct Ask: Equatable {
            let id: String
            let task: String
            let text: String
            let session: String
        }

        /// sessionId → "T-062 Claude-pet Dashboard"
        var taskBySession: [String: String] = [:]
        /// sessionId → that task's status
        var statusBySession: [String: String] = [:]
        /// taskId → status
        var statusByTask: [String: String] = [:]
        /// Questions waiting for an answer, card by card, oldest first within a card.
        var openAsks: [Ask] = []

        static var home: URL {
            if let h = ProcessInfo.processInfo.environment["PET_HQ_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
            return URL(fileURLWithPath: NSHomeDirectory())
        }

        static func read(now: Date = Date()) -> Tasks {
            var out = Tasks()
            let hq = home.appending(path: ".claude/hq")
            guard let config = json(hq.appending(path: "config.json")) as? [String: Any],
                  let root = config["root"] as? String
            else { return out }
            let tasksDir = URL(fileURLWithPath: root).appending(path: "tasks")
            let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path)) ?? []).sorted()
            var titles: [String: String] = [:]
            for dir in dirs where dir.hasPrefix("T-") {
                let folder = tasksDir.appending(path: dir)
                let id = dir.split(separator: "-").prefix(2).joined(separator: "-")
                if let head = try? String(contentsOf: folder.appending(path: "TASK.md"), encoding: .utf8) {
                    for line in head.split(omittingEmptySubsequences: false, whereSeparator: lineBreak).prefix(30) {
                        if line.hasPrefix("title:") { titles[id] = clean(line.dropFirst(6)) }
                        if line.hasPrefix("status:") { out.statusByTask[id] = clean(line.dropFirst(7)) }
                    }
                }
                out.openAsks += asks(in: folder, task: id, now: now)
            }
            if let state = json(hq.appending(path: "state/sessions.json")) as? [String: [String: Any]] {
                for (sid, entry) in state {
                    guard let task = entry["task"] as? String else { continue }
                    let title = titles[task] ?? ""
                    out.taskBySession[sid] = title.isEmpty ? task : "\(task) \(title)"
                    if let status = out.statusByTask[task], !status.isEmpty { out.statusBySession[sid] = status }
                }
            }
            return out
        }

        /// The asks ledger is an event log: folded into the ones still open, as TaskIndex.asks.
        /// One put off with "Later" is out until its `until` passes.
        static func asks(in folder: URL, task: String, now: Date) -> [Ask] {
            guard let text = try? String(contentsOf: folder.appending(path: "asks.jsonl"), encoding: .utf8) else { return [] }
            var open: [String: Ask] = [:]
            var seen: [String: Ask] = [:]
            var order: [String] = []
            var resolved: Set<String> = []
            for line in text.split(whereSeparator: lineBreak) {
                guard let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
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
                    let until = (e["until"] as? String).flatMap(localTime)
                    if let until, until > now { open[id] = nil }
                    else if open[id] == nil, let a = seen[id], !resolved.contains(id) { open[id] = a }
                default:
                    break
                }
            }
            return order.compactMap { open[$0] }.reduce(into: [Ask]()) { if !$0.contains($1) { $0.append($1) } }
        }

        /// "\n", or "\r\n" (one Character, which a split on "\n" never matches). Not
        /// Character.isNewline: hq writes U+2028 and the like raw inside its JSON strings.
        static func lineBreak(_ c: Character) -> Bool { c == "\n" || c == "\r\n" }

        /// `2026-11-21T00:00:00` as written by `hq ask snooze`: local time, no zone.
        static func localTime(_ text: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: text) { return d }
            }
            return nil
        }

        private static func json(_ url: URL) -> Any? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }

        /// A frontmatter value without its quotes or a trailing template comment (TaskIndex.clean).
        static func clean(_ raw: Substring) -> String {
            var v = raw.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") {
                v.removeFirst()
                if let end = v.lastIndex(of: "\"") { v = String(v[..<end]) }
            } else if let hash = v.range(of: "  #") {
                v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return v
        }
    }
}
