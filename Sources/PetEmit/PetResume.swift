#if os(Windows)
import ClaudePetCore
import Foundation

/// Resume going back to a tab instead of opening another: BoardWindow's resumeInOrcaPlace and
/// resumeInIdleTab, as `pet-emit --board` ops over the same core (OrcaPlace, IdleTab), plus a
/// Windows Terminal tab the session ended in. board.js builds the line to type and opens a new
/// tab when these find nothing.
///
///   resume-orca        {session, title, line, focus}
///     → {reused: handle}                 typed into a tab, or a tab already running it brought forward
///     → {woke: true, watch: {worktree, tab, leaf}}   a sleeping tab's workspace was opened: board.js
///                                         then runs resume-orca-watch (Orca resumes it there itself)
///     → {none: true}                      no usable tab: open a new one
///   resume-orca-watch  {session, line, focus, worktree, tab, leaf}
///     → {reused: handle?}                 OrcaPlace.WakeWatch for up to 10 s
///   resume-wt          {session, line, focus}
///     → {reused: "wt:<shell pid>"} | {none: true}
///
/// An error means the board must not open another tab: the command may already be in one.
enum PetResume {
    static func handle(_ body: [String: Any]) -> (Any?, String?) {
        func str(_ key: String) -> String { body[key] as? String ?? "" }
        let session = str("session"), line = str("line"), focus = body["focus"] as? Bool ?? true
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        guard !line.isEmpty, !line.contains(where: { $0.isNewline }) else { return (nil, "bad command line") }
        switch body["op"] as? String ?? "" {
        case "resume-orca":
            return resume(session: session, title: str("title"), line: line, focus: focus)
        case "resume-orca-watch":
            let place = OrcaPlace.Place(worktreeID: str("worktree"), tabID: str("tab"), leafID: str("leaf"))
            guard !place.worktreeID.isEmpty, !place.tabID.isEmpty, !place.leafID.isEmpty else { return (nil, "bad place") }
            let watched = watch(session: session, woken: place, line: line, focus: focus)
            if let err = watched.error { return (nil, err) }
            return (watched.handle.map { ["reused": $0] } ?? [:], nil)
        case "resume-wt":
            return resumeWT(session: session, line: line, focus: focus)
        default:
            return (nil, L("unknown operation", "未知操作"))
        }
    }

    private static let shells: Set<String> = ["pwsh", "powershell", "cmd", "bash"]

    /// A Windows Terminal tab the session ended in: a shell straight under WindowsTerminal.exe
    /// (Git Bash's launcher bash.exe counts as its one inner bash), alone on its console, whose
    /// screen ends at a prompt under Claude Code's "claude --resume <id>" (IdleTab.endedHere).
    /// A Windows Terminal tab takes no input from outside, so the line goes into the shell's
    /// console input (WindowsJump.type), and the tab is selected as a jump selects it. The
    /// board's own tabs close with their session; this finds one you opened.
    private static func resumeWT(session: String, line: String, focus: Bool) -> (Any?, String?) {
        let all = ProcessProbe.snapshot()
        let hosts = Set(all.filter { $0.name.lowercased() == "windowsterminal" }.map(\.pid))
        guard !hosts.isEmpty else { return (["none": true], nil) }
        func children(_ pid: Int32) -> [ProcessProbe.Entry] { all.filter { $0.parent == pid } }
        for top in all where hosts.contains(top.parent) && shells.contains(top.name.lowercased()) {
            // Git\bin\bash.exe only starts Git\usr\bin\bash.exe and waits.
            var shell = top, launcher: Int32?
            let kids = children(top.pid)
            if top.name.lowercased() == "bash", kids.count == 1, kids[0].name.lowercased() == "bash" {
                shell = kids[0]; launcher = top.pid
            }
            guard children(shell.pid).isEmpty, let screen = WindowsJump.screen(of: shell.pid),
                  // Nothing else on the console: a program started in the background from there
                  // (`start /b`) is no child of the shell, but would get the keys too.
                  Set(screen.attached).isSubset(of: Set([shell.pid] + (launcher.map { [$0] } ?? []))),
                  IdleTab.endedHere(session: session, preview: screen.text) else { continue }
            let p = shell
            switch WindowsJump.type(into: p.pid, [(0, WindowsJump.keys(typing: line)), (0.1, [.enter])]) {
            case 0:
                // Its console was just read, so part of the line may be at the prompt.
                return (nil, L("Couldn't type the resume command into its Windows Terminal tab — check that tab before trying again",
                               "没能把续上的命令输进它的 Windows Terminal 标签页——先看看那个标签页再重试"))
            case 1:
                return (nil, L("Typed the resume command into its Windows Terminal tab but couldn't press Enter — press it there",
                               "已把续上的命令输进它的 Windows Terminal 标签页，但没能按回车——去那里按一下"))
            default:
                if focus { _ = WindowsJump.jumpConsole(pid: p.pid) }
                return (["reused": "wt:\(p.pid)"], nil)
            }
        }
        return (["none": true], nil)
    }

