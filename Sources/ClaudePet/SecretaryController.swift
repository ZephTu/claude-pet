import ClaudePetCore
import Foundation

/// The secretary: the board's standing chat with an agent that knows the HQ board.
///
/// What it is made of, all reused:
/// - `hq secretary init` scaffolds the agent definition (`<root>/.claude/agents/secretary.md`), its
///   memory (`<root>/secretary/*.md`) and its own task card, whose asks are its proposals;
/// - a scheduled job, `secretary`, holds the session: Claude runs in the task root as
///   `--agent secretary`, the same session every run, compacted past a threshold and skipped
///   when the subscription's quota is nearly used up (see Jobs.swift). Each message from the board
///   is one run, its text the run's prompt. Its schedule, off until the user turns it on from the
///   secretary's window, is the evening report: weekdays at 18:30, the weekly one on Fridays
///   (`hq report` picks which);
/// - the session is bound to the secretary's card, so the hq hooks give it the card's rules, file
///   its `hq-asks` as asks in Needs you, and tell it the answers at its next turn;
/// - the board shows the conversation in Peek, by the session's id;
/// - a second job, `secretary-feed`, brings in what reached the user on Zulip and Jira: a shell job
///   running `hq feed all` hourly on weekdays (off until turned on from the window), which files
///   each conversation or issue into the inbox for the sorter.
@MainActor
final class SecretaryController {
    static let shared = SecretaryController()

    static let jobID = "secretary"
    static let feedJobID = "secretary-feed"
    /// Weekdays, every hour from 9:00 to 19:00.
    static let feedSchedule = Schedule(kind: .cron, cron: "0 9-19 * * 1-5")
    private var jobs: JobsController { JobsController.shared }
    private var store: JobStore { jobs.store }

    /// What hq last said about the secretary (`hq secretary --json`).
    private var info: [String: Any] = [:]
    /// The secretary's asks answered Yes since its last wake-up: it runs once they have settled.
    private var answeredYes: Set<String> = []
    private var waking = false
    /// A run was launched and hasn't recorded its start yet (the runner records it only after
    /// taking the job's lock and checking the quota): the newest run record at launch time.
    private var launched: (after: String?, at: Date)?

    /// How long a Yes waits before the secretary acts on it: longer than the board's Undo
    /// (8 s), and answering several asks one after another makes one run.
    static let wakeGrace: Duration = .seconds(10)

    /// Runs hq with these arguments: (stdout, error). Set by the board's bridge, which knows where
    /// hq is and how to run it.
    var hq: (([String]) async -> (String?, String?))?

    // MARK: - For the board

    /// Whether it is set up, its session, and whether it is answering right now.
    func status() async -> (Any?, String?) {
        if let err = await refreshInfo() { return (nil, err) }
        var o = info
        let state = store.state(Self.jobID)
        let runs = store.runs(Self.jobID)
        o["job"] = store.load(Self.jobID) != nil
        o["sessionId"] = state["sessionId"] as? String ?? ""
        o["running"] = running
        if let r = runs.first {
            // The last run when it went wrong, or was skipped (quota): the chat says why.
            o["last"] = ["status": r.status.rawValue, "summary": r.summary, "at": Jobs.iso(r.ended ?? r.started),
                         "failed": r.failed]
        }
        if let ctx = state["contextTokens"] as? Int, let window = state["contextWindow"] as? Int, window > 0 {
            o["contextPct"] = Int((Double(ctx) * 100 / Double(window)).rounded())
        }
        o["waking"] = !answeredYes.isEmpty
        if let job = store.load(Self.jobID) {
            // A job from before reports shows what ensureJob will make of it.
            let migrating = Self.needsMigration(job)
            let sch = migrating ? Self.migratedSchedule(job.schedule) : job.schedule
            o["schedule"] = ["enabled": job.enabled, "kind": sch.kind.rawValue,
                             // false: its scheduled runs ask something else (the user's own prompt).
                             "reports": migrating || Self.writesReports(job),
                             "hour": sch.hour, "minute": sch.minute,
                             "next": job.enabled ? (job.schedule.nextRuns(after: Date(), count: 1, anchor: nil).first.map(Jobs.iso) ?? "") : ""]
        }
        o["feed"] = feedStatus()
        return (o, nil)
    }

