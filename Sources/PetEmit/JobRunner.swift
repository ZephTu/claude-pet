import ClaudePetCore
import Foundation

/// `pet-emit --run-job <id> [--manual]`: one run of a scheduled job — what its LaunchAgent
/// starts on schedule, and what the board's "Run now" starts.
///
/// It records the run in the job's `runs.jsonl` (a line when it starts, a line when it ends),
/// keeps the output in `logs/`, and for a Claude job carries the session between runs or
/// deletes the old ones. Everything the job runs goes through the user's login shell
/// (`zsh -lic`), so PATH, and anything else set up for their terminal, is what they expect.
enum JobRunner {
    static func run(id: String, trigger: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let store = JobStore()
        guard Jobs.isValidID(id), let job = store.load(id) else {
            FileHandle.standardError.write(Data("pet-emit: no job \(id)\n".utf8))
            return 2
        }
        try? FileManager.default.createDirectory(at: store.logsURL(id), withIntermediateDirectories: true)

        // One run at a time: a run that outlasts its interval makes the next one a skip, which
        // the history shows, rather than two runs fighting over one session.
        let lockFD = open(store.folder(id).appending(path: "lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            store.append(id, ["run": JobStore.newRunID(), "event": "skip", "at": iso(Date()), "trigger": trigger,
                              "summary": "skipped: the previous run was still going"])
            return 0
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        try? FileManager.default.removeItem(at: store.stopURL(id))

        let runID = JobStore.newRunID()
        let outPath = store.logsURL(id).appending(path: runID + (job.kind == .claude ? ".jsonl" : ".log")).path
        let errPath = store.logsURL(id).appending(path: runID + ".log").path
        var env = ProcessInfo.processInfo.environment
        env[Jobs.environmentKey] = id
        env["CLAUDE_PET_RUN"] = runID
        let cwd = job.directory

        var start: [String: Any] = ["run": runID, "event": "start", "at": iso(Date()), "trigger": trigger,
                                    "pid": Int(getpid())]
        var end: [String: Any] = ["run": runID, "event": "end"]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            store.append(id, start)
            end["at"] = iso(Date()); end["status"] = "fail"; end["summary"] = "no such directory: \(cwd)"
            store.append(id, end)
            return 0
        }

        switch job.kind {
        case .shell:
            store.append(id, start)
            let r = execute(["/bin/zsh", "-lic", job.command], cwd: cwd, env: env, stdin: nil,
                            out: outPath, err: outPath, timeout: job.timeoutMinutes, stop: store.stopURL(id))
            let lines = tailLines(outPath, 8)
            end["exitCode"] = Int(r.code)
            end["status"] = r.stopped ? "stopped" : r.timedOut ? "timeout" : r.code == 0 ? "ok" : "fail"
            end["summary"] = lines.last ?? ""
            if r.code != 0 || r.timedOut { end["tail"] = lines.joined(separator: "\n") }

        case .claude:
            // Quota guard: leave the rest of the subscription for the user's own work.
            let quota = Quota.current(claudeHome: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
                                      petHome: Jobs.petHome, store: store)
            if let reason = quota.reasonToSkip(weekPct: job.skipWeekPct, fiveHourPct: job.skipFiveHourPct) {
                store.append(id, ["run": runID, "event": "skip", "at": iso(Date()), "trigger": trigger, "summary": reason])
                return 0
            }
            var state = store.state(id)
            var sid = UUID().uuidString.lowercased()
            var resuming = false
            if job.sessionMode == .resume, let s = state["sessionId"] as? String, transcript(of: s) != nil {
                sid = s
                resuming = true
            }
            start["sessionId"] = sid
            store.append(id, start)
            let base = claudeFlags(job)
            // A long-lived session is compacted before it gets heavy, so every run doesn't
            // re-read its whole history.
            if resuming, job.compactAbovePct > 0, let ctx = state["contextTokens"] as? Int,
               let window = state["contextWindow"] as? Int, window > 0, ctx * 100 >= job.compactAbovePct * window {
                _ = execute(shellClaude(["-p", "--output-format", "json", "--resume", sid] + base.model),
                            cwd: cwd, env: env, stdin: "/compact", out: errPath, err: errPath,
                            timeout: 15, stop: store.stopURL(id))
            }
            let session = resuming ? ["--resume", sid] : ["--session-id", sid, "--name", "⏱ " + job.name]
            let r = execute(shellClaude(["-p", "--output-format", "stream-json", "--verbose"] + session + base.all),
                            cwd: cwd, env: env, stdin: job.prompt, out: outPath, err: errPath,
                            timeout: job.timeoutMinutes, stop: store.stopURL(id))
            let result = ClaudeStreamResult.parse((try? Data(contentsOf: URL(fileURLWithPath: outPath))) ?? Data())
            let errLines = tailLines(errPath, 8)
            let ok = r.code == 0 && result.finished && !result.isError
            end["exitCode"] = Int(r.code)
            end["status"] = r.stopped ? "stopped" : r.timedOut ? "timeout" : ok ? "ok" : "fail"
            end["sessionId"] = result.sessionId ?? sid
            end["denials"] = result.denials
            if let c = result.costUSD { end["costUSD"] = c }
            if let t = result.turns { end["turns"] = t }
            if let c = result.contextTokens { end["contextTokens"] = c }
            if let w = result.contextWindow { end["contextWindow"] = w }
            if let q = result.quotaFirst { end["quotaBefore"] = q.json() }
            if let q = result.quotaLast {
                end["quotaAfter"] = q.json()
                // The freshest reading there is: the next run's quota guard starts from it.
                if let data = try? JSONSerialization.data(withJSONObject: q.json()) {
                    try? data.write(to: store.quotaURL, options: .atomic)
                }
            }
            let firstLine = result.reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            end["summary"] = String((ok ? firstLine : (result.errorText.isEmpty ? errLines.last ?? firstLine : result.errorText)).prefix(300))
            if !ok { end["tail"] = (errLines + (result.errorText.isEmpty ? [] : [result.errorText])).joined(separator: "\n") }

            if job.sessionMode == .resume {
                if result.sessionId != nil || transcript(of: sid) != nil {
                    state["sessionId"] = result.sessionId ?? sid
                    if let c = result.contextTokens { state["contextTokens"] = c }
                    if let w = result.contextWindow { state["contextWindow"] = w }
                    store.setState(id) { $0 = state }
                }
            }
        }
        end["at"] = iso(Date())
        store.append(id, end)