    /// BoardWindow's orcaTimeout / orcaSendTimeout: a hung Orca must not hold Resume up.
    private static let timeout: Double = 5
    private static let sendTimeout: Double = 10

    private static func resume(session: String, title: String, line: String, focus: Bool) -> (Any?, String?) {
        let none: (Any?, String?) = (["none": true], nil)
        guard WindowsJump.orcaCLI() != nil else { return none }   // not installed
        // Orca's place for the session: asleep after a restart, or left at a prompt by Stop.
        // Not answering is not "doesn't know it": right after a restart, when tabs sleep, Orca is
        // slow, and a new tab now would run the session twice once its tab wakes.
        guard let places = places(of: session) else {
            return (nil, L("Orca didn't answer where it has this session — try Resume again", "Orca 没回答这个 session 在哪——再点一次 Resume 试试"))
        }
        if !places.isEmpty {
            guard let terms = terminals() else {
                return (nil, L("Couldn't read Orca's terminals — try Resume again", "读不到 Orca 的终端列表——再点一次 Resume 试试"))
            }
            switch OrcaPlace.choose(places: places, terminals: terms, session: session, recorded: liveSessionsByHandle()) {
            case .bringForward(_, let handle)?:
                bringForward(handle, focus)
                return (["reused": handle], nil)
            case .type(_, let handle)?:
                if let err = type(line, into: handle) { return (nil, err) }
                bringForward(handle, focus)
                return (["reused": handle], nil)
            case .wake(let place)?:
                // Opening its workspace wakes the tab, and Orca resumes the session in it.
                guard let r = WindowsJump.orca(["worktree", "activate", "--worktree", OrcaPlace.worktreeSelector(place), "--json"],
                                               timeout: sendTimeout),
                      r.status == 0, TerminalTarget.orcaSwitchSucceeded(r.out) else {
                    return (nil, L("This session sleeps in an Orca tab the board can't wake — open its workspace in Orca and Orca resumes it there",
                                   "这个 session 在 Orca 一个休眠的标签页里，board 叫不醒——在 Orca 里打开它所在的工作区，Orca 会在原标签页里恢复它"))
                }
                return (["woke": true, "watch": ["worktree": place.worktreeID, "tab": place.tabID, "leaf": place.leafID]], nil)
            case nil:
                break   // every tab it is in runs something else
            }
        }
        guard let terms = terminals() else { return none }
        let live = liveSessionsByHandle()
        /// Typed into a tab found only by its looks: a refusal leaves the new tab to open, but a
        /// send that may have gone in must not — the session would run twice.
        func typeFound(_ handle: String) -> (Any?, String?) {
            switch send(line, into: handle) {
            case .typed:
                bringForward(handle, focus)
                return (["reused": handle], nil)
            case .refused: return none
            case .unsure: return (nil, unsureTyping)
            }
        }
        // The tab the session ended in (Stop, /exit), still at the prompt under Claude Code's
        // "claude --resume <id>" (IdleTab.endedHere). Orca's agentIdentity may still say claude.
        if let t = terms.first(where: {
            guard let h = $0["handle"] as? String, WindowsJump.isSafeToken(h), live[h] == nil,
                  $0["connected"] as? Bool == true, $0["writable"] as? Bool == true,
                  $0["orphaned"] as? Bool != true else { return false }
            return IdleTab.endedHere(session: session, preview: $0["preview"] as? String ?? "")
        }), let handle = t["handle"] as? String {
            return typeFound(handle)
        }
        // A tab with the session's title at a shell prompt, nobody in it.
        guard !title.isEmpty, let handle = IdleTab.orca(terminals: terms, title: title, occupied: Set(live.keys))
        else { return none }
        return typeFound(handle)
    }