    /// The scan's job: on or off, when next, and how its last run went.
    private func feedStatus() -> [String: Any] {
        guard let job = store.load(Self.feedJobID) else { return ["job": false, "enabled": false] }
        var f: [String: Any] = ["job": true, "enabled": job.enabled, "kind": job.schedule.kind.rawValue,
                                "cron": job.schedule.cron, "running": store.runs(Self.feedJobID).first(where: { $0.status != .skipped })?.status == .running,
                                "next": job.enabled ? (job.schedule.nextRuns(after: Date(), count: 1, anchor: nil).first.map(Jobs.iso) ?? "") : ""]
        if let r = store.runs(Self.feedJobID).first {
            f["last"] = ["status": r.status.rawValue, "summary": r.summary, "at": Jobs.iso(r.ended ?? r.started), "failed": r.failed]
        }
        return f
    }

    /// The scan on or off. Made on first use; the user may change its schedule in Scheduled, and
    /// what makes it the scan (a shell job running `hq feed all` in the task root) is put back.
    func setFeed(on: Bool) async -> (Any?, String?) {
        if info["root"] == nil, let err = await refreshInfo() { return (nil, err) }
        guard let root = info["root"] as? String, !root.isEmpty else { return (nil, L("No HQ root", "找不到 HQ 根目录")) }
        let command = Self.feedCommand
        var job = store.load(Self.feedJobID) ?? Job(
            id: Self.feedJobID, name: L("Secretary: scan Zulip · Jira", "秘书：扫描 Zulip · Jira"), kind: .shell, command: command,
            cwd: root, schedule: Self.feedSchedule, enabled: false, timeoutMinutes: 15, notify: .failure)
        if store.load(Self.feedJobID) == nil || job.kind != .shell || job.command != command || job.directory != root {
            job.kind = .shell; job.command = command; job.cwd = root
            if let err = await save(job) { return (nil, err) }
        }
        let r = await jobs.setEnabled(Self.feedJobID, on)
        if let err = r.1 { return (nil, err) }
        return await status()
    }

    /// One scan now (the job is made, off, if it isn't there yet).
    func feedNow() async -> (Any?, String?) {
        if store.load(Self.feedJobID) == nil {
            let r = await setFeed(on: false)
            if let err = r.1 { return (nil, err) }
        }
        let r = jobs.runNow(Self.feedJobID)
        if let err = r.1 { return (nil, err) }
        return await status()
    }

    static var feedCommand: String {
        "'\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/hq/bin/hq' feed all"
    }

    /// Scaffolds what is missing and makes the job. `lang`: the board's language, for the memory
    /// files' and the card's wording.
    func setup(lang: String) async -> (Any?, String?) {
        guard let hq else { return (nil, "no hq") }
        let r = await hq(["secretary", "init", "--lang", lang == "zh" ? "zh" : "en", "--json"])
        if let err = r.1 { return (nil, err) }
        if let err = parseInfo(r.0) { return (nil, err) }
        if let err = await ensureJob() { return (nil, err) }
        // Its session id and binding now, so a run from Scheduled (Run now, or a schedule) before
        // the first chat is already the secretary's session.
        if let err = await prepare() { return (nil, err) }
        return await status()
    }

