import ClaudePetCore
import Foundation

/// The secretary: the board's standing chat with an agent that knows the HQ board.
///
/// What it is made of, all reused:
/// - `hq secretary init` scaffolds the agent definition (`<root>/.claude/agents/secretary.md`), its
///   memory (`<root>/secretary/*.md`) and its own task card, whose asks are its proposals;
/// - a scheduled job, `secretary`, holds the session: Claude runs in the task root as
///   `--agent secretary`, the same session every run, compacted past a threshold and skipped
///   when the subscription's quota is nearly used up (see Jobs.swift). It is off schedule unless
///   the user turns one on; each message from the board is one run, its text the run's prompt;
/// - the session is bound to the secretary's card, so the hq hooks give it the card's rules, file
///   its `hq-asks` as asks in Needs you, and tell it the answers at its next turn;
/// - the board shows the conversation in Peek, by the session's id.
@MainActor
final class SecretaryController {
    static let shared = SecretaryController()

    static let jobID = "secretary"
    private var jobs: JobsController { JobsController.shared }
    private var store: JobStore { jobs.store }

    /// What hq last said about the secretary (`hq secretary --json`).
    private var info: [String: Any] = [:]
    /// An answer arrived while a run was going: run again once it ends.
    private var wakePending = false
    private var waking = false

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
        o["running"] = runs.first(where: { $0.status != .skipped })?.status == .running
        if let r = runs.first {
            // The last run when it went wrong, or was skipped (quota): the chat says why.
            o["last"] = ["status": r.status.rawValue, "summary": r.summary, "at": Jobs.iso(r.ended ?? r.started),
                         "failed": r.failed]
        }
        if let ctx = state["contextTokens"] as? Int, let window = state["contextWindow"] as? Int, window > 0 {
            o["contextPct"] = Int((Double(ctx) * 100 / Double(window)).rounded())
        }
        o["waking"] = wakePending
        return (o, nil)
    }

    /// Scaffolds what is missing and makes the job. `lang`: the board's language, for the memory
    /// files' and the card's wording.
    func setup(lang: String) async -> (Any?, String?) {
        guard let hq else { return (nil, "no hq") }
        let r = await hq(["secretary", "init", "--lang", lang == "zh" ? "zh" : "en", "--json"])
        if let err = r.1 { return (nil, err) }
        if let err = parseInfo(r.0) { return (nil, err) }
        if let err = await ensureJob() { return (nil, err) }
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

    func stop() -> (Any?, String?) {
        wakePending = false
        return jobs.stop(Self.jobID)
    }

    /// An ask on the secretary's card was answered on the board: let it act on the answer now
    /// (the hq hook hands it the answer at the start of the run). A run already going doesn't
    /// see it — the next one does, started as soon as that run ends.
    func answered(askID: String, resolution: String) {
        guard resolution == "do" else { return }
        Task { @MainActor in
            if info["task"] == nil { _ = await refreshInfo() }
            guard let task = info["task"] as? String, askID.hasPrefix(task + ".") else { return }
            wakePending = true
            wakeWhenFree()
        }
    }

    // MARK: - Internals

    private var running: Bool {
        store.runs(Self.jobID).first(where: { $0.status != .skipped })?.status == .running
    }

    private func wakeWhenFree() {
        guard !waking else { return }
        waking = true
        Task { @MainActor in
            defer { waking = false }
            // A few seconds' grace: answering several asks one after another makes one run.
            try? await Task.sleep(for: .seconds(3))
            while running { try? await Task.sleep(for: .seconds(3)) }
            guard wakePending else { return }
            wakePending = false
            guard await prepare() == nil else { return }
            _ = start(L("I answered your proposals on the board. Carry out the ones I said yes to, then report in one line each.",
                        "我在看板上回应了你的建议：同意的照做，做完每条用一行汇报。"), trigger: "answer")
        }
    }

    /// Everything a run needs: set up, a job, a session id bound to the secretary's card.
    private func prepare() async -> String? {
        if let err = await refreshInfo() { return err }
        guard info["ready"] as? Bool == true, let task = info["task"] as? String else {
            return L("The secretary isn't set up yet.", "秘书还没有设置好。")
        }
        if let err = await ensureJob() { return err }
        // The session's id is chosen before its first run, so the session is bound to the card
        // from its first prompt (the hq hooks then give it the card's rules).
        var sid = store.state(Self.jobID)["sessionId"] as? String ?? ""
        if sid.isEmpty {
            sid = UUID().uuidString.lowercased()
            store.setState(Self.jobID) { $0["sessionId"] = sid; $0.removeValue(forKey: "boundTask") }
        }
        if store.state(Self.jobID)["boundTask"] as? String != "\(task) \(sid)" {
            guard let hq else { return "no hq" }
            let r = await hq(["bind", task, "--session=\(sid)"])
            if let err = r.1 { return err }
            store.setState(Self.jobID) { $0["boundTask"] = "\(task) \(sid)" }
        }
        return nil
    }

    private func start(_ prompt: String, trigger: String) -> (Any?, String?) {
        let file = store.folder(Self.jobID).appending(path: "prompt-\(UUID().uuidString.lowercased()).txt")
        do { try Data(prompt.utf8).write(to: file, options: .atomic) } catch {
            return (nil, error.localizedDescription)
        }
        let r = jobs.runNow(Self.jobID, extra: ["--trigger", trigger, "--prompt-file", file.path])
        if r.1 != nil { try? FileManager.default.removeItem(at: file) }
        return r
    }

    /// The job as the secretary needs it. The user may change its model, time limit, quota and
    /// compaction settings, or give it a schedule, in Scheduled; what makes it the secretary
    /// (folder, agent, same session, allowed tools) is put back.
    private func ensureJob() async -> String? {
        guard let root = info["root"] as? String, !root.isEmpty else { return L("No HQ root", "找不到 HQ 根目录") }
        let tools = Self.allowedTools(root: root)
        var job = store.load(Self.jobID) ?? Job(
            id: Self.jobID, name: L("Secretary", "秘书"), kind: .claude,
            prompt: L("Look over the board: what needs my attention?", "看一眼看板：有什么需要我注意的？"),
            cwd: root, enabled: false, timeoutMinutes: 15, sessionMode: .resume, compactAbovePct: 50,
            notify: .failure, agent: "secretary", allowedTools: tools)
        let fresh = store.load(Self.jobID) == nil
        if !fresh, job.directory == root, job.agent == "secretary", job.sessionMode == .resume,
           job.kind == .claude, job.allowedTools == tools { return nil }
        job.cwd = root; job.agent = "secretary"; job.sessionMode = .resume; job.kind = .claude
        job.allowedTools = tools
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
