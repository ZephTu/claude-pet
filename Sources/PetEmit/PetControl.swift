#if os(Windows)
import ClaudePetCore
import Foundation

/// The HQ board typing into a session's terminal on Windows: BoardBridge's send, interrupt,
/// approvePlan and stopSession on the Mac, as `pet-emit --board` ops (PetBoard hands them here).
///
/// Orca takes text and keys through its CLI (`orca terminal send`), as on the Mac. A Windows
/// Terminal tab or a console window takes no input from outside, so for those the keys are
/// written into the session's console input (WindowsJump.type), where Claude Code reads them as
/// if typed. Every op first checks that the process the pet recorded is still that session: an
/// Enter or a message typed into a tab whose session has ended goes to the shell.
/// A background session (`bg`) has no terminal: board.js continues it with `claude --bg --resume`.
enum PetControl {
    static func handle(_ body: [String: Any]) -> (Any?, String?) {
        func str(_ key: String) -> String { body[key] as? String ?? "" }
        switch body["op"] as? String ?? "" {
        case "send":
            return send(session: str("session"), text: str("text"), queue: body["queue"] as? Bool ?? false,
                        outbox: body["outbox"] as? Bool ?? false)
        case "interrupt": return interrupt(session: str("session"), bg: str("bg"))
        case "plan-approve": return approvePlan(session: str("session"), ask: str("ask"), bg: str("bg"))
        case "stop-session": return stopSession(str("session"))
        default: return (nil, L("unknown operation", "未知操作"))
        }
    }

    // MARK: - The pet's record

    private struct Terminal { let kind: String; let handle: String }

    private static func record(_ session: String) -> (state: SessionState, raw: [String: Any])? {
        guard WindowsJump.isSafeToken(session),
              let data = try? Data(contentsOf: HookEmit.sessionsDirectory.appending(path: session + ".json")),
              let state = SessionState.decode(from: data),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (state, raw)
    }

    /// `bg`: the board has it as a background session, so it is in no terminal, whatever its
    /// record says.
    private static func terminal(of session: String, bg: String = "") -> Terminal? {
        guard bg.isEmpty, let raw = record(session)?.raw,
              raw["background"] as? Bool != true,
              let t = raw["terminal"] as? [String: Any],
              let kind = t["kind"] as? String, let handle = t["handle"] as? String else { return nil }
        return Terminal(kind: kind, handle: handle)
    }

    /// The Claude Code process the pet recorded, while it is still this session: Claude Code,
    /// started before the session's last hook (a pid since reused is younger), and on this
    /// session by Claude Code's own file for the pid (which follows /clear).
    private static func sessionRunning(_ session: String) -> Int32? {
        guard let state = record(session)?.state, let pid = state.pid, pid > 1, ProcessProbe.isClaude(pid: pid),
              (ProcessProbe.startTime(pid: pid) ?? .distantFuture) <= state.updatedAt,
              SessionControl.processIsSession(session, sessionsFile: claudeSessionFile(pid), arguments: nil)
        else { return nil }
        return pid
    }

    private static func claudeSessionFile(_ pid: Int32) -> Data? {
        try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions/\(pid).json"))
    }

    /// BoardWindow.currentState: a wait since approved or closed counts as what it became.
    private static func currentState(_ session: String) -> SessionActivity? {
        guard let s = record(session)?.state else { return nil }
        if StateAggregator.wasApproved(s) { return .busy }
        return (StateAggregator.waitEnded(s) ?? s).state
    }

    private static func lastPromptAt(_ session: String) -> String {
        record(session)?.raw["lastPromptAt"] as? String ?? ""
    }