        if job.kind == .claude, job.sessionMode == .fresh {
            for old in JobRun.sessionsToPrune(store.runs(id), keep: job.keepSessions) { deleteTranscript(old) }
        }
        store.trim(id)
        return 0
    }

    // MARK: - Building the command

    struct Flags { var model: [String]; var all: [String] }

    static func claudeFlags(_ job: Job) -> Flags {
        let model = job.model.isEmpty ? [] : ["--model", job.model]
        var all = model
        switch job.permission {
        case .standard: break
        case .edits: all += ["--permission-mode", "acceptEdits"]
        case .all: all += ["--dangerously-skip-permissions"]
        }
        return Flags(model: model, all: all)
    }

    /// `claude <args>` through the login shell; the arguments go in as "$@", never as text the
    /// shell would read.
    static func shellClaude(_ args: [String]) -> [String] {
        ["/bin/zsh", "-lic", "exec claude \"$@\"", "claude-pet-job"] + args
    }

    // MARK: - Sessions on disk

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// Claude Code keeps a session as `~/.claude/projects/<folder>/<id>.jsonl`.
    static func transcript(of session: String) -> URL? {
        guard session.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        for d in dirs {
            let f = projectsDirectory.appending(path: d).appending(path: session + ".jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    static func deleteTranscript(_ session: String) {
        guard let f = transcript(of: session) else { return }
        try? FileManager.default.removeItem(at: f)
        // Its subagents' transcripts, when it had any.
        try? FileManager.default.removeItem(at: f.deletingPathExtension())
    }

    // MARK: - Running a process

    struct Outcome { var code: Int32; var timedOut: Bool; var stopped: Bool }

    /// Runs `argv` in its own process group, so a timeout or a stop ends everything it started.
    static func execute(_ argv: [String], cwd: String, env: [String: String], stdin: String?,
                        out: String, err: String, timeout minutes: Int, stop: URL) -> Outcome {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var pipeFDs: [Int32] = [-1, -1]
        if stdin != nil, pipe(&pipeFDs) == 0 {
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if err == out {
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, err, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let cargs = argv.map { strdup($0) } + [nil]
        let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cargs, cenv)
        if pipeFDs[0] >= 0 { close(pipeFDs[0]) }
        guard rc == 0 else {
            if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
            appendText(err, "could not start \(argv[0]): \(String(cString: strerror(rc)))\n")
            return Outcome(code: 127, timedOut: false, stopped: false)
        }
        if let stdin, pipeFDs[1] >= 0 {
            let data = Data(stdin.utf8)
            data.withUnsafeBytes { p in
                var off = 0
                while off < data.count {
                    let n = write(pipeFDs[1], p.baseAddress! + off, data.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(pipeFDs[1])
        }

        let deadline = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
        var timedOut = false, stopped = false
        var killAt: Date?
        var status: Int32 = 0
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid || (w < 0 && errno != EINTR) { break }
            if killAt == nil {
                if FileManager.default.fileExists(atPath: stop.path) { stopped = true }
                else if Date() > deadline { timedOut = true }
                if stopped || timedOut {
                    kill(-pid, SIGTERM)
                    killAt = Date().addingTimeInterval(10)
                    appendText(err, stopped ? "\n[stopped from Claude Pet]\n" : "\n[stopped: over the \(minutes)-minute limit]\n")
                }
            } else if let k = killAt, Date() > k {
                kill(-pid, SIGKILL)
                killAt = .distantFuture
            }
            usleep(200_000)
        }
        // Anything it left running in its group goes with it.
        kill(-pid, SIGTERM)
        let signaled = status & 0x7f
        let code: Int32 = signaled == 0 ? (status >> 8) & 0xff : 128 + signaled
        return Outcome(code: code, timedOut: timedOut, stopped: stopped)
    }

    static func appendText(_ path: String, _ text: String) {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let d = Data(text.utf8)
        d.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// The last `n` non-empty lines of a log, each cut short.
    static func tailLines(_ path: String, _ n: Int) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).map { String($0.prefix(300)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(n).map { $0 }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
