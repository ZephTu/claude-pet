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

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let body = message.body as? [String: Any] ?? [:]
        func str(_ key: String) -> String { body[key] as? String ?? "" }

        switch body["op"] as? String ?? "" {
        case "board": return await hq(["board", "--json"])
        case "sessions": return await hq(["sessions", "--json"])
        case "peek": return await hq(["peek", str("session"), "-n", "30", "--json", "--meta"])
        case "resolve":
            return await hq(["ask", "resolve", str("id"), str("resolution"),
                             "--via", "board", "--note=\(str("note"))"])
        case "reopen": return await hq(["ask", "reopen", str("id"), "--via=board"])
        case "delivered":
            return await hq(["ask", "delivered", str("id"), "--session=\(str("session"))"] + (body["undo"] as? Bool == true ? ["--undo"] : []))
        case "todo":
            let index = (body["index"] as? Int).map(String.init) ?? str("index")
            return await hq(["todo", str("task"), index, str("state"), "--via=board"])
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
            var args = ["new", "--category=\(str("category").isEmpty ? "dev" : str("category"))"]
            if !str("workdir").isEmpty { args.append("--workdir=\(str("workdir"))") }
            if !str("project").isEmpty { args.append("--project=\(str("project"))") }
            return await hq(args + ["--", str("title")])
        case "send": return await send(session: str("session"), text: str("text"))
        case "launch":
            return await launch(task: str("task"), title: str("title"), dir: str("dir"),
                                place: str("where"), prompt: str("prompt"))
        case "attach": return await openInTerminal(place: str("where"), dir: NSHomeDirectory(),
                                                    command: [claudePath() ?? "claude", "attach", str("session")],
                                                    title: "attach " + str("session").prefix(8))
        case "stop":
            guard let claude = claudePath() else { return (nil, "can't find the claude command") }
            let r = await Self.run(claude, ["stop", str("session")])
            return r.status == 0 ? (["ok": true], nil) : (nil, r.err.isEmpty ? r.out : r.err)
        case "agents":
            // Background sessions have no terminal, so the pet's records can't say what they are;
            // `claude agents --json` can.
            guard let claude = claudePath() else { return ("[]", nil) }
            let r = await Self.run(claude, ["agents", "--json"])
            return (r.status == 0 ? r.out : "[]", nil)
        case "jump":
            guard let t = terminal(of: str("session")) else { return (nil, "no terminal recorded for this session") }
            TerminalJump.jump(kind: t.kind, handle: t.handle)
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

    // MARK: - New sessions

    /// The claude CLI. The pet runs outside any shell, so PATH doesn't know about it: look in the
    /// usual install places, then ask a login shell once.
    private var cachedClaude: String??
    private func claudePath() -> String? {
        if let c = cachedClaude { return c }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lic", "command -v claude"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
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
    private func launch(task: String, title: String, dir: String, place: String, prompt: String) async -> (Any?, String?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (nil, "no such directory: \(dir)")
        }
        guard let claude = claudePath() else { return (nil, "can't find the claude command") }
        let name = String("\(task) \(title)".prefix(60))
        if place == "bg" { return await launchBackground(claude: claude, task: task, name: name, dir: dir, prompt: prompt) }
        let sid = UUID().uuidString.lowercased()
        let bound = await hq(["bind", task, "--session=\(sid)"])
        if let err = bound.1 { return (nil, err) }
        var cmd = [claude, "--session-id", sid, "--name", name]
        cmd.append(prompt)
        let opened = await openInTerminal(place: place, dir: dir, command: cmd, title: name)
        if opened.1 != nil { _ = await hq(["unbind", "--session=\(sid)"]) }
        return opened.1 == nil ? (["ok": true, "session": sid, "where": place], nil) : opened
    }

    /// `claude --bg` picks its own session id (it ignores --session-id), so a background session
    /// can't be bound before it starts. It is told to bind itself first — that also hands it the
    /// task's rules — and the board binds it too as soon as `claude agents` reports its id.
    private func launchBackground(claude: String, task: String, name: String, dir: String, prompt: String) async -> (Any?, String?) {
        let first = "Start by running `\(hqPath) bind \(task)` — it binds this background session to the task and prints its rules. Then: "
        let r = await Self.run(claude, ["--bg", "--name", name, first + prompt], cwd: dir)
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
    private func openInTerminal(place: String, dir: String, command: [String], title: String) async -> (Any?, String?) {
        // A board started with HQ_ROOT (tests, a second root) passes it on to the new session.
        var line = "cd \(Self.shq(dir)) && "
        if let root = ProcessInfo.processInfo.environment["HQ_ROOT"] { line += "HQ_ROOT=\(Self.shq(root)) " }
        line += command.map(Self.shq).joined(separator: " ")
        switch place {
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else {
                return (nil, "Orca is not installed")
            }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            // In the Orca workspace for that folder when there is one, else in the current one.
            var r = await Self.run(cli, ["terminal", "create", "--worktree", "path:\(dir)", "--title", title,
                                         "--command", line, "--focus", "--json"])
            if r.status != 0 {
                r = await Self.run(cli, ["terminal", "create", "--title", title, "--command", line, "--focus", "--json"])
            }
            if r.status == 0 { NSRunningApplication.runningApplications(withBundleIdentifier: Self.orcaBundleID).first?.activate() }
            return r.status == 0 ? (["ok": true], nil) : (nil, "orca: " + (r.err.isEmpty ? r.out : r.err).prefix(300))
        case "iterm2", "terminal":
            let esc = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = place == "iterm2" ? """
            tell application "iTerm2"
              activate
              if (count of windows) = 0 then
                create window with default profile
              else
                tell current window to create tab with default profile
              end if
              tell current session of current window to write text "\(esc)"
            end tell
            """ : """
            tell application "Terminal"
              activate
              do script "\(esc)"
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
        let risky: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "terminal", "pkg",
                                  "dmg", "workflow", "scpt", "applescript", "jar", "py", "rb", "pl"]
        let ext = url.pathExtension.lowercased()
        if isDir.boolValue && ext != "app" {
            NSWorkspace.shared.open(url)
        } else if risky.contains(ext) || (!isDir.boolValue && FileManager.default.isExecutableFile(atPath: url.path)) {
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
    private func send(session: String, text: String) async -> (Any?, String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "empty message") }
        guard let t = terminal(of: session) else { return (nil, "no terminal recorded for this session") }
        switch t.kind {
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else {
                return (nil, "Orca is not installed")
            }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            let r = await Self.run(cli, ["terminal", "send", "--terminal", t.handle, "--text", text,
                                         "--enter", "--wait-submit", "5", "--json"])
            return r.status == 0 ? (["ok": true, "detail": r.out], nil)
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

    // MARK: - Process

    private struct Result: Sendable { let status: Int32; let out: String; let err: String }

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
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    // Read before waiting, or a full pipe blocks the child forever.
                    let o = out.fileHandleForReading.readDataToEndOfFile()
                    let e = err.fileHandleForReading.readDataToEndOfFile()
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
