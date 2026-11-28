import ClaudePetCore
import Foundation

/// `pet-emit --watch`: the pet's state, worked out by the same core code the Mac app uses, printed
/// as one JSON line whenever it changes. A shell that is not the Mac app (the Windows spike)
/// starts this once and draws what it says; the Mac app does not use it.
///
/// One line:
///   {"mood", "phase", "pose", "mark", "waitingProject", "waitingOn", "waitingSessionId",
///    "waitingAskId", "badge", "sessions": [rows shaped like WebBridge's setSessions items],
///    "notices": [{"sessionId", "text", "emphasis", "holdMs"}], only when sessions just finished}
enum PetWatch {
    static func run(interval: TimeInterval = 1) -> Never {
        var previous: GlobalState?
        var lastLine = ""
        var prunedAt = Date.distantPast
        while true {
            let now = Date()
            if now.timeIntervalSince(prunedAt) > 3600 {
                pruneEvents(now: now)
                prunedAt = now
            }
            let all = scan(HookEmit.sessionsDirectory)
            // As on the Mac: the settled state (a finish held back settleAfter) decides only
            // "it finished"; the rows and the figure show the state as it is.
            let state = StateAggregator.aggregate(all, now: now)
            let settled = StateAggregator.settled(state, previous: previous, now: now)
            let finished = doneNotices(previous: previous, current: settled, now: now)
            previous = settled
            let line = render(state, now: now, notices: finished)
            if line != lastLine {
                lastLine = line
                // The reader went away (the shell quit or restarted us): stop quietly. The
                // non-throwing write traps on a closed pipe on Windows.
                do { try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
                catch { exit(0) }
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    static func scan(_ directory: URL) -> [SessionState] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap(SessionState.decode(from:))
        }
    }

    /// The Mac app's announceFinishes: one notice per session that just came to rest, saying
    /// the first line of Claude's last reply when the hook recorded one (events/, the last
    /// minute's).
    static func doneNotices(previous: GlobalState?, current: GlobalState, now: Date) -> [Chatter.DoneNotice] {
        let bare = Chatter.doneNotices(previous: previous, current: current)
        guard !bare.isEmpty else { return [] }
        // Only the finished sessions' files (CompletionQueue.fileName: "<session>~<turn>.json").
        let prefixes = bare.map { $0.sessionId + "~" }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: HookEmit.eventsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in url.pathExtension == "json" && prefixes.contains { url.lastPathComponent.hasPrefix($0) } }
        var summaries: [String: (Date, String)] = [:]
        for event in CompletionQueue.decode(files.compactMap { try? Data(contentsOf: $0) })
        where !event.summary.isEmpty && now.timeIntervalSince(event.finishedAt) < 60 {
            if let seen = summaries[event.sessionId], seen.0 >= event.finishedAt { continue }
            summaries[event.sessionId] = (event.finishedAt, event.summary)
        }
        return Chatter.doneNotices(previous: previous, current: current, summaries: summaries.mapValues(\.1))
    }

    /// Ages `events/` out as the Mac's CompletionStore does (CompletionQueue.prune), deleting
    /// the files of what it drops: the hook adds one per turn, and nothing else on Windows
    /// removes them.
    static func pruneEvents(now: Date) {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: HookEmit.eventsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let read = ReadMarks.decode((try? Data(contentsOf: HookEmit.baseDirectory.appending(path: "read.json"))) ?? Data())
        let events = CompletionQueue.dedupe(CompletionQueue.decode(urls.compactMap { try? Data(contentsOf: $0) }))
        let keeping = Set(CompletionQueue.prune(events, read: read, now: now).keep.map(CompletionQueue.fileName(for:)))
        // A file that doesn't decode is left alone: it may be one being written right now.
        let named = Set(events.map(CompletionQueue.fileName(for:)))
        for url in urls where named.contains(url.lastPathComponent) && !keeping.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    static func render(_ state: GlobalState, now: Date, notices: [Chatter.DoneNotice] = []) -> String {
        let sessions = state.sessions
        let phase = StateAggregator.phase(sessions)
        let waitingSession = sessions.first { $0.sessionId == state.waitingSessionId }
        // Awake with something answered and unread, asleep with nothing at all.
        let wanted = sessions.contains { $0.state == .idle && !$0.detail.isEmpty }
        let look = CatSkin.look(mood: state.mood.rawValue, phase: phase, flash: "", wanted: wanted,
                                blockedOn: waitingSession?.waitingOn ?? "",
                                struggling: sessions.contains(where: Struggle.isStruggling))
        let needsYou = sessions.filter { $0.state == .waiting }.count
        var doc: [String: Any] = [
            "mood": state.mood.rawValue,
            "phase": phase,
            "pose": look.pose.rawValue,
            "mark": look.mark.rawValue,
            "waitingProject": state.waitingProject ?? NSNull(),
            "waitingOn": state.waitingOn,
            "waitingSessionId": state.waitingSessionId,
            "waitingAskId": state.waitingAskId,
            "badge": PanelModel.badge(needsYou: needsYou, unreadFinishes: 0),
            "sessions": sessions.map { row($0, now: now) },
        ]
        // Only on the line where they happen: the shell shows each one once (window.notify).
        if !notices.isEmpty {
            doc["notices"] = notices.map {
                ["sessionId": $0.sessionId, "text": $0.text, "emphasis": $0.emphasis,
                 "holdMs": Int(Chatter.noticeHold * 1000)] as [String: Any]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Terminals `pet-emit --jump` can bring up (WindowsJump): only these rows are clickable.
    static let jumpKinds: Set<String> = ["orca", "wt", "console"]

    /// A subset of WebBridge.setSessions' row: what the panel needs to draw a row, offer
    /// Allow / Deny, and jump to the terminal. No HQ task, no context, no tab title.
    static func row(_ s: SessionState, now: Date) -> [String: Any] {
        var item: [String: Any] = [
            "sessionId": s.sessionId,
            "project": s.project,
            "state": s.state.rawValue,
            "tool": s.tool,
            "detail": SessionCopy.note(state: s.state, detail: s.detail, waitingOn: s.waitingOn),
            "waitedSeconds": Int(max(0, now.timeIntervalSince(s.since))),
        ]
        // wt and console are reached through the session's pid: without one (Claude Code run
        // by node.exe, say) the row would offer a jump that can only fail.
        if let t = s.terminal, jumpKinds.contains(t.kind), t.kind == "orca" || s.pid != nil {
            item["termKind"] = t.kind
            item["termHandle"] = t.handle
        }
        if StateAggregator.isQuiet(s, now: now) { item["quiet"] = true }
        if s.state == .waiting, !s.waitingOn.isEmpty { item["asks"] = "permission" }
        if s.askAnswerable(now: now) { item.merge(BoardPrompt.dotFields(of: s)) { _, new in new } }
        if s.state == .busy, s.phase == "awaiting-agent" { item["agent"] = true }
        if Struggle.isStruggling(s) {
            item["struggle"] = "\(s.failStreak) failed in a row" + (s.failTarget.isEmpty ? "" : " · " + s.failTarget)
        }
        if s.state == .idle, !s.detail.isEmpty { item["replied"] = true }
        if s.state == .waiting, SessionCopy.isUrgent(waitedFor: now.timeIntervalSince(s.since)) { item["urgent"] = true }
        if !s.backgroundAgents.isEmpty {
            item["activity"] = BackgroundWork.phrase(s.backgroundAgents)
        } else if s.running.count > 1 {
            item["activity"] = ActivitySummary.concurrent(s.running.count)
        } else if let only = s.running.first {
            item["activity"] = ActivitySummary.phrase(toolName: only.tool, target: only.target)
            if let began = only.since { item["toolSeconds"] = Int(max(0, now.timeIntervalSince(began))) }
        }
        return item
    }

    /// `pet-emit --decide <session> <ask> allow|deny`: the answer a click on the pet gives, in
    /// the file the holding hook polls (PermissionDecision). The same file the Mac app writes.
    static func decide(session: String, ask: String, behavior: String) -> Int32 {
        guard let b = PermissionDecision.Behavior(rawValue: behavior), !session.isEmpty, !ask.isEmpty else { return 2 }
        let url = PermissionDecision.fileURL(petHome: HookEmit.baseDirectory, sessionId: session)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try PermissionDecision.encode(.init(askId: ask, behavior: b)).write(to: url, options: .atomic)
            return 0
        } catch {
            FileHandle.standardError.write(Data("pet-emit: \(error)\n".utf8))
            return 1
        }
    }
}
