import AppKit
import ClaudePetCore
import WebKit

/// The HQ task board: tasks, the asks ledger, and live sessions in one window.
///
/// Unlike the pet's own panel this is an ordinary window that takes the
/// keyboard — the board is for typing notes and messages, so it must be key.
/// Everything it shows and changes goes through the `hq` CLI (see hq/README.md);
/// this file only renders a page and relays a short, fixed list of operations.
/// No task logic lives in Swift.
@MainActor
final class BoardWindow: NSWindow {
    private let webView: WKWebView
    /// Retained for as long as the web view: WKWebView does not own it.
    private let scheme: PetSchemeHandler?
    private let bridge = BoardBridge()

    init() {
        let config = WKWebViewConfiguration()
        scheme = Bundle.module.url(forResource: "pet", withExtension: nil)
            .map { PetSchemeHandler(root: $0) }
        if let scheme {
            config.setURLSchemeHandler(scheme, forURLScheme: PetSchemeHandler.scheme)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760), configuration: config)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        // A real title bar, painted the board's colour, is what the window is
        // dragged by. The page must not extend under it: WKWebView swallows
        // every mouse event, and `-webkit-app-region` is Electron-only — with
        // the content under the bar the window could not be moved at all.
        title = "HQ"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(calibratedRed: 0.137, green: 0.125, blue: 0.114, alpha: 1)
        isReleasedWhenClosed = false
        minSize = NSSize(width: 760, height: 480)
        contentView = webView
        // See PetPanel: handlers go on the view's live configuration copy.
        webView.configuration.userContentController.addScriptMessageHandler(
            bridge, contentWorld: .page, name: "hq")
        center()
        setFrameAutosaveName("HQBoard")
        if let url = PetSchemeHandler.url(path: "board/board.html") {
            webView.load(URLRequest(url: url))
        } else {
            NSLog("ClaudePet: board resources missing from bundle")
        }
    }

    /// Brings the board forward and gives it the keyboard. The pet is an
    /// accessory app, so it has to activate itself for the window to be key.
    func present(reveal task: String = "") {
        // Activation is only a request on macOS 14+, and an accessory app
        // asking from a menu or a click on a non-activating panel is often
        // refused — the window then opened *behind* the frontmost app, which
        // looked like the first "Task Board…" doing nothing. Order it front
        // regardless, then ask for the keyboard.
        NSApp.activate()
        orderFrontRegardless()
        makeKey()
        if task.isEmpty {
            webView.evaluateJavaScript("window.hqRefresh && window.hqRefresh();")
        } else if task == "jobs" {
            webView.evaluateJavaScript("window.hqShowJobs && window.hqShowJobs();")
        } else {
            // Ids look like T-123; anything else is not passed into the page.
            let safe = task.range(of: #"^T-\d+$"#, options: .regularExpression) != nil ? task : ""
            webView.evaluateJavaScript("window.hqReveal && window.hqReveal('\(safe)');")
        }
    }

    /// The pet has no main menu (it is an accessory app), so the standard
    /// editing shortcuts have no menu item to fire. Route them by hand, or
    /// copy and paste simply do nothing in the board.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: String?
        if flags == .command {
            action = ["c": "copy:", "v": "paste:", "x": "cut:", "a": "selectAll:", "z": "undo:"][key]
        } else if flags == [.command, .shift], key == "z" {
            action = "redo:"
        }
        if let action, NSApp.sendAction(Selector(action), to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Renders the live board to a PNG — the development check for layout,
    /// since screen capture needs a permission this app should not ask for.
    /// Waits for the page to load real data through hq, runs an optional
    /// script (expand a task, open a peek), then snapshots.
    func renderPreview(to path: String, script: String, done: @escaping @MainActor (Bool) -> Void) {
        setFrameOrigin(NSPoint(x: 40, y: 40))
        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            webView.evaluateJavaScript(script.isEmpty ? "null" : script) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    webView.takeSnapshot(with: nil) { image, _ in
                        MainActor.assumeIsolated {
                            guard let tiff = image?.tiffRepresentation,
                                  let rep = NSBitmapImageRep(data: tiff),
                                  let png = rep.representation(using: .png, properties: [:])
                            else { return done(false) }
                            done((try? png.write(to: URL(fileURLWithPath: path))) != nil)
                        }
                    }
                }
            }
        }
    }
}

