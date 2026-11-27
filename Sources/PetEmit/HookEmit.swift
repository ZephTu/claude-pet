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

    /// Appends the raw payload to `$PET_DUMP` when that variable is set.
    ///
    /// Off unless you ask for it, and it is the only thing here that writes a
    /// payload verbatim — a hook payload carries the prompt text, so this is a
    /// debugging tool rather than a feature. It exists because guessing at
    /// payload shapes has been wrong twice: a parser once listed five plausible
    /// spellings of the quota field and missed the real one, reading nothing
    /// while claiming to work. One captured payload settles what a whole
    /// afternoon of reasoning cannot.
    ///
    ///     PET_DUMP=/tmp/hooks.jsonl claude
    private static func dump(_ payload: Data) {
        guard let path = ProcessInfo.processInfo.environment["PET_DUMP"], !path.isEmpty
        else { return }
        var line = payload
        line.append(0x0a)
        // O_APPEND rather than seek-then-write: several hooks fire at once, and
        // seeking first let two of them land on the same offset. The first cut
        // of this produced a file whose lines were spliced into each other,
        // which is a poor start for a tool whose whole job is to show you
        // exactly what arrived.
        Portable.append(line, toFile: path)
    }

    static func run(payload: Data) {
        dump(payload)
        // A scheduled job's Claude run (see JobRunner): nobody is at that session, so the pet
        // must neither show it nor hold its permission prompts open waiting for an answer. Its
        // runs are reported from the job's own records instead.
        if ProcessInfo.processInfo.environment[Jobs.environmentKey] != nil { return }
        guard
            let raw = try? JSONSerialization.jsonObject(with: payload),
            let hook = raw as? [String: Any]
        else { return }

        let sessionID = (hook["session_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A session id with a slash (or, on Windows, a backslash) would escape the sessions directory.
        guard !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.contains("\\") else { return }
        // Claude Code puts the transcript path on every hook payload. One without it was typed
        // by hand — another session testing this binary with `echo '{"session_id":"x"}' |
        // pet-emit` — and recording it would list a session that does not exist, kept alive for
        // as long as the process that ran the test (a whole afternoon, under the "~" project).
        // Checked before SessionEnd too, so such a test cannot remove a real session either.
        // Present is enough: a relative path (CLAUDE_CONFIG_DIR set to one) is still a session.
        guard let transcript = hook["transcript_path"] as? String, !transcript.isEmpty
        else { return }

        let directory = sessionsDirectory
        let path = directory.appending(path: sessionID + ".json")
        let event = hook["hook_event_name"] as? String ?? ""
        let toolName = hook["tool_name"] as? String ?? ""
        let toolInput = hook["tool_input"] as? [String: Any] ?? [:]
        // A question card is answered on the card, and a plan is approved in its
        // own dialog — see PermissionSummary.isQuestion / isPlan — so either is
        // waiting for a reply, not for a permission the pet could grant. The board
        // answers both with their own controls (askKind).
        let askKind = event == "PermissionRequest" ? PermissionSummary.askKind(toolName: toolName) : ""
        let message = askKind == "question" ? PermissionSummary.questionNote(toolInput: toolInput)
            : askKind == "plan" ? PermissionSummary.planNote
            : hook["message"] as? String ?? ""

        // The session is over: drop its file now instead of leaving the watcher
        // to time it out fifteen minutes from now.
        if event == "SessionEnd" {
            withSessionLock(sessionID) {
                try? FileManager.default.removeItem(at: path)
                // The activity log goes too: it describes a session that no longer
                // exists, and nothing can reach it any more.
                try? FileManager.default.removeItem(
                    at: activityDirectory.appending(path: sanitise(sessionID) + ".jsonl"))
            }
            try? FileManager.default.removeItem(at: lockURL(sessionID))
            return
        }

        let kind = hook["notification_type"] as? String ?? ""
        guard var state = state(for: event, message: message, notificationType: kind) else { return }

        // Work this session parked in the background. A Stop with an agent still
        // running is the session pausing, not finishing — see BackgroundWork.
        let waitingForWork = BackgroundWork.waking(
            BackgroundWork.parse(hook["background_tasks"]))
        if event == "Stop", !waitingForWork.isEmpty { state = "busy" }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Everything that asks the kernel, before the lock: the lock is held only for reading
        // the old file and writing the new one.
        let askedAt = Date()
        let now = iso8601(askedAt)
        let cwd = hook["cwd"] as? String ?? ""
        // The pet decides liveness from this, so an idle session stays listed.
        // Resolved before the terminal because Ghostty's handle is the tty, and
        // this pid is the only process still holding one.
        let pid = claudePID()
        // A background session is in no terminal, whatever terminal variables it inherited
        // (TerminalTarget.isBackgroundSession); the board reaches it through `claude agents`.
        let background = TerminalTarget.isBackgroundSession(
            environment: ProcessInfo.processInfo.environment, sessionId: sessionID,
            parentArguments: pid.flatMap(ProcessProbe.parentPID).flatMap(ProcessProbe.arguments))
        let terminal = background ? nil
            : terminalRef(cwd: cwd, tty: pid.flatMap(ProcessProbe.controllingTTY) ?? "")
        // Who holds a prompt's hook open, and until when: the app offers Allow / Deny only
        // while that is true (SessionState.askAnswerable). Only while the app is there to be
        // clicked; a test that sets the wait itself is asking for it regardless.
        let holdsAsk = event == "PermissionRequest"
            && (ProcessInfo.processInfo.environment["PET_PERMISSION_WAIT"] != nil
                || ProcessProbe.isAnyRunning(named: "ClaudePet"))
        let holdFor = ProcessInfo.processInfo.environment["PET_PERMISSION_WAIT"]
            .flatMap(TimeInterval.init).map { min($0, PermissionDecision.wait) } ?? PermissionDecision.wait

        // One read-modify-write of the session file at a time. Claude Code fires the hooks of
        // parallel tool calls together; without the lock two PostToolUse each removed their own
        // call from the list the other had read, and a finished call stayed "running".
        let written: [String: Any] = withSessionLock(sessionID) {
            let old = readDocument(at: path)

            // The prompts up in this session, oldest first — see `pendingAsks`. A subagent's
            // prompt and another's can be up together, and neither may be washed out by the
            // other agents' tool calls, which go on while it waits.
            let newAsk: [String: Any]? = event == "PermissionRequest"
                ? askEntry(hook: hook, toolName: toolName, toolInput: toolInput, askKind: askKind,
                           message: message, old: old, holds: holdsAsk, askedAt: askedAt, holdFor: holdFor)
                : nil
            let asks = pendingAsks(event: event, hook: hook, old: old, adding: newAsk,
                                   keepAgents: !waitingForWork.isEmpty)
            // Which tool calls are in flight, keyed by Claude Code's own
            // tool_use_id. Without this a PostToolUse left the finished tool showing
            // as "running", and two parallel calls showed as one.
            let running = runningTools(event: event, hook: hook, old: old, now: now)
            if !asks.isEmpty { state = "waiting" }
            let top = asks.first

            var document: [String: Any] = [
                "sessionId": sessionID,
                "project": projectName(fromCWD: cwd),
                "cwd": cwd,
                "state": state,
                "tool": top?["tool"] as? String ?? toolName,
                "detail": top?["detail"] as? String ?? message,
                "since": top?["since"] as? String ?? since(for: state, old: old, fallback: now),
                "updatedAt": now,
            ]
            // The pet counts the session's turns from it — see TranscriptStats. Only a path it can
            // open without knowing Claude Code's working directory.
            if transcript.hasPrefix("/") {
                document["transcript"] = transcript
            }
            if let pid { document["pid"] = pid }
            if background {
                document["background"] = true
            } else if let terminal {
                document["terminal"] = terminal
            }

            // The prompt shown first, in the fields the app and the board read: which prompt it
            // is, so a click answers THIS one (PermissionDecision); WHAT is blocked, in short
            // and whole; a question's menu or a plan's text; who holds its hook open.
            mirror(asks, running: running, into: &document)
            // A wait with no prompt behind it — a dialog Claude Code announced only by
            // Notification — keeps the phrase the last prompt left, so it does not blank.
            // A question or a plan has none.
            document["waitingOn"] = top.map { $0["waitingOn"] as? String ?? "" }
                ?? (state == "waiting" ? old?["waitingOn"] as? String ?? "" : "")

            // Only a real user prompt updates this. It is what un-hides a session the
            // user muted: the session talking to itself — running tools, finishing a
            // turn — must not count as "we are back in conversation".
            // Never write an empty string here: the reader decodes this as a Date,
            // and "" is a value it rejects rather than a value it ignores.
            let prompt = lastPromptAt(for: event, hook: hook, old: old, now: now)
            if !prompt.isEmpty { document["lastPromptAt"] = prompt }

            // Which turn this is, counted from the session's own history.
            //
            // Claude Code's payload carries no turn identifier, and the obvious
            // stand-in — the timestamp of the prompt that began the turn — is only
            // second-resolution, so two turns inside one second collapse into one.
            // A counter is not a guess about ordering: it advances on exactly the
            // event that starts a turn, and on nothing else.
            document["turn"] = turnNumber(for: event, old: old)

            // Claude Code stamps every event of one turn with the same prompt_id.
            // That is the authoritative turn identifier and it is preferred over the
            // counter above, which stays only as a fallback for builds that do not
            // send one.
            let promptId = (hook["prompt_id"] as? String) ?? ""
            if !promptId.isEmpty { document["promptId"] = promptId }

            document["running"] = running

            // A phase is something the session is in the MIDDLE of that no other
            // event reports. Compaction is the only one so far: it takes a while,
            // emits nothing else, and without this the pet shows a session that has
            // apparently stopped working.
            // A Stop held open by a background agent is its own phase: the session
            // has stopped talking but has not stopped working, and nothing else in
            // the file says so. Only Stop carries `background_tasks`, and only Stop
            // sets this — a mid-turn event describes the tool it is running, which
            // is the more useful truth while a tool is running.
            let phase = event == "Stop" && !waitingForWork.isEmpty
                ? "awaiting-agent"
                : phaseValue(event: event, old: old)
            if !phase.isEmpty { document["phase"] = phase }

            // Named so the row can say what it is waiting for. Structural labels
            // only — never the task's free-text description.
            if event == "Stop", !waitingForWork.isEmpty {
                document["backgroundAgents"] = waitingForWork.map(\.label)
            }

            // When a tool call last came back interrupted. The app watches this for
            // CHANGES rather than for a flag being set, so the brief warning fires
            // once per failure instead of for as long as the value sits there.
            let trouble = troubleAt(event: event, hook: hook, old: old, now: now)
            if !trouble.isEmpty { document["troubleAt"] = trouble }

            // How many tool calls in a row have failed, and on what. A session that
            // keeps failing the same command is working on paper and going nowhere;
            // this is what lets the pet say so. Only the call's short target is
            // kept, never Claude Code's error text.
            let streak = failStreak(event: event, hook: hook, old: old)
            if streak.count > 0 {
                document["failStreak"] = streak.count
                document["failTarget"] = streak.target
            }

            write(document, to: path)
            return document
        }
        let askId = event == "PermissionRequest"
            ? ((written["asks"] as? [[String: Any]])?.last?["id"] as? String ?? "") : ""
        let promptId = (hook["prompt_id"] as? String) ?? ""
        let turn = written["turn"] as? Int ?? 0

        if holdsAsk, !askId.isEmpty {
            awaitDecision(sessionID: sessionID, askId: askId, sessionFile: path,
                          claudePID: pid, askedAt: askedAt, toolInput: toolInput,
                          command: askCommand(toolName: toolName, toolInput: toolInput))
        }

        // A finished tool call, with the duration Claude Code measured itself.
        if event == "PostToolUse" || event == "PostToolUseFailure" {
            recordActivity(sessionID: sessionID, hook: hook, now: now)
        }

        // Stop is Claude Code telling us a turn ended — a confirmed event, not
        // something inferred from a session going quiet or disappearing. It is
        // not, however, a finish while a background agent is still running: that
        // turn's Stop is a pause, and the turn that the agent wakes will fire
        // its own Stop with nothing left in flight. Recording both put a red dot
        // on a session nine minutes before it had anything to show.
        // A turn held only by a command that looks like a wait is recorded too,
        // marked held: that hold is a guess, and a wrong one must not lose the
        // finish. The app keeps it out of sight while the session is busy.
        let held = BackgroundWork.onlyWaits(waitingForWork)
        if event == "Stop", waitingForWork.isEmpty || held {
            recordCompletion(sessionID: sessionID, project: written["project"] as? String ?? "",
                             turnKey: promptId.isEmpty ? String(turn) : promptId, at: now,
                             summary: TurnSummary.headline(
                                hook["last_assistant_message"] as? String ?? ""),
                             held: held)
        }
    }

    /// Identifies the terminal tab this session is running in, so the pet's
    /// panel can offer to jump back to it. The hook runs as a child of the
    /// Claude Code process, so it inherits the terminal's own environment.
    ///
    /// Returns nil for every terminal we cannot address, which is not a failure:
    /// that session's row simply will not be clickable.
    /// - Parameter tty: the Claude Code process's controlling terminal. The hook
    ///   cannot read its own — it is run detached — so this is resolved from the
    ///   pid instead, and is empty for a session that has no terminal at all.
    private static func terminalRef(cwd: String, tty: String) -> [String: String]? {
        guard let ref = TerminalTarget.identify(environment: ProcessInfo.processInfo.environment,
                                                cwd: cwd, tty: tty)
        else { return nil }
        return ["kind": ref.kind, "handle": ref.handle]
    }

    /// When the user last actually typed into this session.
    ///
    /// Carried forward from the previous write for every event except
    /// UserPromptSubmit, which is the only one that means the human said
    /// something. Empty string for a session the user has not spoken to since
    /// this field existed, which reads as "no conversation yet".
    private static func lastPromptAt(for event: String, hook: [String: Any],
                                     old: [String: Any]?, now: String) -> String {
        if event == "UserPromptSubmit", isHuman(hook) { return now }
        return old?["lastPromptAt"] as? String ?? ""
    }

    /// Did a person type this prompt, or did the session wake itself up?
    ///
    /// When a background agent finishes, Claude Code resumes the session by
    /// submitting a prompt of its own — a real `UserPromptSubmit`, carrying a
    /// `<task-notification>` envelope instead of anything a human wrote. There
    /// is no flag on the payload that says so, so the opening tag is the only
    /// signal available.
    ///
    /// The distinction is load-bearing for muting: a muted session is supposed
    /// to come back "the next time YOU type into it", and an agent finishing is
    /// not the user speaking. Without this, an agent you dispatched an hour ago
    /// would silently unmute the session you had deliberately put away.
    ///
    /// This is the only place that looks at prompt text at all, it reads the
    /// first tag and nothing else, and it stores none of it. The only words of
    /// a conversation the pet keeps are one line of Claude's last message per
    /// finished turn — see `TurnSummary`.
    private static func isHuman(_ hook: [String: Any]) -> Bool {
        let prompt = (hook["prompt"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !prompt.hasPrefix("<task-notification>")
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
                                     old: [String: Any]?, now: String) -> [[String: Any]] {
        if event == "Stop" || event == "StopFailure" || event == "UserPromptSubmit" { return [] }

        var running = (old?["running"] as? [[String: Any]]) ?? []
        let id = (hook["tool_use_id"] as? String) ?? ""
        let tool = (hook["tool_name"] as? String) ?? ""

        switch event {
        case "PreToolUse":
            guard !tool.isEmpty else { break }
            // An id-less build would otherwise accumulate duplicates forever.
            let key = id.isEmpty ? tool : id
            running.removeAll { ($0["id"] as? String) == key }
            let input = hook["tool_input"] as? [String: Any] ?? [:]
            var call: [String: Any] = [
                "id": key,
                "tool": tool,
                "target": ActivitySummary.target(toolName: tool, toolInput: input),
                "since": now,
                // What a PermissionRequest is matched to this call by — see `askEntry`.
                "fp": fingerprint(toolName: tool, toolInput: input),
            ]
            if let agent = hook["agent_id"] as? String, !agent.isEmpty { call["agent"] = agent }
            running.append(call)
        case "PostToolUse", "PostToolUseFailure":
            let key = id.isEmpty ? tool : id
            running.removeAll { ($0["id"] as? String) == key }
        default:
            break
        }
        // A runaway list is a bug somewhere else; cap it rather than write it.
        return Array(running.suffix(12))
    }

    /// The timestamp of the most recent interrupted tool call.
    ///
    /// Only an interruption counts — that is the one failure Claude Code states
    /// outright. A non-empty stderr is not a failure, and a tool failing is
    /// usually not a task failing, which is why this drives a brief warning and
    /// not a mood.
    private static func troubleAt(event: String, hook: [String: Any],
                                  old: [String: Any]?, now: String) -> String {
        let previous = (old?["troubleAt"] as? String) ?? ""
        if event == "PostToolUseFailure" {
            return hook["is_interrupt"] as? Bool == true ? now : previous
        }
        guard event == "PostToolUse" else {
            // Cleared when a new turn starts: last turn's trouble is not this
            // turn's.
            return event == "UserPromptSubmit" ? "" : previous
        }
        let response = hook["tool_response"] as? [String: Any]
        return (response?["interrupted"] as? Bool == true) ? now : previous
    }

    /// Counts failed tool calls in a row. A success or a new prompt starts the
    /// count again; an interrupt is the user stopping it, not it failing, so it
    /// leaves the count alone.
    private static func failStreak(event: String, hook: [String: Any],
                                   old: [String: Any]?) -> (count: Int, target: String) {
        let count = old?["failStreak"] as? Int ?? 0
        let target = old?["failTarget"] as? String ?? ""
        switch event {
        case "PostToolUseFailure":
            guard hook["is_interrupt"] as? Bool != true else { return (count, target) }
            let tool = hook["tool_name"] as? String ?? ""
            let what = ActivitySummary.phrase(
                toolName: tool,
                target: ActivitySummary.target(toolName: tool,
                                               toolInput: hook["tool_input"] as? [String: Any] ?? [:]))
            return (count + 1, what)
        case "PostToolUse", "UserPromptSubmit", "SessionStart":
            return (0, "")
        default:
            return (count, target)
        }
    }

    /// Which multi-event phase the session is in, if any.
    ///
    /// Claude Code sends `PreCompact` when compaction starts but nothing when it
    /// finishes, so the phase is cleared by the first event that can only happen
    /// afterwards. Being stuck in a phase forever because one optional hook was
    /// missed is exactly the failure mode to avoid.
    private static func phaseValue(event: String, old: [String: Any]?) -> String {
        switch event {
        case "PreCompact": return "compacting"
        case "UserPromptSubmit", "Stop", "StopFailure", "PreToolUse", "PostToolUse",
             "PostToolUseFailure", "SessionStart":
            return ""
        default:
            return (old?["phase"] as? String) ?? ""
        }
    }

    /// This session's turn counter: bumped by UserPromptSubmit, carried by
    /// everything else. A turn redelivering its Stop therefore reports the same
    /// number, which is what makes the completion record idempotent.
    private static func turnNumber(for event: String, old: [String: Any]?) -> Int {
        let previous = (old?["turn"] as? Int) ?? 0
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
        ProcessProbe.findClaudeAncestor(from: ProcessInfo.processInfo.processIdentifier)
    }

    /// Maps a hook event to one of the three session states, or nil for events
    /// the pet does not care about — those must not touch the file at all.
    private static func state(for event: String, message: String,
                              notificationType: String) -> String? {
        if event == "Notification", !notificationType.isEmpty {
            // Structured since Claude Code started sending it, and preferred over
            // the English sentence below. It also names kinds the sentence test
            // could only call "waiting": an agent finishing or a quota pause
            // resuming made the pet raise its paw at a session that wanted
            // nothing. Kinds not listed here are not about this session needing
            // the user, so the file is left alone.
            switch notificationType {
            case "permission_prompt", "elicitation_dialog", "agent_needs_input": return "waiting"
            case "idle_prompt": return "idle"
            default: return nil
            }
        }
        if event == "Notification" {
            // Older builds send no notification_type, only the sentence.
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
        // Compaction is work, just not work the user asked for. Without a state
        // here the whole write is skipped and the phase never reaches the file.
        case "PreCompact": return "busy"
        case "PostToolUse": return "busy"
        // A failed call is still the session working: Claude reads the error
        // and carries on.
        case "PostToolUseFailure": return "busy"
        case "Stop": return "idle"
        // A turn killed by an API error — rate limit, overload, auth. Stop does
        // not fire for it, so without this the session sat on "busy" until the
        // 90s quiet rule caught it. Idle, not finished: no completion is
        // recorded, since nothing finished.
        case "StopFailure": return "idle"
        default: return nil
        }
    }

    /// The prompt a PermissionRequest puts up, as one row of the session's `asks`.
    ///
    /// PermissionRequest carries no tool_use_id, so the call it is about is found among the
    /// calls in flight: the newest with the same tool and input that no other prompt has
    /// claimed, from the same agent if there is one. Its PostToolUse is what takes the prompt
    /// down again — see `pendingAsks`.
    private static func askEntry(hook: [String: Any], toolName: String, toolInput: [String: Any],
                                 askKind: String, message: String, old: [String: Any]?,
                                 holds: Bool, askedAt: Date, holdFor: TimeInterval) -> [String: Any] {
        let hookAgent = hook["agent_id"] as? String ?? ""
        let fp = fingerprint(toolName: toolName, toolInput: toolInput)
        // Claimed by another agent's prompt. This agent's own are about to be replaced (see
        // `pendingAsks`), so the same call asking again keeps its call.
        let claimed = Set(currentAsks(old).filter { $0["agent"] as? String ?? "" != hookAgent }
            .compactMap { $0["toolUseId"] as? String })
        let calls = ((old?["running"] as? [[String: Any]]) ?? []).filter {
            $0["tool"] as? String == toolName && $0["fp"] as? String == fp
                && !claimed.contains($0["id"] as? String ?? "")
        }
        let call = calls.last { $0["agent"] as? String ?? "" == hookAgent } ?? calls.last
        // A subagent's PermissionRequest may not say which agent it is; its call does.
        let agent = hookAgent.isEmpty ? call?["agent"] as? String ?? "" : hookAgent
        var ask: [String: Any] = [
            "id": UUID().uuidString,
            "tool": toolName,
            "detail": message,
            "since": iso8601(askedAt),
        ]
        if !agent.isEmpty { ask["agent"] = agent }
        if let id = call?["id"] as? String { ask["toolUseId"] = id }
        // What tells its command's shell from another call's — see `shellIsShared`.
        ask["fp"] = fp
        // A question card is answered on the card, and a plan is approved in its own dialog —
        // see PermissionSummary.isQuestion / isPlan — so neither is a permission the pet could
        // grant, and neither has a phrase. The board answers both with their own controls.
        if askKind.isEmpty {
            ask["waitingOn"] = PermissionSummary.describe(toolName: toolName, toolInput: toolInput)
            ask["waitingOnFull"] = PermissionSummary.full(toolName: toolName, toolInput: toolInput)
            ask["command"] = askCommand(toolName: toolName, toolInput: toolInput)
        } else {
            ask["askKind"] = askKind
            if askKind == "plan" {
                ask["plan"] = String((toolInput["plan"] as? String ?? "").prefix(PermissionSummary.planLimit))
            } else if let questions = toolInput["questions"] as? [Any] {
                ask["questions"] = questions
            }
        }
        // Written before the hold starts, so the app never sees an ask with nobody behind it.
        if holds {
            ask["heldBy"] = Int(ProcessInfo.processInfo.processIdentifier)
            ask["heldUntil"] = iso8601(askedAt.addingTimeInterval(holdFor))
        }
        return ask
    }

    /// The prompts still up after `event`, oldest first; the first is the one the pet shows.
    ///
    /// A prompt stays up until the call it asked about ends — its own PostToolUse or
    /// PostToolUseFailure — or the turn does. Other calls ending, a subagent's or the main
    /// thread's, say nothing about it: with one file per session, treating every tool event as
    /// "the prompt was answered" dropped a subagent's prompt the moment any other agent ran a
    /// tool, while the terminal still showed it. A prompt matched to no call (an older build
    /// with no tool_use_id) ends with its agent's next tool event, as every prompt once did.
    /// - Parameter keepAgents: a Stop with background work still running keeps the prompts of
    ///   subagents, which go on after the main thread has stopped.
    private static func pendingAsks(event: String, hook: [String: Any], old: [String: Any]?,
                                    adding new: [String: Any]?, keepAgents: Bool) -> [[String: Any]] {
        var asks = currentAsks(old)
        let agent = hook["agent_id"] as? String ?? ""
        let tool = hook["tool_name"] as? String ?? ""
        let id = hook["tool_use_id"] as? String ?? ""
        let key = id.isEmpty ? tool : id
        func unmatched(_ a: [String: Any]) -> Bool {
            (a["toolUseId"] as? String ?? "").isEmpty && (a["agent"] as? String ?? "") == agent
        }
        switch event {
        case "Stop":
            asks = keepAgents ? asks.filter { !($0["agent"] as? String ?? "").isEmpty } : []
        case "StopFailure", "UserPromptSubmit", "SessionStart":
            asks = []
        case "PostToolUse", "PostToolUseFailure":
            asks.removeAll { ($0["toolUseId"] as? String ?? "") == key || unmatched($0) }
        case "PreToolUse":
            asks.removeAll(where: unmatched)
        case "PermissionRequest":
            if let new {
                // An agent has one prompt up at a time, so its new one replaces any before it:
                // the same call asking again, or one denied in the terminal — a denial fires
                // no PostToolUse, and the turn goes on.
                let asker = new["agent"] as? String ?? ""
                asks.removeAll { $0["agent"] as? String ?? "" == asker }
                asks.append(new)
            }
        default:
            break
        }
        // A runaway list is a bug somewhere else; cap it rather than write it.
        return Array(asks.suffix(8))
    }

    /// Puts the prompt shown first into the fields the app and the board read: which prompt it
    /// is, so a click answers THIS one (PermissionDecision); WHAT is blocked, in short and whole;
    /// a question's menu or a plan's text; who holds its hook open; the command it would run.
    private static let mirrored = [
        ("id", "askId"), ("waitingOn", "waitingOn"), ("waitingOnFull", "waitingOnFull"),
        ("askKind", "askKind"), ("plan", "plan"), ("questions", "questions"),
        ("heldBy", "askHeldBy"), ("heldUntil", "askHeldUntil"), ("command", "askCommand"),
    ]

    ///
    /// The command goes only while no other call running could have started the same shell:
    /// the app takes that shell for this prompt's approval (StateAggregator.wasApproved).
    private static func mirror(_ asks: [[String: Any]], running: [[String: Any]],
                               into document: inout [String: Any]) {
        for (_, to) in mirrored { document[to] = nil }
        document["asks"] = nil
        guard let top = asks.first else { return }
        for (from, to) in mirrored {
            if let v = top[from], (v as? String)?.isEmpty != true { document[to] = v }
        }
        if shellIsShared(top, running: running) { document["askCommand"] = nil }
        document["asks"] = asks
    }

    /// Could another call in flight have started the shell this prompt's command runs in?
    ///
    /// A shell is matched to a prompt by its command alone (ProcessProbe.startedToolShell).
    /// Two agents asking to run the same command — both `npm test` — start the same-looking
    /// shell: approving the first started one that read as the second's approval, and the
    /// second prompt left the pet while the terminal still showed it. Then only the call's
    /// own PostToolUse takes the prompt down.
    private static func shellIsShared(_ ask: [String: Any], running: [[String: Any]]) -> Bool {
        guard let fp = ask["fp"] as? String, !fp.isEmpty else { return false }
        let own = ask["toolUseId"] as? String ?? ""
        return running.contains { $0["fp"] as? String == fp && $0["id"] as? String != own }
    }

    /// Takes an answered prompt out of the session file, so the one behind it comes first.
    ///
    /// Denied, Claude Code fires no PostToolUse and the turn goes on, so nothing else would: the
    /// prompt stayed first in line — its plan on the board, its hold gone — and hid the next one
    /// until Stop. The call it was about is no longer running either (`callEnded`).
    ///
    /// Allowed, the call runs, and its PostToolUse comes only when it is done — after a long
    /// command, minutes. Until then the prompt stayed first, so the app read the whole session
    /// as approved and busy while the next prompt waited unseen in the terminal. The call stays
    /// running: it is.
    private static func dropAsk(_ askId: String, sessionID: String, path: URL, callEnded: Bool) {
        withSessionLock(sessionID) {
            guard var document = readDocument(at: path) else { return }
            let before = currentAsks(document)
            guard let gone = before.first(where: { $0["id"] as? String == askId }) else { return }
            let asks = before.filter { $0["id"] as? String != askId }
            let now = iso8601(Date())
            var running = document["running"] as? [[String: Any]] ?? []
            if callEnded, let call = gone["toolUseId"] as? String {
                running.removeAll { $0["id"] as? String == call }
                document["running"] = running
            }
            mirror(asks, running: running, into: &document)
            if let top = asks.first {
                document["tool"] = top["tool"] ?? ""
                document["detail"] = top["detail"] ?? ""
                document["since"] = top["since"] ?? now
            } else {
                document["state"] = "busy"
                document["detail"] = ""
                document["since"] = now
                document["waitingOn"] = ""
            }
            document["updatedAt"] = now
            write(document, to: path)
        }
    }

    /// The prompts the session file lists. A file written before the list existed has at most
    /// the one its top-level fields describe, still up while it says "waiting".
    private static func currentAsks(_ old: [String: Any]?) -> [[String: Any]] {
        guard let old else { return [] }
        if let asks = old["asks"] as? [[String: Any]] { return asks }
        guard old["state"] as? String == "waiting", let id = old["askId"] as? String, !id.isEmpty
        else { return [] }
        var ask: [String: Any] = ["id": id, "tool": old["tool"] ?? "", "detail": old["detail"] ?? "",
                                  "since": old["since"] ?? ""]
        for (from, to) in [("waitingOn", "waitingOn"), ("waitingOnFull", "waitingOnFull"),
                           ("askKind", "askKind"), ("plan", "plan"), ("questions", "questions"),
                           ("askHeldBy", "heldBy"), ("askHeldUntil", "heldUntil")] {
            if let v = old[from] { ask[to] = v }
        }
        return [ask]
    }

    /// The command a Bash prompt asks to run — what its approval starts a shell for (see
    /// ProcessProbe.startedToolShell). Only its start is kept for a long one.
    private static func askCommand(toolName: String, toolInput: [String: Any]) -> String {
        guard toolName == "Bash", let command = toolInput["command"] as? String else { return "" }
        return String(command.prefix(ProcessProbe.commandLimit))
    }

    /// A short, stable name for one tool call's input, for matching a PermissionRequest to the
    /// PreToolUse of the same call without keeping the input itself. FNV-1a: Swift's Hasher
    /// is seeded per process, and these are compared across processes.
    private static func fingerprint(toolName: String, toolInput: [String: Any]) -> String {
        let text = toolName + "\u{0}" + PermissionSummary.full(toolName: toolName, toolInput: toolInput)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// The per-session lock that one hook's read-modify-write of the session file runs under,
    /// beside that file. The app reaps it with the session's file (SessionWatcher).
    private static func lockURL(_ sessionID: String) -> URL {
        sessionsDirectory.appending(path: "." + sessionID + ".lock")
    }

    /// Runs `body` holding this session's lock. A hook may not hang, so after two seconds it
    /// gives up waiting and runs anyway — one lost update is better than a stuck session.
    private static func withSessionLock<T>(_ sessionID: String, _ body: () -> T) -> T {
        Portable.withFileLock(lockURL(sessionID).path, attempts: 400, interval: 0.005, body)
    }

    /// Holds the PermissionRequest hook open until the user answers from the
    /// pet, then prints that answer as the hook's output.
    ///
    /// Claude Code shows its own dialog at the same time and takes whichever
    /// answer comes first, so waiting here never delays the terminal prompt.
    /// Every way out other than a click prints nothing, which leaves the
    /// decision to the terminal exactly as if the pet did not exist:
    /// - the session file no longer lists this prompt (its call ended, the turn did, or
    ///   another hold answered it);
    /// - Claude started the shell running the command asked about — answered in
    ///   the terminal, with nothing written since because the command is running.
    ///   The prompt comes down, as on a click, so a prompt behind it is shown. Not
    ///   while another call in flight runs the same command (`shellIsShared`);
    /// - the Claude process is gone;
    /// - `PermissionDecision.wait` ran out.
    private static func awaitDecision(sessionID: String, askId: String, sessionFile: URL,
                                      claudePID: Int32?, askedAt: Date, toolInput: [String: Any],
                                      command: String) {
        let answerFile = PermissionDecision.fileURL(petHome: baseDirectory, sessionId: sessionID)
        // `PET_PERMISSION_WAIT` overrides the wait for tests; 0 turns it off.
        let wait = ProcessInfo.processInfo.environment["PET_PERMISSION_WAIT"]
            .flatMap(TimeInterval.init) ?? PermissionDecision.wait
        let deadline = askedAt.addingTimeInterval(min(wait, PermissionDecision.wait))
        while Date() < deadline {
            if let data = try? Data(contentsOf: answerFile),
               let answer = PermissionDecision.decode(data), answer.askId == askId {
                try? FileManager.default.removeItem(at: answerFile)
                FileHandle.standardOutput.write(PermissionDecision.hookOutput(answer, toolInput: toolInput))
                // Answered either way, so it comes down now. An allowed call goes on running
                // until its PostToolUse; a denied one ends here.
                dropAsk(askId, sessionID: sessionID, path: sessionFile,
                        callEnded: answer.behavior == .deny)
                return
            }
            let document = readDocument(at: sessionFile)
            if PermissionDecision.isStale(askId: askId, sessionDocument: document) {
                return
            }
            if let claudePID {
                if !ProcessProbe.isClaude(pid: claudePID) { return }
                let ask = currentAsks(document).first { $0["id"] as? String == askId } ?? [:]
                let running = document?["running"] as? [[String: Any]] ?? []
                if !command.isEmpty, !shellIsShared(ask, running: running),
                   ProcessProbe.startedToolShell(under: claudePID, since: askedAt, running: command) {
                    dropAsk(askId, sessionID: sessionID, path: sessionFile, callEnded: false)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Keep `since` across writes that do not change state, otherwise the 60s
    /// urgency escalation can never fire.
    private static func since(for state: String, old: [String: Any]?, fallback: String) -> String {
        guard
            let old,
            old["state"] as? String == state,
            let previous = old["since"] as? String,
            !previous.isEmpty
        else { return fallback }
        return previous
    }

    private static func projectName(fromCWD cwd: String) -> String {
        var trimmed = cwd
        #if os(Windows)
        // C:\work\demo: Windows hands the hook backslashes.
        trimmed = trimmed.replacingOccurrences(of: "\\", with: "/")
        #endif
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
                                         turnKey: String, at now: String, summary: String,
                                         held: Bool = false) {
        guard let finishedAt = CompletionQueue.parseDate(now) else { return }
        var event = CompletionEvent(sessionId: sessionID, turnKey: turnKey,
                                    project: project, displayName: project,
                                    finishedAt: finishedAt, summary: summary, held: held)
        let directory = eventsDirectory
        let file = directory.appending(path: CompletionQueue.fileName(for: event))
        // The wait came back and the session finished for real: the finish it
        // was holding is this one, not a second.
        if !held { dropHeld(sessionID: sessionID, except: file, in: directory) }
        // The same turn ending again — HQ's Stop hook sent the reply back to be
        // corrected, and the corrected reply holds only that block — says nothing
        // of its own: the line the turn first ended with stays.
        if summary.isEmpty, let data = try? Data(contentsOf: file),
           let before = CompletionQueue.decode([data]).first, !before.summary.isEmpty {
            event = CompletionEvent(sessionId: sessionID, turnKey: turnKey,
                                    project: project, displayName: project,
                                    finishedAt: finishedAt, summary: before.summary, held: held)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeAtomically(CompletionQueue.encode(event), to: file)
    }

    /// Removes this session's held finishes — see `CompletionEvent.held`.
    private static func dropHeld(sessionID: String, except keep: URL, in directory: URL) {
        let prefix = CompletionQueue.fileName(for: CompletionEvent(
            sessionId: sessionID, turnKey: "x", project: "", displayName: "",
            finishedAt: Date())).dropLast("x.json".count)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix)
            && file.lastPathComponent != keep.lastPathComponent {
            guard let data = try? Data(contentsOf: file),
                  CompletionQueue.decode([data]).first?.held == true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Records this session's last finished tool call, replacing the one before
    /// — see ActivityLog. Write-then-rename, so a hook killed mid-write leaves
    /// the previous call rather than half of this one.
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
        if hook["hook_event_name"] as? String == "PostToolUseFailure" {
            result = hook["is_interrupt"] as? Bool == true ? .interrupted : .failed
        } else if let response {
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
        writeAtomically(ActivityLog.encode(entry),
                        to: directory.appending(path: sanitise(sessionID) + ".jsonl"))
    }

    /// A session id is a uuid, but it arrives from outside and is about to
    /// become a file name.
    private static func sanitise(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(s.map { ok.contains($0) ? $0 : "_" })
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
        if (try? Portable.replaceItem(at: path, withItemAt: tmp)) == nil {
            // replaceItemAt fails when the destination does not exist yet.
            if (try? FileManager.default.moveItem(at: tmp, to: path)) == nil {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }
}