    /// Like Orca's --wait-submit: watches up to 5 s for the session to take a new prompt.
    private static func turnStarted(_ session: String, since before: String) -> Bool {
        for _ in 0..<25 {
            if lastPromptAt(session) != before { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    // MARK: - Ops

    /// BoardBridge.send for a terminal session. `queue`: it is busy, so the message waits in
    /// Claude Code's queue and no turn will start soon. `outbox`: the board's send queue asks, and
    /// must tell "not sent" (an error) from "typed, but no turn seen" (`unsure`).
    private static func send(session: String, text: String, queue: Bool, outbox: Bool) -> (Any?, String?) {
        func unsure(_ msg: String) -> (Any?, String?) { outbox ? (["ok": false, "unsure": true, "error": msg], nil) : (nil, msg) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, L("empty message", "消息是空的")) }
        if BoardSend.opensMenu(text) {
            return (nil, L("give it a model: /model opus, /model sonnet, … — alone it opens a menu in the terminal",
                           "要带上模型名：/model opus、/model sonnet……——不带参数会在终端里打开一个菜单"))
        }
        guard let t = terminal(of: session) else {
            return (nil, L("no terminal recorded for this session", "没有记录这个 session 的终端"))
        }
        // Typing into a tab whose session has ended would hand the message to the shell.
        let pid = sessionRunning(session)
        if pid == nil, record(session)?.state.pid != nil || t.kind != "orca" {
            return (nil, L("that session is not running any more — Resume it first", "这个 session 已经不在运行了 — 先 Resume 它"))
        }
        // On a permission prompt or a question menu the Return would pick the highlighted option.
        if BoardSend.refuses(state: currentState(session)) {
            return (nil, L("it is waiting on a prompt in its terminal — answer it there (Jump) first",
                           "它在终端里等你确认或回答 — 先去那里（跳转）处理"))
        }
        switch t.kind {
        case "orca":
            guard WindowsJump.isSafeToken(t.handle) else { return (nil, L("unexpected Orca terminal handle", "Orca 终端 handle 不对劲")) }
            guard let r = WindowsJump.orca(["terminal", "send", "--terminal", t.handle, "--text", text, "--enter", "--json"]
                                           + (queue ? [] : ["--wait-submit", "5"])) else {
                return (nil, L("Orca is not installed", "没有安装 Orca"))
            }
            // Ended at its timeout: it may have typed the message already.
            if r.timedOut {
                return unsure(L("Orca didn't answer — check its terminal before sending again", "Orca 没有回应 — 再发之前先去它的终端看看"))
            }
            if r.status == 0 {
                if outbox, !queue, BoardSend.orcaTurnUnproven(r.out) {
                    if currentState(session) == .busy { return (["ok": true, "queued": true], nil) }
                    return unsure(L("typed into its Orca terminal, but no turn started — check it and press Return there",
                                    "已经输入到它的 Orca 终端，但没有开始新一轮 — 去那里看看，在那里按回车"))
                }
                return (["ok": true, "queued": queue, "detail": r.out], nil)
            }
            let msg = "orca: \(r.err.isEmpty ? r.out : r.err)".prefix(300).description
            return (r.err + r.out).contains("retry-request") ? unsure(msg) : (nil, msg)
        case "wt", "console":
            guard let pid else { return (nil, L("that session is not running any more — Resume it first", "这个 session 已经不在运行了 — 先 Resume 它")) }
            // One line with no control characters (BoardSend.typeable); a tab too, which typed
            // as a key would ask Claude Code to complete.
            let typed = BoardSend.typeable(text).replacingOccurrences(of: "\t", with: " ")
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, L("empty message", "消息是空的")) }
            let before = lastPromptAt(session)
            // The text as one bracketed paste (as the Mac types it): however it is split into reads,
            // Claude Code takes it as text, with no `@` or `/` suggestion menu for the Return to
            // pick from. ESC is in the markers only: typeable took it out of the text. The Return
            // on its own, once Claude Code has taken the text in (BoardSend.returnDelay).
            let pasted = WindowsJump.keys(typing: "\u{1B}[200~" + typed + "\u{1B}[201~")
            let went = WindowsJump.type(into: pid, [(0, pasted), (BoardSend.returnDelay(characters: typed.count), [.enter])])
            if went == 0 {
                return (nil, L("couldn't type into its terminal — Jump and send it there", "没法输入到它的终端 — 跳过去在那里发"))
            }
            // The text went in but its Return did not: sending again would type it twice.
            if went == 1 {
                return unsure(L("typed into its terminal, but couldn't press Return — check it and press Return there",
                                "已经输入到它的终端，但没能按回车 — 去那里看看，在那里按回车"))
            }
            if queue { return (["ok": true, "queued": true], nil) }
            if !BoardSend.startsTurn(typed) { return (["ok": true], nil) }
            if turnStarted(session, since: before) { return (["ok": true], nil) }
            if currentState(session) == .busy { return (["ok": true, "queued": true], nil) }
            return unsure(L("typed into its terminal, but no turn started — check it and press Return there",
                            "已经输入到它的终端，但没有开始新一轮 — 去那里看看，在那里按回车"))
        default:
            return (nil, L("sending to \(t.kind) terminals is not supported yet — use Jump", "还不支持给 \(t.kind) 终端发消息 — 请用跳转"))
        }
    }