/// Relays the page's requests to `hq` and to the terminals. Every operation is
/// on a fixed list and every argument is passed as a separate argv entry, so
/// nothing the page sends is ever interpreted by a shell.
@MainActor
final class BoardBridge: NSObject, WKScriptMessageHandlerWithReply {
    private static let orcaBundleID = "com.stablyai.orca"
    /// The pet's unread finishes per session, and how the board marks one session's read.
    /// Set by the app; nil when the board is rendered on its own (`--render-board`).
    static var unreadBySession: (() -> [String: Int])?
    /// What the pet's list draws each session's dot from — the board draws the same dot.
    static var petDots: (() -> [String: [String: Any]])?
    static var onSeen: ((String) -> Void)?
    /// Answers a session's permission prompt the way the pet's Allow / Deny does — see
    /// PermissionDecision. The askId comes from the pet's own dots, so a click can only answer the
    /// prompt that was on screen; one that has since gone away approves nothing.
    static var onDecide: ((String, String, PermissionDecision.Behavior) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let body = message.body as? [String: Any] ?? [:]
        func str(_ key: String) -> String { body[key] as? String ?? "" }

        switch body["op"] as? String ?? "" {
        case "board": return await hq(["board", "--json"])
        case "sessions": return await hq(["sessions", "--json"])
        case "peek":
            // An open conversation shows the newest reply: that is reading it.
            let r = await hq(["peek", str("session"), "-n", "30", "--json", "--meta"])
            if r.1 == nil { Self.onSeen?(str("session")) }
            return r
        case "pet":
            var pet: [String: Any] = ["unread": Self.unreadBySession?() ?? [:], "dots": Self.petDots?() ?? [:]]
            if let usage = Self.usage?() { pet["usage"] = usage }
            let data = (try? JSONSerialization.data(withJSONObject: pet, options: [.sortedKeys])) ?? Data("{}".utf8)
            return (String(decoding: data, as: UTF8.self), nil)
        case "resolve":
            return await hq(["ask", "resolve", str("id"), str("resolution"),
                             "--via", "board", "--note=\(str("note"))"])
        case "reopen": return await hq(["ask", "reopen", str("id"), "--via=board"])
        case "snooze":
            // "Later": the ask stays open, out of sight until tomorrow (or `until`; "" brings it back).
            let until = body["until"] as? String
            return await hq(["ask", "snooze", str("id"), "--via=board"] + (until.map { ["--until=\($0)"] } ?? []))
        case "delivered":
            return await hq(["ask", "delivered", str("id"), "--session=\(str("session"))"] + (body["undo"] as? Bool == true ? ["--undo"] : []))
        case "todo":
            let index = (body["index"] as? Int).map(String.init) ?? str("index")
            // The text guards against the card having changed since the board read it.
            let text = str("text").isEmpty ? [] : ["--text=\(str("text"))"]
            return await hq(["todo", str("task"), index, str("state"), "--via=board"] + text)
        case "set":
            let fields = (body["fields"] as? [String]) ?? []
            guard !fields.isEmpty else { return (nil, "no fields") }
            return await hq(["set", str("task")] + fields)
        case "log": return await hq(["log", str("task"), "--", str("message")])
        case "focus":
            return await hq(["focus", str("action")] + ((body["tasks"] as? [String]) ?? []) + ["--json"])
        case "scan": return await hq(["scan", "--json"])
        case "scan-apply":
            let only = ((body["names"] as? [String]) ?? []).joined(separator: ",")
            guard !only.isEmpty else { return (nil, "nothing selected") }
            return await hq(["scan", "--apply-projects", "--only=\(only)"])
        case "project":
            let action = str("action")
            var args = ["project", action] + ((body["names"] as? [String]) ?? [])
            if action == "add" { for p in (body["paths"] as? [String]) ?? [] { args.append("--path=\(p)") } }
            if let to = body["to"] as? String { args.append("--to=\(to)") }
            return await hq(args)
        case "category":
            var args = ["category", str("action")] + ((body["names"] as? [String]) ?? [])
            if let to = body["to"] as? String { args.append("--to=\(to)") }
            return await hq(args)
        case "ref": return await hq(["ref", str("action"), str("task"), "--", str("ref")])
        case "addtodo": return await hq(["addtodo", str("task"), "--", str("text")])
        case "bind": return await hq(["bind", str("task"), "--session=\(str("session"))"])
        case "unbind": return await hq(["unbind", "--session=\(str("session"))"])
        case "new":
            // No category picked: let hq choose its default rather than inventing one.
            var args = ["new"]
            if !str("category").isEmpty { args.append("--category=\(str("category"))") }
            if !str("workdir").isEmpty { args.append("--workdir=\(str("workdir"))") }
            if !str("project").isEmpty { args.append("--project=\(str("project"))") }
            return await hq(args + ["--", str("title")])
        case "send":
            let r = await send(session: str("session"), text: str("text"), queue: body["queue"] as? Bool ?? false,
                               bg: str("bg"), skip: body["skip"] as? Bool ?? false)
            if r.1 == nil { Self.onSeen?(str("session")) }   // replying means you read it
            return r
        case "saveImage": return saveImage(dataURL: str("data"))
        case "launch":
            return await launch(task: str("task"), title: str("title"), dir: str("dir"),
                                place: str("where"), prompt: str("prompt"), skip: body["skip"] as? Bool ?? false,
                                focus: body["focus"] as? Bool ?? true)
        case "history": return await hq(["history", str("task"), "--json"])
        case "resume":
            return await resume(task: str("task"), session: str("session"), dir: str("dir"),
                                place: str("where"), skip: body["skip"] as? Bool ?? false, name: str("name"),
                                focus: body["focus"] as? Bool ?? true)
        case "attach": return await openInTerminal(place: str("where"), dir: NSHomeDirectory(),
                                                    command: [await claudePath() ?? "claude", "attach", str("session")],
                                                    title: "attach " + str("session").prefix(8))
        case "stop":
            guard let claude = await claudePath() else { return (nil, "can't find the claude command") }
            let r = await Self.run(claude, ["stop", str("session")])
            return r.status == 0 ? (["ok": true], nil) : (nil, r.err.isEmpty ? r.out : r.err)
        case "stop-session": return await stopSession(str("session"))
        case "agents":
            // Background sessions have no terminal, so the pet's records can't say what they are;
            // `claude agents --json` can.
            guard let claude = await claudePath() else { return ("[]", nil) }
            let r = await Self.run(claude, ["agents", "--json"])
            return (r.status == 0 ? r.out : "[]", nil)
        case "decide":
            guard let behavior = PermissionDecision.Behavior(rawValue: str("behavior")),
                  !str("session").isEmpty, !str("ask").isEmpty else { return (nil, "bad decision") }
            guard let decide = Self.onDecide else { return (nil, "answer it in the terminal") }
            // The prompt the click was for must still be the one the pet can answer: a hold that
            // ended, or a prompt replaced since the board drew it, approves nothing.
            guard (Self.petDots?()[str("session")]?["askId"] as? String) == str("ask") else {
                return (nil, "that prompt is no longer waiting here — answer it in the terminal")
            }
            decide(str("session"), str("ask"), behavior)
            return (["ok": true], nil)
        case "jump":
            guard let t = terminal(of: str("session")) else { return (nil, "no terminal recorded for this session") }
            TerminalJump.jump(kind: t.kind, handle: t.handle)
            Self.onSeen?(str("session"))
            return (["ok": true], nil)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str("text"), forType: .string)
            return (["ok": true], nil)
        case "openURL":
            guard let url = URL(string: str("url")),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
            else { return (nil, "only web links can be opened") }
            NSWorkspace.shared.open(url)
            return (["ok": true], nil)
        case "openPath": return openPath(str("path"), cwd: str("cwd"))

        // Scheduled jobs — see JobsController.
        case "jobs": return (JobsController.shared.list(), nil)
        case "job-save": return await JobsController.shared.save(body["job"] as? [String: Any] ?? [:])
        case "job-enable": return await JobsController.shared.setEnabled(str("id"), body["on"] as? Bool ?? false)
        case "job-delete": return await JobsController.shared.delete(str("id"))
        case "job-run": return JobsController.shared.runNow(str("id"))
        case "job-stop": return JobsController.shared.stop(str("id"))
        case "job-preview": return (JobsController.shared.preview(body["schedule"] as? [String: Any] ?? [:]), nil)
        case "job-detail": return JobsController.shared.detail(str("id"), run: str("run"))
        case "job-seen":
            JobsController.shared.markSeen()
            return (["ok": true], nil)
        case "job-resume": return await resumeJob(id: str("id"), session: str("session"), place: str("where"),
                                                  skip: body["skip"] as? Bool ?? false, focus: body["focus"] as? Bool ?? true)
        case "pick-folder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if !str("path").isEmpty { panel.directoryURL = URL(fileURLWithPath: (str("path") as NSString).expandingTildeInPath) }
            guard panel.runModal() == .OK, let url = panel.url else { return (["path": ""], nil) }
            let home = NSHomeDirectory()
            return (["path": url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path], nil)
        case "open":
            let path = str("path")
            guard path.hasSuffix("/TASK.md"), FileManager.default.fileExists(atPath: path) else {
                return (nil, "not a task card")
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return (["ok": true], nil)
        default:
            return (nil, "unknown operation")
        }
    }

