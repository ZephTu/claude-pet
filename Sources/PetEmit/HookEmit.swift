import ClaudePetCore
import Foundation

/// Translates one Claude Code hook payload into the pet's session state file.
///
/// This runs inside every Claude Code session on every hook event, so it must be
/// fast and must never fail: the pet is not allowed to break the hook chain.
/// Every path returns normally and the caller always exits 0.
enum HookEmit {
    /// Where the pet keeps its files. `PET_HOME` overrides it for tests.
    static var baseDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ProcessInfo.processInfo.environment["PET_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".claude/pet")
    }

    /// One file per session, replaced in place: the CURRENT state.
    static var sessionsDirectory: URL { baseDirectory.appending(path: "sessions") }

    /// One append-only log per session: what its tool calls DID.
    static var activityDirectory: URL { baseDirectory.appending(path: "activity") }

    /// One file per finished turn: the RECORD that it happened.
    ///
    /// Separate from the session file on purpose. The session file only ever
    /// holds the latest state, so a turn that began and ended between two of the
    /// app's renders left no trace in it at all — and neither did one that
    /// finished while the app was suppressing speech. A finish the user never
    /// saw is the one thing this project is supposed to not do.
    static var eventsDirectory: URL { baseDirectory.appending(path: "events") }

    static func run(payload: Data) {
        guard
            let raw = try? JSONSerialization.jsonObject(with: payload),
            let hook = raw as? [String: Any]
        else { return }

        let sessionID = (hook["session_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A session id with a slash would escape the sessions directory.
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return }

        let directory = sessionsDirectory
        let path = directory.appending(path: sessionID + ".json")
        let event = hook["hook_event_name"] as? String ?? ""
        let message = hook["message"] as? String ?? ""

        // The session is over: drop its file now instead of leaving the watcher
        // to time it out fifteen minutes from now.
        if event == "SessionEnd" {
            try? FileManager.default.removeItem(at: path)
            // The activity log goes too: it describes a session that no longer
            // exists, and nothing can reach it any more.
            try? FileManager.default.removeItem(
                at: activityDirectory.appending(path: sanitise(sessionID) + ".jsonl"))
            return
        }

        guard let state = state(for: event, message: message) else { return }

        // PermissionRequest names the tool and its arguments, so the pet can say
        // WHAT is blocked rather than just that something is. Carried forward on
        // other events so the phrase survives until the session stops waiting.
        let waitingOn: String
        if event == "PermissionRequest" {
            waitingOn = PermissionSummary.describe(
                toolName: hook["tool_name"] as? String ?? "",
                toolInput: hook["tool_input"] as? [String: Any] ?? [:]
            )
        } else if state == "waiting" {
            waitingOn = previousWaitingOn(at: path)
        } else {
            waitingOn = ""
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = iso8601(Date())
        let cwd = hook["cwd"] as? String ?? ""

        var document: [String: Any] = [
            "sessionId": sessionID,
            "project": projectName(fromCWD: cwd),
            "cwd": cwd,
            "state": state,
            "tool": hook["tool_name"] as? String ?? "",
            "detail": message,
            "since": since(for: state, at: path, fallback: now),
            "waitingOn": waitingOn,
            "updatedAt": now,
        ]
        if let terminal = terminalRef() {
            document["terminal"] = terminal
        }
        // The pet decides liveness from this, so an idle session stays listed.
        if let pid = claudePID() {
            document["pid"] = pid
        }
        // Only a real user prompt updates this. It is what un-hides a session the
        // user muted: the session talking to itself — running tools, finishing a
        // turn — must not count as "we are back in conversation".
        // Never write an empty string here: the reader decodes this as a Date,
        // and "" is a value it rejects rather than a value it ignores.
        let prompt = lastPromptAt(for: event, at: path, now: now)
        if !prompt.isEmpty { document["lastPromptAt"] = prompt }

        // Which turn this is, counted from the session's own history.
        //
        // Claude Code's payload carries no turn identifier, and the obvious
        // stand-in — the timestamp of the prompt that began the turn — is only
        // second-resolution, so two turns inside one second collapse into one.
        // A counter is not a guess about ordering: it advances on exactly the
        // event that starts a turn, and on nothing else.
        let turn = turnNumber(for: event, at: path)
        document["turn"] = turn

        // Claude Code stamps every event of one turn with the same prompt_id.
        // That is the authoritative turn identifier and it is preferred over the
        // counter above, which stays only as a fallback for builds that do not
        // send one.
        let promptId = (hook["prompt_id"] as? String) ?? ""
        if !promptId.isEmpty { document["promptId"] = promptId }

        // Which tool calls are in flight, keyed by Claude Code's own
        // tool_use_id. Without this a PostToolUse left the finished tool showing
        // as "running", and two parallel calls showed as one.
        let running = runningTools(event: event, hook: hook, at: path, now: now)
        document["running"] = running

        // A phase is something the session is in the MIDDLE of that no other
        // event reports. Compaction is the only one so far: it takes a while,
        // emits nothing else, and without this the pet shows a session that has
        // apparently stopped working.
        let phase = phaseValue(event: event, at: path)
        if !phase.isEmpty { document["phase"] = phase }

        write(document, to: path)

        // A finished tool call, with the duration Claude Code measured itself.
        if event == "PostToolUse" {
            recordActivity(sessionID: sessionID, hook: hook, now: now)
        }

        // Stop is Claude Code telling us a turn ended — a confirmed event, not
        // something inferred from a session going quiet or disappearing.
        if event == "Stop" {
            recordCompletion(sessionID: sessionID, project: document["project"] as? String ?? "",
                             turnKey: promptId.isEmpty ? String(turn) : promptId, at: now)
        }
    }

    /// Identifies the terminal tab this session is running in, so the pet's
    /// panel can offer to jump back to it. The hook runs as a child of the
    /// Claude Code process, so it inherits the terminal's own environment.
    ///
    /// Returns nil for every terminal we cannot address, which is not a failure:
    /// that session's row simply will not be clickable.
    private static func terminalRef() -> [String: String]? {
        guard let ref = TerminalTarget.identify(environment: ProcessInfo.processInfo.environment)
        else { return nil }
        return ["kind": ref.kind, "handle": ref.handle]
    }

    /// When the user last actually typed into this session.
    ///
    /// Carried forward from the previous write for every event except
    /// UserPromptSubmit, which is the only one that means the human said
    /// something. Empty string for a session the user has not spoken to since
    /// this field existed, which reads as "no conversation yet".
    private static func lastPromptAt(for event: String, at path: URL, now: String) -> String {
        if event == "UserPromptSubmit" { return now }
        guard
            let data = try? Data(contentsOf: path),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let old = raw as? [String: Any],
            let previous = old["lastPromptAt"] as? String
        else { return "" }
        return previous
    }

    /// The tool calls currently in flight for this session.
    ///
    /// PreToolUse adds one, PostToolUse removes the matching one — matched by
    /// `tool_use_id`, which Claude Code puts on both. Matching by tool NAME
    /// would be wrong the moment two Bash calls run at once.
    ///
    /// Anything that ends a turn clears the list outright: a tool whose
    /// PostToolUse never arrived (the session was interrupted, the process was
    /// killed) must not sit there claiming to still be running.
    private static func runningTools(event: String, hook: [String: Any],
                                     at path: URL, now: String) -> [[String: Any]] {
        if event == "Stop" || event == "UserPromptSubmit" { return [] }

        var running = (readDocument(at: path)?["running"] as? [[String: Any]]) ?? []
        let id = (hook["tool_use_id"] as? String) ?? ""
        let tool = (hook["tool_name"] as? String) ?? ""

        switch event {
        case "PreToolUse":
            guard !tool.isEmpty else { break }
            // An id-less build would otherwise accumulate duplicates forever.
            let key = id.isEmpty ? tool : id
            running.removeAll { ($0["id"] as? String) == key }
            running.append([
                "id": key,
                "tool": tool,
                "target": ActivitySummary.target(toolName: tool,
                                                 toolInput: hook["tool_input"] as? [String: Any] ?? [:]),
                "since": now,
            ])
        case "PostToolUse":
            let key = id.isEmpty ? tool : id
            running.removeAll { ($0["id"] as? String) == key }
        default:
            break
        }
        // A runaway list is a bug somewhere else; cap it rather than write it.
        return Array(running.suffix(12))
    }

    /// Which multi-event phase the session is in, if any.
    ///
    /// Claude Code sends `PreCompact` when compaction starts but nothing when it
    /// finishes, so the phase is cleared by the first event that can only happen
    /// afterwards. Being stuck in a phase forever because one optional hook was
    /// missed is exactly the failure mode to avoid.
    private static func phaseValue(event: String, at path: URL) -> String {
        switch event {
        case "PreCompact": return "compacting"
        case "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse", "SessionStart":
            return ""
        default:
            return (readDocument(at: path)?["phase"] as? String) ?? ""
        }
    }

    /// This session's turn counter: bumped by UserPromptSubmit, carried by
    /// everything else. A turn redelivering its Stop therefore reports the same
    /// number, which is what makes the completion record idempotent.
    private static func turnNumber(for event: String, at path: URL) -> Int {
        let previous = (readDocument(at: path)?["turn"] as? Int) ?? 0
        return event == "UserPromptSubmit" ? previous + 1 : previous
    }

    private static func readDocument(at path: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: path),
            let raw = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return raw as? [String: Any]
    }

    /// The Claude Code process that invoked this hook.
    ///
    /// Claude Code runs hook commands through a shell, so `claude` is this
    /// process's grandparent rather than its parent — but that is an
    /// implementation detail, so this walks up the tree looking for it by name
    /// instead of assuming a fixed depth. Returns nil if it is not found, which
    /// leaves that session on the old timeout behaviour rather than breaking it.
    private static func claudePID() -> Int32? {
        ProcessProbe.findAncestor(
            named: ProcessProbe.claudeProcessName,
            from: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Maps a hook event to one of the three session states, or nil for events
    /// the pet does not care about — those must not touch the file at all.
    private static func state(for event: String, message: String) -> String? {
        if event == "Notification" {
            // Notification covers two different situations and only one of them
            // is worth interrupting the user over:
            //   "Claude needs your permission to use X" - the session is stuck
            //   "Claude is waiting for your input"      - it simply finished talking
            // Treating both as waiting made the pet hop until the user typed
            // something, for a session that was not blocked on anything.
            // An unrecognised message is treated as the blocking kind: a false
            // alarm is cheaper than a stuck session nobody notices.
            return message.contains("waiting for your input") ? "idle" : "waiting"
        }
        switch event {
        // Structured and unambiguous, unlike inferring intent from Notification's
        // English copy.
        case "PermissionRequest": return "waiting"
        case "SessionStart": return "idle"
        case "UserPromptSubmit": return "busy"
        case "PreToolUse": return "busy"
        case "PostToolUse": return "busy"
        case "Stop": return "idle"
        default: return nil
        }
    }

    /// The phrase from the last PermissionRequest, so that the events which
    /// follow it (a repeated Notification, say) do not blank the bubble.
    private static func previousWaitingOn(at path: URL) -> String {
        guard
            let data = try? Data(contentsOf: path),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let old = raw as? [String: Any]
        else { return "" }
        return old["waitingOn"] as? String ?? ""
    }

    /// Keep `since` across writes that do not change state, otherwise the 60s
    /// urgency escalation can never fire.
    private static func since(for state: String, at path: URL, fallback: String) -> String {
        guard
            let data = try? Data(contentsOf: path),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let old = raw as? [String: Any],
            old["state"] as? String == state,
            let previous = old["since"] as? String,
            !previous.isEmpty
        else { return fallback }
        return previous
    }

    private static func projectName(fromCWD cwd: String) -> String {
        var trimmed = cwd
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "~" : name
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Appends the record of one finished turn.
    ///
    /// The file name is derived from the session and the turn, so Claude Code
    /// delivering the same Stop twice overwrites one file rather than producing
    /// two rows. Failure here is silent by design: the pet may never break the
    /// hook chain, and a missing record is better than a broken session.
    private static func recordCompletion(sessionID: String, project: String,
                                         turnKey: String, at now: String) {
        guard let finishedAt = CompletionQueue.parseDate(now) else { return }
        let event = CompletionEvent(sessionId: sessionID, turnKey: turnKey,
                                    project: project, displayName: project,
                                    finishedAt: finishedAt)
        let directory = eventsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeAtomically(CompletionQueue.encode(event),
                        to: directory.appending(path: CompletionQueue.fileName(for: event)))
    }

    /// Appends one finished tool call to this session's log.
    ///
    /// Append, not read-modify-write: a hook has to finish fast, and a single
    /// short line reaches the file in one write. The reader tolerates a
    /// half-written last line, which is what a hook being killed leaves behind.
    private static func recordActivity(sessionID: String, hook: [String: Any], now: String) {
        guard
            let finishedAt = CompletionQueue.parseDate(now),
            let tool = hook["tool_name"] as? String, !tool.isEmpty
        else { return }

        // The only failure claimed is the one Claude Code states outright. A
        // non-empty stderr is not a failure — guessing from it would label half
        // of a normal build as broken.
        let response = hook["tool_response"] as? [String: Any]
        let result: ActivityEntry.Result
        if let response {
            result = (response["interrupted"] as? Bool == true) ? .interrupted : .ok
        } else {
            result = .unknown
        }

        let entry = ActivityEntry(
            tool: tool,
            target: ActivitySummary.target(toolName: tool,
                                           toolInput: hook["tool_input"] as? [String: Any] ?? [:]),
            finishedAt: finishedAt,
            durationMs: (hook["duration_ms"] as? Int) ?? 0,
            result: result)

        let directory = activityDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        append(ActivityLog.encode(entry),
               to: directory.appending(path: sanitise(sessionID) + ".jsonl"))
    }

    /// A session id is a uuid, but it arrives from outside and is about to
    /// become a file name.
    private static func sanitise(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(s.map { ok.contains($0) ? $0 : "_" })
    }

    /// Roughly this many bytes before the log is trimmed back.
    private static let activityTrimAt = 24_000

    private static func append(_ data: Data, to path: URL) {
        guard !data.isEmpty else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            try? data.write(to: path)
            return
        }
        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        // Trimming reads the whole file, so it happens by size rather than on
        // every call — a hook cannot afford that on every tool use.
        let size = (try? fm.attributesOfItem(atPath: path.path)[.size]) as? Int ?? 0
        if size > activityTrimAt { trim(path) }
    }

    private static func trim(_ path: URL) {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > ActivityLog.shown else { return }
        writeAtomically(Data((lines.suffix(ActivityLog.shown).joined(separator: "\n") + "\n").utf8),
                        to: path)
    }

    /// Write-then-rename so a reader never sees a half-written file.
    private static func write(_ document: [String: Any], to path: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
        writeAtomically(data, to: path)
    }

    private static func writeAtomically(_ data: Data, to path: URL) {
        guard !data.isEmpty else { return }
        // The temp name is unique per write, not per destination. Claude Code
        // runs tools in parallel, so two hooks for the SAME session can be in
        // flight at once, and a shared `.tmp` is a window where one write
        // silently becomes the other: B overwrites the temp file A just wrote,
        // then A renames B's bytes into place and A's update is gone.
        //
        // Not corruption — `replaceItemAt` is an atomic rename, and eight
        // concurrent hooks against a shared temp file produced no malformed
        // JSON when tried. A lost update, which is quieter and worse.
        let tmp = URL(fileURLWithPath: path.path
            + ".tmp.\(ProcessInfo.processInfo.processIdentifier).\(UInt32.random(in: 0...UInt32.max))")
        guard (try? data.write(to: tmp)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(path, withItemAt: tmp)) == nil {
            // replaceItemAt fails when the destination does not exist yet.
            if (try? FileManager.default.moveItem(at: tmp, to: path)) == nil {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }
}
