import ClaudePetCore
import Foundation

/// `pet-emit --watch`: the pet's state, worked out by the same core code the Mac app uses, printed
/// as one JSON line whenever it changes. A shell that is not the Mac app (the Windows spike)
/// starts this once and draws what it says; the Mac app does not use it.
///
/// One line:
///   {"mood", "phase", "pose", "mark", "waitingProject", "waitingOn", "waitingSessionId",
///    "waitingAskId", "badge", "sessions": [rows shaped like WebBridge's setSessions items],
///    "finished": [WebBridge's Finished rows], "dropped": unread finishes aged out (once),
///    "hidden": muted live sessions, "quota": [{"label", "percent", "resetsIn"}], "quotaFallback",
///    "notices": [{"sessionId", "text", "emphasis", "holdMs"}], only when sessions just finished}
enum PetWatch {
    static func run(interval: TimeInterval = 1) -> Never {
        var previous: GlobalState?
        var lastLine = ""
        var prunedAt = Date.distantPast
        var cache = PetFinished.Cache()
        var lastRead: Set<String> = []
        var quota = PetQuota()
        var rows = PetRows()
        while true {
            let now = Date()
            var dropped = 0
            if now.timeIntervalSince(prunedAt) > 3600, let marks = PetFinished.read() {
                dropped = pruneEvents(now: now, read: marks)
                prunedAt = now
            }
            let all = scan(HookEmit.sessionsDirectory)
            // Muted sessions leave the list and the mood; snoozed ones stay listed but stop the
            // waving and the badge (PetMarks; the Mac keeps these in its defaults).
            let muted = PetMarks.muted()
            let snoozed = PetMarks.snoozed()
            // As on the Mac: the settled state (a finish held back settleAfter) decides only
            // "it finished"; the rows and the figure show the state as it is.
            let state = StateAggregator.aggregate(all, now: now, hidden: muted, snoozed: snoozed)
            PetMarks.prune(all: all, live: state.sessions, now: now)
            let settled = StateAggregator.settled(state, previous: previous, now: now)
            let finished = doneNotices(previous: previous, current: settled, now: now)
            previous = settled

            // The Finished group (the Mac's render): unread turns, minus the ones the user has
            // plainly seen - they typed into that session since.
            cache.reload(now: now)
            // Unreadable for a moment: last tick's marks, not none.
            var read = PetFinished.read() ?? lastRead
            let replied = CompletionQueue.answered(CompletionQueue.unread(cache.events, read: read),
                                                   sessions: state.sessions)
            if !replied.isEmpty {
                PetFinished.markRead(replied)
                read.formUnion(replied)
            }
            lastRead = read
            let unread = CompletionQueue.shown(CompletionQueue.unread(cache.events, read: read),
                                               sessions: settled.sessions)

            let line = render(state, now: now, notices: finished, unread: unread, dropped: dropped,
                              snoozed: snoozed, usage: quota.sample(now: now),
                              extras: rows.extras(for: state.sessions, all: all, now: now))
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
    /// removes them. Returns how many unread ones went (the list says so once).
    static func pruneEvents(now: Date, read: Set<String>) -> Int {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: HookEmit.eventsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let events = CompletionQueue.dedupe(CompletionQueue.decode(urls.compactMap { try? Data(contentsOf: $0) }))
        let keeping = Set(CompletionQueue.prune(events, read: read, now: now).keep.map(\.eventId))
        // Only files named for their event go (one that doesn't decode may be being written
        // right now), and only what really went is counted, so nothing is reported twice.
        var droppedUnread = 0
        for e in events where !keeping.contains(e.eventId) {
            let url = HookEmit.eventsDirectory.appending(path: CompletionQueue.fileName(for: e))
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            if !read.contains(e.eventId) { droppedUnread += 1 }
        }
        return droppedUnread
    }

    static func render(_ state: GlobalState, now: Date, notices: [Chatter.DoneNotice] = [],
                       unread: [CompletionEvent] = [], dropped: Int = 0,
                       snoozed: [String: Snooze.Mark] = [:], usage: UsageSnapshot? = nil,
                       extras: [String: PetRows.Extra] = [:]) -> String {
        let sessions = state.sessions
        let phase = StateAggregator.phase(sessions)
        let finishedRows = PanelModel.completionRows(unread, live: sessions)
        // As the Mac's render: one number for "how many things want me", and the cat looks up
        // while it is not zero. A postponed wait is not counted: the user said "not now".
        let badge = PanelModel.badge(
            needsYou: PanelModel.needsYou(sessions).filter { !Snooze.isSnoozed($0, marks: snoozed, now: now) }.count,
            unreadFinishes: finishedRows.count)
        let look = CatSkin.look(mood: state.mood.rawValue, phase: phase, flash: "", wanted: !badge.isEmpty,
                                blockedOn: state.waitingOn,
                                struggling: sessions.contains(where: Struggle.isStruggling))
        var doc: [String: Any] = [
            "mood": state.mood.rawValue,
            "phase": phase,
            "pose": look.pose.rawValue,
            "mark": look.mark.rawValue,
            "waitingProject": state.waitingProject ?? NSNull(),
            "waitingOn": state.waitingOn,
            "waitingSessionId": state.waitingSessionId,
            "waitingAskId": state.waitingAskId,
            "badge": badge,
            "sessions": sessions.map { row($0, now: now, snoozed: snoozed, extra: extras[$0.sessionId]) },
            "finished": finishedRows.map { finishedRow($0, live: sessions, now: now) },
            "hidden": state.hiddenCount,
            // What resting on the cat shows (the Mac's showQuota): meters, or this line when
            // there is no usable reading.
            "quota": Chatter.quotaRows(usage: usage, now: now).map {
                ["label": $0.label, "percent": $0.percent, "resetsIn": $0.resetsIn] as [String: Any]
            },
            "quotaFallback": Chatter.fallbackLine(state: state),
        ]
        if dropped > 0 { doc["dropped"] = dropped }
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

    /// WebBridge's Finished row. Jumpable on the same terms as a session row (`row`).
    static func finishedRow(_ r: CompletionRow, live: [SessionState], now: Date) -> [String: Any] {
        var item: [String: Any] = [
            "sessionId": r.sessionId,
            "eventIds": r.eventIds,
            "label": r.label,
            "count": r.count,
            "closed": r.sessionClosed,
            "agoSeconds": Int(max(0, now.timeIntervalSince(r.latestAt))),
            "summary": r.summary,
        ]
        if let t = r.terminal, jumpKinds.contains(t.kind),
           t.kind == "orca" || live.first(where: { $0.sessionId == r.sessionId })?.pid != nil {
            item["termKind"] = t.kind
            item["termHandle"] = t.handle
        }
        return item
    }

    /// WebBridge.setSessions' row: what the panel needs to draw a row, offer Allow / Deny and
    /// jump to the terminal, plus what PetRows gathered (turns, context, the HQ task, commands
    /// left running, and Claude Code's name for the session where the Mac has the tab title).
    /// No aliases or pins (the Mac keeps those in its defaults).
    static func row(_ s: SessionState, now: Date, snoozed: [String: Snooze.Mark] = [:],
                    extra: PetRows.Extra? = nil) -> [String: Any] {
        var item: [String: Any] = [
            "sessionId": s.sessionId,
            "project": SessionLabels.displayName(for: s, prefs: [:], title: extra?.name ?? ""),
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
        if let extra {
            if let turns = extra.turns { item["turns"] = turns }
            if let task = extra.task {
                item["task"] = task
                item["taskStatus"] = extra.taskStatus ?? ""
            }
            if let reading = extra.context {
                item["context"] = reading.percent
                if reading.hasTokens {
                    item["contextTokens"] = reading.tokens
                    item["contextBudget"] = reading.budget
                }
            }
            if extra.background > 0 { item["background"] = extra.background }
        }
        if s.state == .busy, s.phase == "awaiting-agent" { item["agent"] = true }
        if Struggle.isStruggling(s) {
            item["struggle"] = "\(s.failStreak) failed in a row" + (s.failTarget.isEmpty ? "" : " · " + s.failTarget)
        }
        if s.state == .idle, !s.detail.isEmpty { item["replied"] = true }
        if s.state == .waiting, SessionCopy.isUrgent(waitedFor: now.timeIntervalSince(s.since)) { item["urgent"] = true }
        let left = Snooze.remaining(s, marks: snoozed, now: now)
        if !left.isEmpty { item["snoozedFor"] = left }
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