    // MARK: - Images

    /// An image pasted or dropped into a message box, saved as a file so its path can go into the
    /// message — Claude Code reads an image from a path in the prompt.
    private func saveImage(dataURL: String) -> (Any?, String?) {
        let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return (nil, "not an image") }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]   // image/png;base64
        let mime = String(header.split(separator: ";").first ?? "")
        guard header.hasSuffix(";base64"), let ext = types[mime] else { return (nil, "unsupported image type \(mime)") }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return (nil, "bad image data") }
        guard data.count <= 20 * 1024 * 1024 else { return (nil, "image is larger than 20 MB") }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/hq/attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(fmt.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        let url = dir.appending(path: name)
        do { try data.write(to: url) } catch { return (nil, "could not save the image: \(error.localizedDescription)") }
        return (["path": url.path], nil)
    }

    // MARK: - New sessions

    /// The claude CLI. The pet runs outside any shell, so PATH doesn't know about it: look in the
    /// usual install places, then ask a login shell once.
    private var cachedClaude: String??
    private func claudePath() async -> String? {
        if let c = cachedClaude { return c }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Off the main thread: a slow shell profile must not freeze the pet.
            let r = await Self.run("/bin/zsh", ["-lic", "command -v claude"])
            let path = r.out.split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { found = path }
        }
        cachedClaude = .some(found)
        return found
    }

    /// Single-quoted for a POSIX shell: nothing inside is interpreted.
    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Starts a Claude Code session for a task: binds a fresh session id to the task first (so the
    /// session starts with the task's rules), then runs `claude --session-id … --name … <prompt>`
    /// in the task's directory — in a new terminal tab, or in the background with `--bg`.
    /// The quota reading the pet uses (5-hour and weekly: percent used, when each resets), from the
    /// app; nil when there is no fresh one — see AppMain.currentUsage.
    static var usage: (() -> [String: Any]?)?

    /// The user's choice on the board: sessions it starts or resumes skip Claude Code's permission prompts.
    private static let skipFlag = "--dangerously-skip-permissions"

    /// Picks up an earlier session of a task where it left off: `claude --resume <id>` in the
    /// directory it ran in (Claude Code keeps a conversation under that directory), bound to the
    /// task again. A background place opens a terminal instead — there is nothing to attach to.
    private func resume(task: String, session: String, dir rawDir: String, place: String, skip: Bool,
                        name: String = "", focus: Bool = true) async -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, "not a session id") }
        let dir = (rawDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (nil, "no such directory: \(dir)")
        }
        guard let claude = await claudePath() else { return (nil, "can't find the claude command") }
        let bound = await hq(["bind", task, "--session=\(session)"])
        if let err = bound.1 { return (nil, err) }
        let into = place == "bg" ? "terminal" : place
        let cmd = [claude, "--resume", session] + (skip ? [Self.skipFlag] : [])
        // The tab keeps the session's own name, as the pet and the board show it.
        let title = name.isEmpty ? "\(task) \(session.prefix(8))" : String(name.prefix(60))
        // A tab this session ran in before — kept by Orca or Terminal across a restart, or left
        // behind by Stop — is reused rather than opening a second one beside it.
        if let reused = await resumeInIdleTab(place: into, title: title, dir: dir, command: cmd, focus: focus) {
            return (["ok": true, "session": session, "where": into, "reused": reused], nil)
        }
        let opened = await openInTerminal(place: into, dir: dir, command: cmd, title: title, focus: focus)
        return opened.1 == nil ? (["ok": true, "session": session, "where": into], nil) : opened
    }

    /// The shell line that runs `command` in `dir`, as `openInTerminal` types it.
    private static func shellLine(dir: String, command: [String]) -> String {
        var line = "cd \(shq(dir)) && "
        // A board started with HQ_ROOT (tests, a second root) passes it on to the new session.
        if let root = ProcessInfo.processInfo.environment["HQ_ROOT"] { line += "HQ_ROOT=\(shq(root)) " }
        return line + command.map(shq).joined(separator: " ")
    }

    /// Types `command` into a tab titled `title` that sits at a shell prompt with no Claude Code
    /// session in it, and brings it forward. Returns the tab's handle, or nil when there is no
    /// such tab (then the caller opens a new one). Only Orca and Terminal.app can tell whether a
    /// tab is idle; anything uncertain counts as busy, so a running program is never typed into.
    private func resumeInIdleTab(place: String, title: String, dir: String, command: [String],
                                 focus: Bool) async -> String? {
        let line = Self.shellLine(dir: dir, command: command)
        let occupied = Self.liveTerminalHandles()
        switch place {
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else { return nil }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            let list = await Self.run(cli, ["terminal", "list", "--json"])
            guard let data = list.out.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let terms = (root["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
            else { return nil }
            guard let handle = IdleTab.orca(terminals: terms, title: title, occupied: occupied) else { return nil }
            let sent = await Self.run(cli, ["terminal", "send", "--terminal", handle, "--text", line, "--enter", "--json"])
            guard sent.status == 0, TerminalTarget.orcaSwitchSucceeded(sent.out) else { return nil }
            if focus {
                _ = await Self.run(cli, ["terminal", "switch", "--terminal", handle, "--json"])
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.orcaBundleID).first?.activate()
            }
            return handle
        case "terminal":
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.terminalAppBundleID).isEmpty
            else { return nil }   // scripting a stopped Terminal would launch it just to look
            let r = await Self.run("/usr/bin/osascript", ["-e", IdleTab.terminalListScript])
            guard r.status == 0, let tty = IdleTab.terminalApp(listing: r.out, title: title, occupied: occupied),
                  TerminalTarget.isSafeTTYPath(tty) else { return nil }
            let typed = await Self.run("/usr/bin/osascript", ["-e", IdleTab.terminalRunScript(tty: tty, line: line, focus: focus)])
            return typed.status == 0 && typed.out.contains("ok") ? tty : nil
        default:
            return nil
        }
    }

    /// Terminal handles that a live Claude Code session is recorded in — those tabs are not idle.
    private static func liveTerminalHandles() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions")
        var out = Set<String>()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, ProcessProbe.isClaude(pid: pid),
                  let handle = (obj["terminal"] as? [String: Any])?["handle"] as? String else { continue }
            out.insert(handle)
        }
        return out
    }

    /// Ends a terminal session's Claude Code process — what Ctrl-C twice would do in its tab.
    /// The conversation is kept and Resume picks it up, in the same tab when it is still open.
    /// The pid comes from the pet's own record and must still be a Claude Code process, so a
    /// reused pid is never signalled.
    private func stopSession(_ session: String) async -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, "not a session id") }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 1 else {
            return (nil, "no process recorded for this session")
        }
        guard ProcessProbe.isClaude(pid: pid) else { return (nil, "that session is not running any more") }
        // The process's own command line names its session when the board started it; a
        // session started by hand may not say, and then the pet's record is all there is.
        if let args = ProcessProbe.arguments(pid: pid), args.contains("--session-id") || args.contains("--resume"),
           !args.contains(session) {
            return (nil, "the recorded process belongs to another session — stop it in its terminal")
        }
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if !ProcessProbe.isClaude(pid: pid) { return (["ok": true, "pid": Int(pid)], nil) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        kill(pid, SIGTERM)   // a second interrupt is how Claude Code is told "really quit"
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return ProcessProbe.isClaude(pid: pid) ? (nil, "it did not stop — close it in its terminal")
                                               : (["ok": true, "pid": Int(pid)], nil)
    }

    /// Opens a scheduled run's session to carry on talking to it: `claude --resume` in the job's
    /// folder. Not bound to any task — a job belongs to none.
    private func resumeJob(id: String, session: String, place: String, skip: Bool, focus: Bool) async -> (Any?, String?) {
        guard let job = JobsController.shared.store.load(id) else { return (nil, "No such job") }
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, "not a session id") }
        guard let claude = await claudePath() else { return (nil, "can't find the claude command") }
        let cmd = [claude, "--resume", session] + (skip ? [Self.skipFlag] : [])
        let opened = await openInTerminal(place: place == "bg" ? "terminal" : place, dir: job.directory, command: cmd,
                                          title: String(("⏱ " + job.name).prefix(60)), focus: focus)
        return opened.1 == nil ? (["ok": true, "session": session], nil) : opened
    }

    private func launch(task: String, title: String, dir rawDir: String, place: String, prompt: String,
                        skip: Bool = false, focus: Bool = true) async -> (Any?, String?) {
        let dir = (rawDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (nil, "no such directory: \(dir)")
        }
        guard let claude = await claudePath() else { return (nil, "can't find the claude command") }
        let name = String("\(task) \(title)".prefix(60))
        if place == "bg" { return await launchBackground(claude: claude, task: task, name: name, dir: dir, prompt: prompt, skip: skip) }
        let sid = UUID().uuidString.lowercased()
        let bound = await hq(["bind", task, "--session=\(sid)"])
        if let err = bound.1 { return (nil, err) }
        var cmd = [claude, "--session-id", sid, "--name", name] + (skip ? [Self.skipFlag] : [])
        cmd.append(prompt)
        let opened = await openInTerminal(place: place, dir: dir, command: cmd, title: name, focus: focus)
        if opened.1 != nil { _ = await hq(["unbind", "--session=\(sid)"]) }
        return opened.1 == nil ? (["ok": true, "session": sid, "where": place], nil) : opened
    }

    /// `claude --bg` picks its own session id (it ignores --session-id), so a background session
    /// can't be bound before it starts. It is told to bind itself first — that also hands it the
    /// task's rules — and the board binds it too as soon as `claude agents` reports its id.
    private func launchBackground(claude: String, task: String, name: String, dir: String, prompt: String,
                                  skip: Bool = false) async -> (Any?, String?) {
        let first = "Start by running `\(hqPath) bind \(task)` — it binds this background session to the task and prints its rules. Then: "
        let r = await Self.run(claude, ["--bg", "--name", name] + (skip ? [Self.skipFlag] : []) + [first + prompt], cwd: dir)
        // An untrusted folder can't show its trust prompt in the background; claude says so.
        if r.status != 0 || (r.out + r.err).localizedCaseInsensitiveContains("not trusted") {
            return (nil, "claude --bg: " + (r.err.isEmpty ? r.out : r.err).prefix(300))
        }
        guard let short = (r.out + r.err).range(of: #"\b[0-9a-f]{8}\b"#, options: .regularExpression)
            .map({ String((r.out + r.err)[$0]) }) else {
            return (["ok": true, "where": "bg"], nil)
        }
        for _ in 0..<10 {
            let list = await Self.run(claude, ["agents", "--json", "--all"])
            if let data = list.out.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let row = rows.first(where: { ($0["id"] as? String) == short }),
               let sid = row["sessionId"] as? String {
                let who = await hq(["whoami", "--session=\(sid)"])
                if (who.0 as? String)?.contains(task) != true { _ = await hq(["bind", task, "--session=\(sid)"]) }
                return (["ok": true, "session": sid, "where": "bg", "id": short], nil)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return (["ok": true, "where": "bg", "id": short], nil)
    }

    /// Runs a command in a new tab of the chosen terminal, in `dir`.
    /// `focus: false` opens the tab in the background and leaves the terminal app where it was —
    /// the user carries on from the board (its conversation window), not the terminal.
    private func openInTerminal(place: String, dir: String, command: [String], title: String,
                                focus: Bool = true) async -> (Any?, String?) {
        let line = Self.shellLine(dir: dir, command: command)
        switch place {
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else {
                return (nil, "Orca is not installed")
            }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            // In the Orca workspace for that folder when there is one, else in the current one.
            let front = focus ? ["--focus"] : []
            var r = await Self.run(cli, ["terminal", "create", "--worktree", "path:\(dir)", "--title", title,
                                         "--command", line] + front + ["--json"])
            if r.status != 0 {
                r = await Self.run(cli, ["terminal", "create", "--title", title, "--command", line] + front + ["--json"])
            }
            if r.status == 0, focus { NSRunningApplication.runningApplications(withBundleIdentifier: Self.orcaBundleID).first?.activate() }
            return r.status == 0 ? (["ok": true], nil) : (nil, "orca: " + (r.err.isEmpty ? r.out : r.err).prefix(300))
        case "iterm2", "terminal":
            let esc = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = place == "iterm2" ? """
            tell application "iTerm2"
              \(focus ? "activate" : "")
              if (count of windows) = 0 then
                create window with default profile
              else
                tell current window to create tab with default profile
              end if
              tell current session of current window to write text "\(esc)"
            end tell
            """ : """
            tell application "Terminal"
              \(focus ? "activate" : "")
              set t to do script "\(esc)"
              set custom title of t to "\(IdleTab.appleScriptLiteral(title))"
            end tell
            """
            let r = await Self.run("/usr/bin/osascript", ["-e", script])
            return r.status == 0 ? (["ok": true], nil) : (nil, "\(place): " + (r.err.isEmpty ? r.out : r.err).prefix(300))
        default:
            return (nil, "unknown place to open: \(place)")
        }
    }

    // MARK: - Files

    /// Opens a path mentioned in a conversation with its default app. Paths
    /// come from transcript text, so anything that could run — an app, a
    /// script, an executable — is only revealed in Finder, never opened.
    private func openPath(_ raw: String, cwd: String) -> (Any?, String?) {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if let r = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { path.removeSubrange(r) }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard !cwd.isEmpty else { return (nil, "relative path and no working directory") }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return (nil, "not found: \(url.path)")
        }
        // A path from a conversation is shown in Finder, not opened, if opening it could run
        // something: apps, installers, scripts, executables, link files, and any bundle.
        let risky: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "terminal", "pkg", "mpkg",
                                  "dmg", "workflow", "scpt", "scptd", "applescript", "jar", "jnlp", "py", "rb",
                                  "pl", "prefpane", "action", "fileloc", "webloc", "inetloc", "url", "mobileconfig"]
        let ext = url.pathExtension.lowercased()
        let bundle = isDir.boolValue && NSWorkspace.shared.isFilePackage(atPath: url.path)
        if risky.contains(ext) || bundle || (!isDir.boolValue && FileManager.default.isExecutableFile(atPath: url.path)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return (["ok": true, "revealed": true], nil)
        } else {
            NSWorkspace.shared.open(url)
        }
        return (["ok": true], nil)
    }

    // MARK: - hq

    private var hqPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/hq/bin/hq").path
    }

    /// Runs hq and hands its stdout back as text; the page parses JSON itself.
    private func hq(_ args: [String]) async -> (Any?, String?) {
        guard FileManager.default.isExecutableFile(atPath: hqPath) else {
            return (nil, "HQ is not installed — run hq/install.sh --root <dir>")
        }
        let r = await Self.run(hqPath, args)
        if r.status != 0 {
            return (nil, r.err.isEmpty ? "hq exited \(r.status)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (r.out, nil)
    }

    // MARK: - Terminals

    private struct Terminal { let kind: String; let handle: String }

    private func terminal(of session: String) -> Terminal? {
        guard !session.isEmpty, !session.contains("/") else { return nil }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["terminal"] as? [String: Any],
              let kind = t["kind"] as? String, let handle = t["handle"] as? String
        else { return nil }
        return Terminal(kind: kind, handle: handle)
    }

    /// Types the message into the session's terminal and presses Enter — to
    /// Claude it is indistinguishable from the user typing it.
    /// `queue`: the session is busy, so the message waits in Claude Code's queue until the turn
    /// ends — no turn will start within seconds, so don't sit watching for one.
    private func send(session: String, text: String, queue: Bool = false, bg: String = "",
                      skip: Bool = false) async -> (Any?, String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "empty message") }
        guard let t = terminal(of: session) else {
            if !bg.isEmpty { return await sendBackground(session: session, bgId: bg, text: text, busy: queue, skip: skip) }
            return (nil, "no terminal recorded for this session")
        }
        switch t.kind {
        case "terminal":
            guard TerminalTarget.isSafeTTYPath(t.handle) else { return (nil, "unexpected Terminal tty") }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.terminalAppBundleID).isEmpty
            else { return (nil, "Terminal is not running") }
            // Terminal.app types `do script` text into the tab as if from the keyboard. Lines are
            // joined (a newline would submit early), and the text ends in a carriage return —
            // the Return key — so the prompt is submitted whatever line ending Terminal adds.
            let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            let before = Self.lastPromptAt(session)
            let r = await Self.run("/usr/bin/osascript", ["-e", IdleTab.terminalTypeScript(tty: t.handle, text: flat)])
            guard r.status == 0, r.out.contains("ok") else {
                return (nil, r.out.contains("notfound") ? "its Terminal tab is gone" :
                        "Terminal: " + (r.err.isEmpty ? r.out : r.err).prefix(200))
            }
            if queue { return (["ok": true, "queued": true], nil) }
            // Like Orca's --wait-submit: say so if no turn started, instead of claiming it got there.
            for _ in 0..<25 {
                if Self.lastPromptAt(session) != before { return (["ok": true], nil) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return (nil, "typed into its Terminal tab, but no turn started — check the tab and press Return there")
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else {
                return (nil, "Orca is not installed")
            }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            let r = await Self.run(cli, ["terminal", "send", "--terminal", t.handle, "--text", text,
                                         "--enter", "--json"] + (queue ? [] : ["--wait-submit", "5"]))
            return r.status == 0 ? (["ok": true, "queued": queue, "detail": r.out], nil)
                                 : (nil, "orca: \(r.err.isEmpty ? r.out : r.err)".prefix(300).description)
        case "iterm2":
            let uuid = TerminalTarget.iTermUUID(from: t.handle)
            guard TerminalTarget.isSafeITermUUID(uuid) else { return (nil, "unexpected iTerm2 session id") }
            // write text presses Return after each line, which would submit a
            // multi-line message early, so lines are joined.
            let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            let escaped = flat.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if (id of s as text) contains "\(uuid)" then
                      tell s to write text "\(escaped)"
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "notfound"
            """
            let r = await Self.run("/usr/bin/osascript", ["-e", script])
            return r.out.contains("ok") ? (["ok": true], nil) : (nil, "iTerm2 session not found")
        default:
            return (nil, "sending to \(t.kind) terminals is not supported yet — use Jump")
        }
    }

    /// When the session last took a prompt, per the pet's record — changes when a message lands.
    private static func lastPromptAt(_ session: String) -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (obj["lastPromptAt"] as? String) ?? ""
    }

    /// A background session has no terminal to type into. One that is not mid-turn takes the
    /// message the way `claude --bg --resume` allows: it is stopped (its conversation is kept)
    /// and continued in the background, under the same id, with the message as its prompt.
    private func sendBackground(session: String, bgId: String, text: String, busy: Bool,
                                skip: Bool) async -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil,
              bgId.range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression) != nil else { return (nil, "not a session id") }
        if busy { return (nil, "it is busy — try again when its turn ends") }
        guard let claude = await claudePath() else { return (nil, "can't find the claude command") }
        func running() async -> [String: Any]? {
            let list = await Self.run(claude, ["agents", "--json"])
            guard let data = list.out.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            return rows.first { ($0["sessionId"] as? String) == session }
        }
        if let row = await running() {
            let st = ((row["status"] as? String) ?? (row["state"] as? String) ?? "").lowercased()
            if st == "busy" || st == "running" || st == "working" { return (nil, "it is busy — try again when its turn ends") }
            _ = await Self.run(claude, ["stop", bgId])
            for _ in 0..<25 {
                if await running() == nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if await running() != nil { return (nil, "it did not stop to take the message — Attach to talk to it") }
        }
        var dir = Self.sessionCwd(session)
        if dir == nil {   // a background session the pet never saw: `claude agents` knows its folder
            let all = await Self.run(claude, ["agents", "--json", "--all"])
            if let data = all.out.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let cwd = rows.first(where: { ($0["sessionId"] as? String) == session })?["cwd"] as? String,
               FileManager.default.fileExists(atPath: cwd) { dir = cwd }
        }
        guard let dir else { return (nil, "can't tell which folder that session ran in") }
        // A message that starts with "-" would be read as an option; a leading space keeps it the prompt.
        let prompt = text.hasPrefix("-") ? " " + text : text
        let r = await Self.run(claude, ["--bg", "--resume", session] + (skip ? [Self.skipFlag] : []) + [prompt], cwd: dir)
        guard r.status == 0 else { return (nil, "claude --bg --resume: " + (r.err.isEmpty ? r.out : r.err).prefix(300)) }
        return (["ok": true, "resumed": true], nil)
    }

    private static func sessionCwd(_ session: String) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = obj["cwd"] as? String, FileManager.default.fileExists(atPath: cwd) else { return nil }
        return cwd
    }

    // MARK: - Process

    private struct Result: Sendable { let status: Int32; let out: String; let err: String }
    private final class DataBox: @unchecked Sendable { var value = Data() }

    private nonisolated static func run(_ tool: String, _ args: [String], cwd: String? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                var env = ProcessInfo.processInfo.environment
                // If the pet itself was started from inside a Claude Code session, don't let its
                // children look like part of that session (claude refuses to nest; hq would think
                // a board-side bind came from inside the session).
                for key in env.keys where key == "CLAUDECODE" || key == "CLAUDE_PID" || key.hasPrefix("CLAUDE_CODE_") {
                    env.removeValue(forKey: key)
                }
                env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    // Drain both pipes while the child runs, or a full one blocks it forever.
                    let errData = DataBox()
                    let drained = DispatchGroup()
                    drained.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData.value = err.fileHandleForReading.readDataToEndOfFile()
                        drained.leave()
                    }
                    let o = out.fileHandleForReading.readDataToEndOfFile()
                    drained.wait()
                    let e = errData.value
                    p.waitUntilExit()
                    continuation.resume(returning: Result(
                        status: p.terminationStatus,
                        out: String(data: o, encoding: .utf8) ?? "",
                        err: String(data: e, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(returning: Result(status: -1, out: "", err: error.localizedDescription))
                }
            }
        }
    }
}
