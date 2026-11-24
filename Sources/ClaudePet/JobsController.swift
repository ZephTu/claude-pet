import ClaudePetCore
import Foundation

/// The app's side of scheduled jobs (see ClaudePetCore/Jobs.swift for the whole picture):
/// what the board's Scheduled view reads and changes, the LaunchAgents that run the jobs, and
/// the pet's notices when a run ends.
///
/// The jobs themselves run without the app — this only edits them and reports on them.
@MainActor
final class JobsController {
    static let shared = JobsController()

    let store = JobStore()

    /// The runner every agent starts. The same binary as the hooks, installed with the app.
    var program: String { Jobs.petHome.appending(path: "pet-emit").path }

    // MARK: - For the board

    /// Every job with its recent runs and next run times.
    func list(now: Date = Date()) -> [String: Any] {
        let jobs = store.list().map { job -> [String: Any] in
            var o = dict(job)
            let runs = store.runs(job.id)
            o["runs"] = runs.prefix(30).map { $0.json() }
            o["running"] = runs.first(where: { $0.status != .skipped })?.status == .running
            o["installed"] = FileManager.default.fileExists(atPath: LaunchAgent.plistURL(for: job.id).path)
            if job.kind == .shell, let r = Recurring.parse(job.command) {     // a duty's recurring work
                o["recur"] = ["project": r.project, "template": r.template]
            }
            // How full the carried-on session is, for "same session every run".
            let state = store.state(job.id)
            if job.sessionMode == .resume, let ctx = state["contextTokens"] as? Int,
               let window = state["contextWindow"] as? Int, window > 0 {
                o["contextPct"] = Int((Double(ctx) * 100 / Double(window)).rounded())
            }
            if job.enabled {
                o["next"] = job.schedule.nextRuns(after: now, count: 3, anchor: anchor(job, runs))
                    .map { Jobs.iso($0) }
            }
            return o
        }
        let quota = Quota.current(claudeHome: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
                                  petHome: Jobs.petHome, store: store, now: now)
        return ["jobs": jobs, "runner": FileManager.default.isExecutableFile(atPath: program), "quota": quota.json(),
                "seenAt": Jobs.iso(seenAt)]
    }

    func save(_ raw: [String: Any]) async -> (Any?, String?) {
        var raw = raw
        if (raw["id"] as? String ?? "").isEmpty { raw["id"] = Jobs.newID() }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let job = try? JSONDecoder().decode(Job.self, from: data) else { return (nil, L("That job doesn't read as a job.", "这份内容读不出一个任务。")) }
        if let problem = job.problem() { return (nil, problem) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: job.directory, isDirectory: &isDir), isDir.boolValue else {
            return (nil, L("No such folder: \(job.directory)", "没有这个文件夹：\(job.directory)"))
        }
        let before = store.load(job.id)
        do { try store.save(job) } catch { return (nil, L("Couldn't save the job: \(error.localizedDescription)", "任务没能保存：\(error.localizedDescription)")) }
        // A changed session mode starts the session over.
        // A changed session mode or folder starts the session over (a session belongs to its folder).
        if before?.sessionMode != job.sessionMode || before?.directory != job.directory {
            store.setState(job.id) { $0.removeValue(forKey: "sessionId") }
        }
        // Only a changed schedule reloads the agent: launchd stops a running job when it does.
        if let err = await apply(job, onlyIfChanged: true) { return (nil, err) }
        return (["ok": true, "id": job.id], nil)
    }

    /// A project renamed: its recurring jobs (Recurring commands) now name the new one. The command
    /// is read at each run, so the schedule (and launchd) is left as it is.
    func retargetRecurring(from old: String, to new: String, hq: String) {
        for var job in store.list() where job.kind == .shell {
            guard let r = Recurring.parse(job.command), r.project == old else { continue }
            job.command = Recurring.command(hq: hq, project: new, template: r.template)
            job.name = "↻ \(new) · \(r.template)"
            try? store.save(job)
        }
    }

    func setEnabled(_ id: String, _ on: Bool) async -> (Any?, String?) {
        guard var job = store.load(id) else { return (nil, L("No such job", "没有这个任务")) }
        job.enabled = on
        do { try store.save(job) } catch { return (nil, error.localizedDescription) }
        if let err = await apply(job) { return (nil, err) }
        return (["ok": true], nil)
    }

    func delete(_ id: String) async -> (Any?, String?) {
        guard Jobs.isValidID(id) else { return (nil, L("No such job", "没有这个任务")) }
        await uninstall(id)
        do { try store.delete(id) } catch { return (nil, error.localizedDescription) }
        return (["ok": true], nil)
    }

