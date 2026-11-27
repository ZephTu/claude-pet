import ClaudePetCore
import Foundation

/// `pet-emit --watch`: the pet's state, worked out by the same core code the Mac app uses, printed
/// as one JSON line whenever it changes. A shell that is not the Mac app (the Windows spike)
/// starts this once and draws what it says; the Mac app does not use it.
///
/// One line:
///   {"mood", "phase", "pose", "mark", "waitingProject", "waitingOn", "waitingSessionId",
///    "waitingAskId", "badge", "sessions": [rows shaped like WebBridge's setSessions items]}
enum PetWatch {
    static func run(interval: TimeInterval = 1) -> Never {
        var previous: GlobalState?
        var lastLine = ""
        while true {
            let now = Date()
            let all = scan(HookEmit.sessionsDirectory)
            let state = StateAggregator.settled(StateAggregator.aggregate(all, now: now),
                                                previous: previous, now: now)
            previous = state
            let line = render(state, now: now)
            if line != lastLine {
                lastLine = line
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
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

    static func render(_ state: GlobalState, now: Date) -> String {
        let sessions = state.sessions
        let phase = StateAggregator.phase(sessions)
        let waitingSession = sessions.first { $0.sessionId == state.waitingSessionId }
        // Awake with something answered and unread, asleep with nothing at all.
        let wanted = sessions.contains { $0.state == .idle && !$0.detail.isEmpty }
        let look = CatSkin.look(mood: state.mood.rawValue, phase: phase, flash: "", wanted: wanted,
                                blockedOn: waitingSession?.waitingOn ?? "",
                                struggling: sessions.contains(where: Struggle.isStruggling))
        let needsYou = sessions.filter { $0.state == .waiting }.count
        let doc: [String: Any] = [
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
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A subset of WebBridge.setSessions' row: what the panel needs to draw a row and offer
    /// Allow / Deny. No terminal handles (nothing on Windows can jump yet), no HQ task, no context.
    static func row(_ s: SessionState, now: Date) -> [String: Any] {
        var item: [String: Any] = [
            "sessionId": s.sessionId,
            "project": s.project,
            "state": s.state.rawValue,
            "tool": s.tool,
            "detail": SessionCopy.note(state: s.state, detail: s.detail, waitingOn: s.waitingOn),
            "waitedSeconds": Int(max(0, now.timeIntervalSince(s.since))),
        ]
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