    /// Esc in the session's terminal, only while it is mid-turn (BoardSend.mayInterrupt).
    private static func interrupt(session: String, bg: String) -> (Any?, String?) {
        guard let t = terminal(of: session, bg: bg) else {
            return (nil, L("no terminal recorded for this session", "没有记录这个 session 的终端"))
        }
        guard let pid = sessionRunning(session) else { return (nil, L("that session is not running any more", "这个 session 已经不在运行了")) }
        let quiet = record(session).map { StateAggregator.isQuiet($0.state, now: Date()) } ?? false
        guard BoardSend.mayInterrupt(state: currentState(session),
                                     claudeStatus: ClaudeSessionStatus.read(pid: pid, sessionId: session)?.status,
                                     quiet: quiet) else {
            return (nil, L("it is not in a turn — nothing to interrupt", "它不在一轮里——没有可中断的"))
        }
        return press(.escape, in: t, pid: pid) ?? (nil, L("interrupting a session in \(t.kind) is not supported — Jump and press Esc there",
                                                          "还不支持中断 \(t.kind) 里的 session——跳过去在那里按 Esc"))
    }

    /// Enter in the session's terminal: the plan dialog's first option. A hook can't approve a
    /// plan (Claude Code ignores "allow" for ExitPlanMode). board.js keeps it to one Enter per plan.
    private static func approvePlan(session: String, ask: String, bg: String) -> (Any?, String?) {
        guard !ask.isEmpty, let s = record(session)?.state, s.askAnswerable(now: Date()), s.askId == ask, s.askKind == "plan" else {
            return (nil, L("that plan is no longer waiting here — look in its terminal", "这个计划已经不在这里等了 — 去它的终端里看看"))
        }
        guard let t = terminal(of: session, bg: bg) else {
            return (nil, L("no terminal to press Enter in — Attach and approve it there", "没有可以按回车的终端 — 用 Attach 打开后在那里批准"))
        }
        guard let pid = sessionRunning(session) else { return (nil, L("that session is not running any more", "这个 session 已经不在运行了")) }
        return press(.enter, in: t, pid: pid) ?? (nil, L("approving in \(t.kind) is not supported — Jump and approve it there",
                                                         "还不支持在 \(t.kind) 里批准——跳过去在那里批准"))
    }

    /// One key in the terminal; nil for a terminal that can't take one.
    private static func press(_ key: BoardPrompt.Key, in t: Terminal, pid: Int32) -> (Any?, String?)? {
        switch t.kind {
        case "orca":
            guard WindowsJump.isSafeToken(t.handle) else { return (nil, L("unexpected Orca terminal handle", "Orca 终端 handle 不对劲")) }
            guard let r = WindowsJump.orca(["terminal", "send", "--terminal", t.handle, "--text", key.text, "--json"]) else {
                return (nil, L("Orca is not installed", "没有安装 Orca"))
            }
            if r.timedOut { return (nil, L("Orca didn't answer — look in its terminal", "Orca 没有回应 — 去它的终端看看")) }
            return r.status == 0 ? (["ok": true], nil) : (nil, "orca: \(r.err.isEmpty ? r.out : r.err)".prefix(300).description)
        case "wt", "console":
            let k: WindowsJump.Key = key == .enter ? .enter : .escape
            return WindowsJump.type(into: pid, [(0, [k])]) > 0 ? (["ok": true], nil)
                : (nil, L("couldn't reach its terminal — Jump and do it there", "连不上它的终端 — 跳过去在那里操作"))
        default:
            return nil
        }
    }

    /// Ends a terminal session's Claude Code process, as Ctrl+C twice in its tab would (the Mac
    /// sends SIGTERM; Windows has none to send to a console program). The conversation is kept
    /// and Resume picks it up; a tab the board opened closes with it.
    private static func stopSession(_ session: String) -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        guard let state = record(session)?.state, let pid = state.pid, pid > 1 else {
            return (nil, L("no process recorded for this session", "没有记录这个 session 的进程"))
        }
        // Already ended: stopped is what was asked for.
        guard ProcessProbe.isClaude(pid: pid) else { return (["ok": true, "gone": true], nil) }
        guard sessionRunning(session) == pid else {
            return (nil, L("that process is on another session now — stop it in its terminal", "这个进程现在已经是另一个 session 了 — 请在它的终端里停掉"))
        }
        // Mid-turn the first Ctrl+C only interrupts the turn: a second round then quits.
        // A console that can't be reached may only mean the process has just ended.
        for _ in 0..<2 {
            if !ProcessProbe.isClaude(pid: pid) { return (["ok": true, "pid": Int(pid)], nil) }
            guard WindowsJump.type(into: pid, [(0, [.ctrlC]), (0.3, [.ctrlC])]) > 0 else {
                if !ProcessProbe.isClaude(pid: pid) { return (["ok": true, "pid": Int(pid)], nil) }
                return (nil, L("couldn't reach its terminal — close it there", "连不上它的终端 — 请在那里关掉"))
            }
            for _ in 0..<30 {
                if !ProcessProbe.isClaude(pid: pid) { return (["ok": true, "pid": Int(pid)], nil) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return (nil, L("it did not stop — close it in its terminal", "它没有停下 — 请在它的终端里关掉"))
    }
}
#endif