    /// Starts a run now, whatever the schedule says. The runner takes the job's lock, so pressing
    /// it while a run is going only records a skip.
    /// `extra`: more runner arguments (the secretary's `--trigger chat --prompt-file …`).
    func runNow(_ id: String, extra: [String] = ["--manual"]) -> (Any?, String?) {
        guard store.load(id) != nil else { return (nil, L("No such job", "没有这个任务")) }
        guard FileManager.default.isExecutableFile(atPath: program) else { return (nil, Self.noRunner) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = ["--run-job", id] + extra
        p.environment = Self.cleanEnvironment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, L("Couldn't start it: \(error.localizedDescription)", "没能启动：\(error.localizedDescription)")) }
        return (["ok": true], nil)
    }

    /// Asks the running run to stop; the runner ends its whole process group within a second.
    func stop(_ id: String) -> (Any?, String?) {
        guard Jobs.isValidID(id) else { return (nil, L("No such job", "没有这个任务")) }
        FileManager.default.createFile(atPath: store.stopURL(id).path, contents: Data())
        return (["ok": true], nil)
    }

    /// For the form, while it is being filled in: is the schedule valid, and when would it run.
    func preview(_ raw: [String: Any], now: Date = Date()) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let schedule = try? JSONDecoder().decode(Schedule.self, from: data) else { return ["problem": "?"] }
        if let p = schedule.problem() { return ["problem": p] }
        return ["next": schedule.nextRuns(after: now, count: 3, anchor: now).map { Jobs.iso($0) }]
    }

    /// One run in full: the reply and the steps for a Claude run, the output for a command.
    func detail(_ id: String, run: String) -> (Any?, String?) {
        guard let job = store.load(id), let r = store.runs(id).first(where: { $0.id == run }),
              run.range(of: #"^[0-9a-z-]+$"#, options: .regularExpression) != nil
        else { return (nil, L("That run is gone", "这次运行的记录已经没了")) }
        var o: [String: Any] = ["job": dict(job), "run": r.json()]
        let logs = store.logsURL(id)
        if let stream = try? Data(contentsOf: logs.appending(path: run + ".jsonl")) {
            let parsed = ClaudeStreamResult.parse(stream)
            o["reply"] = parsed.reply
            o["steps"] = ClaudeStreamResult.steps(stream)
        }
        o["log"] = Self.tail(logs.appending(path: run + ".log"), bytes: 48_000)
        o["logPath"] = logs.appending(path: run + ".log").path
        return (o, nil)
    }

    /// The board's Scheduled view was looked at: failures up to now have been seen.
    func markSeen(now: Date = Date()) {
        seenAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.seenKey)
        onChange?()
    }

    // MARK: - LaunchAgents

    /// Brings the installed agents in line with the jobs: at launch, after an upgrade moved the
    /// runner, or after a job folder was deleted by hand.
    func syncAgents() async {
        let jobs = store.list()
        for job in jobs { _ = await apply(job, onlyIfChanged: true) }
        let ids = Set(jobs.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: LaunchAgent.directory.path)) ?? []
        for f in files where f.hasPrefix(LaunchAgent.labelPrefix) && f.hasSuffix(".plist") {
            let id = String(f.dropFirst(LaunchAgent.labelPrefix.count).dropLast(".plist".count))
            if !ids.contains(id), Jobs.isValidID(id) { await uninstall(id) }
        }
    }

    /// Installs the job's agent when it is on, removes it when it is off. nil, or what went wrong.
    @discardableResult
    private func apply(_ job: Job, onlyIfChanged: Bool = false) async -> String? {
        guard job.enabled else { await uninstall(job.id); return nil }
        guard FileManager.default.isExecutableFile(atPath: program) else { return Self.noRunner }
        let plist: Data
        do { plist = try LaunchAgent.plist(for: job, program: program) } catch {
            return (error as? CronSpec.ParseError)?.message ?? error.localizedDescription
        }
        let url = LaunchAgent.plistURL(for: job.id)
        if onlyIfChanged, (try? Data(contentsOf: url)) == plist { return nil }
        try? FileManager.default.createDirectory(at: LaunchAgent.directory, withIntermediateDirectories: true)
        let label = "gui/\(getuid())/\(LaunchAgent.label(for: job.id))"
        _ = await Self.launchctl(["bootout", label])
        do { try plist.write(to: url, options: .atomic) } catch { return L("Couldn't write \(url.path): \(error.localizedDescription)", "没能写入 \(url.path)：\(error.localizedDescription)") }
        let r = await Self.launchctl(["bootstrap", "gui/\(getuid())", url.path])
        if r.status != 0 { return L("macOS refused the schedule: ", "macOS 拒绝了这个定时：") + (r.err.isEmpty ? r.out : r.err).prefix(200) }
        // "Every N minutes" counts from here.
        store.setState(job.id) { $0["enabledAt"] = Jobs.iso(Date()) }
        return nil
    }

    private func uninstall(_ id: String) async {
        let url = LaunchAgent.plistURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = await Self.launchctl(["bootout", "gui/\(getuid())/\(LaunchAgent.label(for: id))"])
        try? FileManager.default.removeItem(at: url)
    }

    /// What "every N minutes" counts from: the later of the last scheduled run and when the job
    /// was switched on.
    private func anchor(_ job: Job, _ runs: [JobRun]) -> Date? {
        let enabled = Jobs.date(store.state(job.id)["enabledAt"])
        let last = runs.first(where: { $0.trigger == "schedule" })?.started
        return [enabled, last].compactMap { $0 }.max()
    }

    // MARK: - For the pet

    /// Called when something the pet shows changed (seen, ...), to redraw.
    var onChange: (() -> Void)?

    struct Report {
        /// Runs that ended since the last poll and want a notice.
        var notices: [(text: String, emphasis: String, jobId: String)] = []
        /// The pet list's Scheduled group: running jobs, and failures not yet seen.
        var rows: [[String: String]] = []
        var unseenFailures = 0
    }

    private var announced: Set<String>?
    private var seenAt = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: JobsController.seenKey))
    private static let seenKey = "jobs.seenAt"

    func poll(now: Date = Date()) -> Report {
        var report = Report()
        var ended = Set<String>()
        let first = announced == nil
        for job in store.list() {
            let runs = store.runs(job.id)
            // A run cut off ("interrupted") never wrote an end: it counts from when it started.
            for r in runs.prefix(20) where r.ended != nil || r.status == .lost { ended.insert(r.id) }
            if let r = runs.first(where: { $0.status != .skipped }), r.status == .running {
                report.rows.append(["job": job.id, "name": job.name, "status": "running",
                                    "text": L("running · ", "运行中 · ") + Chatter.duration(until: now, now: r.started)])
            } else if let r = runs.first(where: { $0.status != .skipped }), r.failed, (r.ended ?? r.started) > seenAt {
                report.unseenFailures += 1
                report.rows.append(["job": job.id, "name": job.name, "status": "failed",
                                    "text": Self.failureWord(r) + (r.summary.isEmpty ? "" : " · " + r.summary)])
            }
            guard !first else { continue }
            for r in runs.prefix(5) where (r.ended != nil || r.status == .lost) && !(announced?.contains(r.id) ?? false) {
                let wanted = job.notify == .always ? r.status != .skipped : job.notify == .failure && r.failed
                guard wanted else { continue }
                let what = r.failed ? Self.failureWord(r) : r.status == .stopped ? L("stopped", "已停止") : L("done", "完成")
                let tail = r.summary.isEmpty ? "" : " — " + (r.summary.count > 90 ? String(r.summary.prefix(90)) + "…" : r.summary)
                report.notices.append((text: L("Scheduled job \(what): \(job.name)\(tail)", "定时任务\(what)：\(job.name)\(tail)"), emphasis: job.name, jobId: job.id))
            }
        }
        // A restart must not replay old runs: the first poll only records what is there.
        announced = (announced ?? []).union(ended)
        return report
    }

    private static func failureWord(_ r: JobRun) -> String {
        switch r.status {
        case .timeout: return L("timed out", "超时")
        case .lost: return L("interrupted", "被打断")
        default: return r.exitCode.map { $0 == 0 ? L("failed", "失败") : L("failed (exit \($0))", "失败（退出码 \($0)）") } ?? L("failed", "失败")
        }
    }

    // MARK: - Helpers

    /// Computed, so it follows the language the pet is set to (see `L`).
    private static var noRunner: String {
        L("Claude Pet's runner (~/.claude/pet/pet-emit) isn't installed — reinstall Claude Pet.",
          "Claude Pet 的执行程序（~/.claude/pet/pet-emit）没装上 — 请重新安装 Claude Pet。")
    }

    private func dict(_ job: Job) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(job),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["id": job.id] }
        return o
    }

    private static func tail(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The app's environment, minus anything that would make a run look like part of the Claude
    /// Code session the app happened to be started from.
    nonisolated static func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key == "CLAUDE_PID" || key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    struct Output: Sendable { let status: Int32; let out: String; let err: String }

    nonisolated static func launchctl(_ args: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    return continuation.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                }
                p.waitUntilExit()
                continuation.resume(returning: Output(
                    status: p.terminationStatus,
                    out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
            }
        }
    }
}