    /// Sends a message: one run of the job, with the message as its prompt.
    func send(_ text: String) async -> (Any?, String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, L("Nothing to send", "没有要发送的内容")) }
        if running { return (nil, L("The secretary is still answering — wait for it, or stop it.", "秘书还在回复上一条——等它说完，或者先停下。")) }
        if let err = await prepare() { return (nil, err) }
        return start(text, trigger: "chat")
    }

    /// The evening report on or off: the job's schedule (weekdays 18:30 unless the user changed it
    /// in Scheduled). Turning it on gives the job the report prompt if it asks something else, and
    /// a fixed time if it runs every N minutes: the user asked for reports, from the window.
    func setReports(on: Bool) async -> (Any?, String?) {
        if let err = await prepare() { return (nil, err) }
        if on, var job = store.load(Self.jobID), !Self.writesReports(job) {
            job.prompt = Self.reportPrompt
            if job.schedule.kind == .every { job.schedule = Self.reportSchedule }
            if let err = await save(job) { return (nil, err) }
        }
        let r = await jobs.setEnabled(Self.jobID, on)
        if let err = r.1 { return (nil, err) }
        return await status()
    }

    func stop() -> (Any?, String?) {
        answeredYes.removeAll()
        return jobs.stop(Self.jobID)
    }

    /// An ask on the secretary's card was answered on the board: let it act on the answer now
    /// (the hq hook hands it the answer at the start of the run). A run already going doesn't
    /// see it — the next one does, started as soon as that run ends. `toTodo`: the user took it
    /// as their own @me todo, so there is nothing for the secretary to do.
    func answered(askID: String, resolution: String, toTodo: Bool) {
        guard resolution == "do", !toTodo else { return }
        Task { @MainActor in
            if info["task"] == nil { _ = await refreshInfo() }
            guard let task = info["task"] as? String, askID.hasPrefix(task + ".") else { return }
            answeredYes.insert(askID)
            wakeWhenFree()
        }
    }

    /// The answer was undone (the board's Undo reopens the ask): don't wake up for it.
    func reopened(askID: String) {
        answeredYes.remove(askID)
    }

    /// One of its memory files (`<root>/secretary/*.md`): the board opens these for editing.
    func isMemoryFile(_ path: String) -> Bool {
        guard let memory = info["memory"] as? String, !memory.isEmpty else { return false }
        // Symlinks resolved on both sides: the check is about the file that gets opened.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let folder = URL(fileURLWithPath: memory).resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent().path
        // Its memory, or one of its reports (`secretary/reports/`).
        return url.pathExtension == "md"
            && (parent == folder.path || parent == folder.appending(path: "reports").path)
    }

    // MARK: - Internals

    /// A run is going, or was just launched and hasn't recorded its start yet.
    private var running: Bool {
        let runs = store.runs(Self.jobID)
        if let l = launched {
            // Its first record (a start, or a skip) is in, or the runner never got going.
            if runs.first?.id != l.after || Date().timeIntervalSince(l.at) > 60 { launched = nil } else { return true }
        }
        return runs.first(where: { $0.status != .skipped })?.status == .running
    }

    private func wakeWhenFree() {
        guard !waking else { return }
        waking = true
        Task { @MainActor in
            defer { waking = false }
            // Until every Yes is acted on: one arriving while this one starts gets its own run.
            while !answeredYes.isEmpty {
                try? await Task.sleep(for: Self.wakeGrace)
                while running { try? await Task.sleep(for: .seconds(3)) }
                guard !answeredYes.isEmpty else { return }
                answeredYes.removeAll()
                guard await prepare() == nil else { return }
                _ = start(L("I answered your proposals on the board. Carry out the ones I said yes to, then report in one line each.",
                            "我在看板上回应了你的建议：同意的照做，做完每条用一行汇报。"), trigger: "answer")
            }
        }
    }

    /// Everything a run needs: set up, a job, a session id bound to the secretary's card.
    private func prepare() async -> String? {
        if let err = await refreshInfo() { return err }
        guard info["ready"] as? Bool == true, let task = info["task"] as? String else {
            return L("The secretary isn't set up yet.", "秘书还没有设置好。")
        }
        // Set up by an older version: an agent definition it wrote and nobody edited is brought up
        // to date, and a memory file added since (reports.md) is made. Nothing the user wrote changes.
        let files = info["files"] as? [String: Bool] ?? [:]
        if info["agentStale"] as? Bool == true || files.values.contains(false), let hq {
            let r = await hq(["secretary", "init", "--json"])
            if let err = r.1 { return err }
            if let err = parseInfo(r.0) { return err }
        }
        if let err = await ensureJob() { return err }
        // The session's id is chosen before its first run, so the session is bound to the card
        // from its first prompt (the hq hooks then give it the card's rules).
        var sid = store.state(Self.jobID)["sessionId"] as? String ?? ""
        if sid.isEmpty {
            sid = UUID().uuidString.lowercased()
            store.setState(Self.jobID) { $0["sessionId"] = sid; $0[Jobs.preassignedKey] = true }
        }
        // hq's own record, not a cache: an `hq unbind` or a reset of its sessions is mended here.
        let bound = info["sessions"] as? [String] ?? []
        if !bound.contains(sid) {
            guard let hq else { return "no hq" }
            let r = await hq(["bind", task, "--session=\(sid)"])
            if let err = r.1 { return err }
        }
        return nil
    }

    private func start(_ prompt: String, trigger: String) -> (Any?, String?) {
        let file = store.folder(Self.jobID).appending(path: "prompt-\(UUID().uuidString.lowercased()).txt")
        do { try Data(prompt.utf8).write(to: file, options: .atomic) } catch {
            return (nil, error.localizedDescription)
        }
        let before = store.runs(Self.jobID).first?.id
        let r = jobs.runNow(Self.jobID, extra: ["--trigger", trigger, "--prompt-file", file.path])
        if r.1 != nil { try? FileManager.default.removeItem(at: file) } else { launched = (before, Date()) }
        return r
    }

    /// What a scheduled run asks: the report that is due (`hq report` picks daily or weekly). It
    /// names the steps itself: an agent definition the user edited keeps its old instructions.
    static var reportPrompt: String { L(reportPrompts[0], reportPrompts[1]) }
    private static let reportPrompts = [
        "Scheduled run: write the report that is due (Reports in your instructions): run `~/.claude/hq/bin/hq report`, write the report to the file it names, in the format of secretary/reports.md, run `~/.claude/hq/bin/hq report keep <that file name>`, then stop.",
        "定时运行：写今天该写的报告（照你说明里的 Reports 一节）：运行 `~/.claude/hq/bin/hq report`，按 secretary/reports.md 的格式把报告写进它给出的文件，再运行 `~/.claude/hq/bin/hq report keep <那个文件名>`，写完就停。"]
    static func writesReports(_ job: Job) -> Bool { reportPrompts.contains(job.prompt) }
    /// The schedule a job made before reports existed had, and the time reports run at instead.
    static let reportSchedule = Schedule(kind: .weekdays, hour: 18, minute: 30, cron: "30 18 * * 1-5")
    private static let oldPrompts: Set<String> = ["Look over the board: what needs my attention?", "看一眼看板：有什么需要我注意的？"]
    /// Made before reports: its prompt and schedule were placeholders nobody ran (it was off).
    private static func needsMigration(_ job: Job) -> Bool { !job.enabled && oldPrompts.contains(job.prompt) }
    /// The default 09:00 placeholder, or every N minutes (a report an hour is not a report), becomes
    /// the evening; a fixed time the user chose stays.
    private static func migratedSchedule(_ s: Schedule) -> Schedule {
        s == Schedule() || s.kind == .every ? reportSchedule : s
    }

    /// The job as the secretary needs it. The user may change its model, time limit, quota and
    /// compaction settings, its schedule or its prompt in Scheduled; what makes it the secretary
    /// (folder, agent, same session, allowed tools) is put back.
    private func ensureJob() async -> String? {
        guard let root = info["root"] as? String, !root.isEmpty else { return L("No HQ root", "找不到 HQ 根目录") }
        let tools = Self.allowedTools(root: root)
        var job = store.load(Self.jobID) ?? Job(
            id: Self.jobID, name: L("Secretary", "秘书"), kind: .claude, prompt: Self.reportPrompt,
            cwd: root, schedule: Self.reportSchedule, enabled: false, timeoutMinutes: 15, sessionMode: .resume,
            compactAbovePct: 50, notify: .failure, agent: "secretary", allowedTools: tools)
        let fresh = store.load(Self.jobID) == nil
        let old = Self.needsMigration(job)
        if !fresh, !old, job.directory == root, job.agent == "secretary", job.sessionMode == .resume,
           job.kind == .claude, job.allowedTools == tools { return nil }
        job.cwd = root; job.agent = "secretary"; job.sessionMode = .resume; job.kind = .claude
        job.allowedTools = tools
        if old {
            job.prompt = Self.reportPrompt
            job.schedule = Self.migratedSchedule(job.schedule)
        }
        return await save(job)
    }

    private func save(_ job: Job) async -> String? {
        guard let data = try? JSONEncoder().encode(job),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "encode" }
        return await jobs.save(raw).1
    }

    /// Without anyone there to approve a step, a run may only do what is allowed up front: read
    /// anything, run hq, and edit its own memory. Everything else is refused.
    static func allowedTools(root: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Read", "Grep", "Glob",
                "Bash(~/.claude/hq/bin/hq:*)", "Bash(\(home)/.claude/hq/bin/hq:*)",
                // `//` starts an absolute path in a permission rule.
                "Edit(/\(root)/secretary/**)", "Write(/\(root)/secretary/**)"]
    }

    private func refreshInfo() async -> String? {
        guard let hq else { return "no hq" }
        let r = await hq(["secretary", "--json"])
        if let err = r.1 { return err }
        return parseInfo(r.0)
    }

    private func parseInfo(_ out: String?) -> String? {
        guard let data = out?.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return L("hq said something odd", "hq 的输出读不懂") }
        info = o.filter { $0.key != "made" }
        return nil
    }
}
