import ClaudePetCore
import Foundation

/// `pet-emit --detail <session>`: the card the pet shows while the pointer rests on a row (the
/// Mac app's hoverDetail), printed as the JSON WebBridge.showDetail hands `window.showDetail`.
/// Prints nothing when there is nothing to show. The Mac app does not use it.
enum PetDetail {
    static func run(session: String) -> Int32 {
        guard !session.isEmpty, session.count <= 128,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return 1 }
        // The session as its row shows it (StateAggregator: a prompt approved in the terminal,
        // a wait outlived), not the raw file.
        let now = Date()
        guard let s = StateAggregator.aggregate(PetWatch.scan(HookEmit.sessionsDirectory), now: now)
            .sessions.first(where: { $0.sessionId == session })
        else { return 1 }
        let d = detail(of: s, now: now)
        guard !d.isEmpty, let json = try? JSONSerialization.data(withJSONObject: document(d), options: [.sortedKeys])
        else { return 0 }
        do { try FileHandle.standardOutput.write(contentsOf: json + Data("\n".utf8)) } catch { return 1 }
        return 0
    }

    /// The same inputs the Mac app gathers: the statusline's insight, the transcript (read
    /// whole each time; the Mac caches it, a hover here is rare enough not to), the context
    /// budget, the last tool call, and commands left running after an idle turn.
    static func detail(of s: SessionState, now: Date) -> SessionDetail.Detail {
        let home = HookEmit.baseDirectory
        let insight = (try? Data(contentsOf: SessionInsights.directory(petHome: home)
            .appending(path: SessionInsights.fileName(sessionId: s.sessionId))))
            .flatMap(SessionInsights.decode)
        let path = s.transcript.isEmpty
            ? TranscriptStats.defaultTranscript(cwd: s.cwd, sessionId: s.sessionId, home: NSHomeDirectory())
            : s.transcript
        // Opened as PetRows opens it, so Claude Code can go on appending meanwhile.
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        let transcript = size.flatMap { PetRows.read(path, from: 0, count: $0) }
            .map { TranscriptStats.advance(TranscriptStats.Progress(), through: $0) }

        var context: ContextBudget.Reading?
        if let transcript, transcript.contextTokens > 0 {
            let settingsFile = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
            let settings = (try? Data(contentsOf: settingsFile)).map(ContextBudget.parse) ?? ContextBudget.Settings()
            context = ContextBudget.Reading(tokens: transcript.contextTokens,
                                            budget: ContextBudget.budget(model: transcript.model, settings: settings))
        } else if let insight, insight.isFresh(now: now), let percent = insight.contextPercent {
            context = ContextBudget.Reading(percentOnly: percent)
        }

        let log = HookEmit.activityDirectory.appending(path: s.sessionId + ".jsonl")
        let recent = ActivityLog.recent(
            ActivityLog.decode((try? String(contentsOf: log, encoding: .utf8)) ?? ""), now: now, limit: 1).first
        let background = s.state == .idle ? s.pid.map(BackgroundShells.running(under:)) ?? [] : []
        return SessionDetail.detail(session: s, insight: insight, transcript: transcript, context: context,
                                    lastActivity: recent, background: background, now: now)
    }

    /// WebBridge.showDetail's document.
    static func document(_ d: SessionDetail.Detail) -> [String: Any] {
        var doc: [String: Any] = [
            "path": d.path, "worktree": d.worktree, "model": d.model,
            "turn": d.turn, "tool": d.tool, "quiet": d.quiet,
            "last": d.last, "lastBad": d.lastBad, "background": d.background,
        ]
        if let percent = d.contextPercent { doc["context"] = percent }
        if d.contextTokens > 0 {
            doc["contextTokens"] = d.contextTokens
            doc["contextBudget"] = d.contextBudget
        }
        if d.turns > 0 { doc["turns"] = d.turns }
        return doc
    }
}
