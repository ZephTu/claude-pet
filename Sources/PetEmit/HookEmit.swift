import ClaudePetCore
import Foundation

/// Translates one Claude Code hook payload into the pet's session state file.
///
/// This runs inside every Claude Code session on every hook event, so it must be
/// fast and must never fail: the pet is not allowed to break the hook chain.
/// Every path returns normally and the caller always exits 0.
enum HookEmit {
    /// Where state files live. `PET_HOME` overrides it for tests.
    static var sessionsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["PET_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".claude/pet")
        return base.appending(path: "sessions")
    }

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
            return
        }

        guard let state = state(for: event, message: message) else { return }

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

        write(document, to: path)
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
        case "SessionStart": return "idle"
        case "UserPromptSubmit": return "busy"
        case "PreToolUse": return "busy"
        case "PostToolUse": return "busy"
        case "Stop": return "idle"
        default: return nil
        }
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

    /// Write-then-rename so the watcher never reads a half-written file.
    private static func write(_ document: [String: Any], to path: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
        let tmp = URL(fileURLWithPath: path.path + ".tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(path, withItemAt: tmp)) == nil {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