    /// Polls the woken tab for up to 10 s: brought forward once it is live, and given the resume
    /// command if it stays at a bare prompt (OrcaPlace.WakeWatch).
    private static func watch(session: String, woken: OrcaPlace.Place, line: String, focus: Bool) -> (handle: String?, error: String?) {
        let places = places(of: session) ?? []
        let all = places.contains(woken) ? places : places + [woken]
        var w = OrcaPlace.WakeWatch()
        var seen: String?
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            guard let terms = terminals() else { continue }
            switch w.step(places: all, woken: woken, terminals: terms, session: session, recorded: liveSessionsByHandle()) {
            case .arrived(let h):
                if h != seen { bringForward(h, focus) }
                return (h, nil)
            case .type(let h):
                if h != seen { bringForward(h, focus) }
                return (h, type(line, into: h))   // once
            case .wait(let h?) where h != seen:
                seen = h
                bringForward(h, focus)
            case .wait:
                continue
            }
        }
        return (seen, nil)
    }

    /// The places Orca has the session in (`orca agent show`, by Claude Code's id then Orca's):
    /// empty when Orca doesn't know it (or is too old to say), nil when Orca didn't answer in time.
    private static func places(of session: String) -> [OrcaPlace.Place]? {
        func answer(_ args: [String]) -> String? {
            guard let r = WindowsJump.orca(args, timeout: timeout), !r.timedOut else { return nil }
            return r.out
        }
        guard let asked = answer(["agent", "show", session, "--json"]) else { return nil }
        guard let id = OrcaPlace.orcaSessionID(showOutput: asked), WindowsJump.isSafeToken(id) else { return [] }
        guard let shown = answer(["agent", "show", "orca_session_id:\(id)", "--json"]) else { return nil }
        return OrcaPlace.places(showOutput: shown)
    }

    private static func terminals() -> [[String: Any]]? {
        guard let r = WindowsJump.orca(["terminal", "list", "--json"], timeout: timeout), r.status == 0,
              let root = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] else { return nil }
        return (root["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
    }

    private enum Sent { case typed, refused, unsure }

    /// `orca terminal send`: `refused` only when Orca answered that it typed nothing (or never
    /// ran); `unsure` when it was ended at its timeout or said nothing readable — the line may
    /// be in.
    private static func send(_ line: String, into handle: String) -> Sent {
        guard WindowsJump.isSafeToken(handle),
              let r = WindowsJump.orca(["terminal", "send", "--terminal", handle, "--text", line, "--enter", "--json"],
                                       timeout: sendTimeout) else { return .refused }
        guard !r.timedOut, let root = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        else { return .unsure }
        return r.status == 0 && root["ok"] as? Bool == true ? .typed : .refused
    }

    private static var unsureTyping: String {
        L("Orca didn't confirm typing the resume command into the session's tab — check that tab before trying again",
          "Orca 没确认把续上的命令输进这个 session 的标签页——先看看那个标签页再重试")
    }

    /// Types the resume command into the session's own tab; an error unless Orca confirms it.
    private static func type(_ line: String, into handle: String) -> String? {
        send(line, into: handle) == .typed ? nil : unsureTyping
    }

    private static func bringForward(_ handle: String, _ focus: Bool) {
        guard focus, WindowsJump.isSafeToken(handle) else { return }
        _ = WindowsJump.orca(["terminal", "switch", "--terminal", handle, "--json"], timeout: timeout)
        _ = WindowsJump.raiseOrca()
    }

    /// BoardWindow.liveSessionsByHandle: which session the pet records live in each terminal.
    private static func liveSessionsByHandle() -> [String: String] {
        var out: [String: String] = [:]
        let dir = HookEmit.sessionsDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, ProcessProbe.isClaude(pid: pid),
                  obj["background"] as? Bool != true,
                  let handle = (obj["terminal"] as? [String: Any])?["handle"] as? String else { continue }
            out[handle] = (obj["sessionId"] as? String) ?? f.deletingPathExtension().lastPathComponent
        }
        return out
    }
}
#endif
