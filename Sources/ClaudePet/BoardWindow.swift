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
        webView.configuration.userContentController.installLanguageScript()
        center()
        setFrameAutosaveName("HQBoard")
        if let url = PetSchemeHandler.url(path: "board/board.html") {
            webView.load(URLRequest(url: url))
        } else {
            NSLog("ClaudePet: board resources missing from bundle")
        }
    }

    /// The language changed: reload whatever page is showing, in the new one.
    func reloadForLanguage() {
        webView.configuration.userContentController.installLanguageScript()
        webView.reload()
    }

    /// Brings the board forward and gives it the keyboard. The pet is an
    /// accessory app, so it has to activate itself for the window to be key.
    func present(reveal task: String = "") {
        showInDock(true)
        // Minimised, it would stay in the Dock: every way of opening the board restores it.
        if isMiniaturized { deminiaturize(nil) }
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

    // MARK: - Dock and Cmd-Tab while the board is open

    /// The pet lives outside the Dock and Cmd-Tab (an accessory app). While
    /// the board is open it joins both, with the pet as its icon, so the board
    /// can be switched back to like any window; closing the board takes it out
    /// again. A board that is merely behind other windows keeps its place.
    private func showInDock(_ on: Bool) {
        let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            if on { NSApp.mainMenu = Self.boardMenu() }
            NSApp.setActivationPolicy(policy)
        }
        guard on, let icon = Self.dockIcon() else { return }
        // The icon every time: the skin may have changed while the board was open (it is cached).
        // After the policy switch, and once more on the next turn: the bundle has no icon file,
        // and the Dock tile it builds for a newly regular app came up blank (the generic app
        // icon) until a click redrew it, when the icon had been set before the switch.
        NSApp.applicationIconImage = icon
        DispatchQueue.main.async {
            guard NSApp.activationPolicy() == .regular else { return }
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
    }

    override func close() {
        super.close()
        showInDock(false)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        showInDock(false)
    }

    /// A regular app shows a menu bar; this is the least it needs: close the
    /// board (Cmd-W) and quit. Quit carries no Cmd-Q on purpose: Cmd-Q is
    /// pressed by reflex to close a window, and here it would take the pet
    /// away with the board. Quitting from the menu or the Dock is deliberate.
    private static func boardMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: L("Close Task Board", "关闭任务看板"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quit Claude Pet", "退出 Claude Pet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = app
        main.addItem(appItem)
        return main
    }

    /// The pet as the app icon: the current skin's idle picture on a rounded
    /// tile in the board's colour, drawn once per skin.
    private static var iconCache: (skin: String, image: NSImage)?
    private static func dockIcon() -> NSImage? {
        let skin = UserDefaults.standard.string(forKey: "petSkin") ?? PetSkins.defaultID
        if let cached = iconCache, cached.skin == skin { return cached.image }
        guard let root = Bundle.module.url(forResource: "pet", withExtension: nil) else { return nil }
        let picture = [skin, PetSkins.defaultID].lazy
            .compactMap { NSImage(contentsOf: root.appendingPathComponent("skins/\($0)/assets/idle.png")) }
            .first
        guard let picture else { return nil }
        let side: CGFloat = 512
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Apple's icon grid: the tile is ~80% of the canvas, corners ~22% of the tile.
            let tile = rect.insetBy(dx: side * 0.1, dy: side * 0.1)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            NSColor(calibratedRed: 0.137, green: 0.125, blue: 0.114, alpha: 1).setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            picture.draw(in: tile.insetBy(dx: tile.width * 0.06, dy: tile.width * 0.06))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        iconCache = (skin, icon)
        return icon
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
    /// A session's conversation was just opened in Peek. The jump log notes how long before a
    /// jump that was — see JumpLog.
    static var onPeek: ((String) -> Void)?
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
        // The Focus cards' ⚠ lines (polled about once a minute: it reads each task's sessions).
        case "status": return await hq(["status", "--focus", "--json"])
        case "peek":
            // An open conversation shows the newest reply: that is reading it.
            let r = await hq(["peek", str("session"), "-n", "30", "--json", "--meta"])
            if r.1 == nil {
                Self.onSeen?(str("session"))
                // Opening it, not the refreshes every few seconds while it stays open.
                if body["opened"] as? Bool == true { Self.onPeek?(str("session")) }
            }
            return r
        case "commands":
            // The skills this session can run as slash commands, for the message box's completion.
            return await hq(["peek", str("session"), "--commands", "--json"])
        case "peek-tool":
            // One tool call's full input and output, for a Peek row that was opened.
            return await hq(["peek", str("session"), "--tool", str("id"), "--json"])
        case "pet":
            var pet: [String: Any] = ["unread": Self.unreadBySession?() ?? [:], "dots": Self.petDots?() ?? [:]]
            if let usage = Self.usage?() { pet["usage"] = usage }
            let data = (try? JSONSerialization.data(withJSONObject: pet, options: [.sortedKeys])) ?? Data("{}".utf8)
            return (String(decoding: data, as: UTF8.self), nil)
        case "resolve":
            // "Yes, always" carries the standing grant's wording; hq adds it to the card with the answer.
            let grant = str("grant").isEmpty ? [] : ["--grant=\(str("grant"))"]
            let r = await hq(["ask", "resolve", str("id"), str("resolution"),
                              "--via", "board", "--note=\(str("note"))"] + grant)
            // A yes to one of the secretary's proposals: it carries it out now, not at its next chat.
            if r.1 == nil { secretary.answered(askID: str("id"), resolution: str("resolution")) }
            return r
        case "grant":
            // list / add / revoke the standing grants of a task, or of a project (`project`, kept in its
            // PROJECT.md); revoke goes by #n, checked against the text shown.
            let index = (body["index"] as? Int).map(String.init) ?? str("index")
            // Positionals first and the wording as --text=: argparse can't take `rest*` positionals
            // after options, and wording starting with "-" must not read as one.
            let project = str("project")
            let who = project.isEmpty ? [str("task")] : []
            let whose = project.isEmpty ? [] : ["--project=\(project)"]
            switch str("action") {
            case "add":
                let extra = (str("at").isEmpty ? [] : ["--at=\(str("at"))"]) + (str("source").isEmpty ? [] : ["--source=\(str("source"))"])
                return await hq(["grant", "add"] + who + whose + ["--via=board", "--text=\(str("text"))"] + extra)
            case "revoke":
                return await hq(["grant", "revoke"] + who + (index.isEmpty ? [] : [index]) + whose + ["--via=board", "--text=\(str("text"))"])
            default: return await hq(["grant", "list"] + who + whose + ["--json"])
            }
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
            guard !fields.isEmpty else { return (nil, L("no fields", "没有要改的字段")) }
            return await hq(["set", str("task")] + fields)
        case "log": return await hq(["log", str("task"), "--", str("message")])
        case "focus":
            return await hq(["focus", str("action")] + ((body["tasks"] as? [String]) ?? []) + ["--json"])
        case "scan": return await hq(["scan", "--json"])
        case "scan-apply":
            let only = ((body["names"] as? [String]) ?? []).joined(separator: ",")
            guard !only.isEmpty else { return (nil, L("nothing selected", "什么都没选")) }
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
            guard let claude = await claudePath() else { return (nil, L("can't find the claude command", "找不到 claude 命令")) }
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
                  !str("session").isEmpty, !str("ask").isEmpty else { return (nil, L("bad decision", "无效的决定")) }
            guard let decide = Self.onDecide else { return (nil, L("answer it in the terminal", "请到终端里回应")) }
            // The prompt the click was for must still be the one the pet can answer: a hold that
            // ended, or a prompt replaced since the board drew it, approves nothing.
            guard (Self.petDots?()[str("session")]?["askId"] as? String) == str("ask") else {
                return (nil, L("that prompt is no longer waiting here — answer it in the terminal", "这个请求已经不在这里等了 — 请到终端里回应"))
            }
            decide(str("session"), str("ask"), behavior)
            return (["ok": true], nil)
        case "jump":
            let origin = TerminalJump.Origin(session: str("session"), source: str("from").isEmpty ? "board" : str("from"),
                                             view: str("view"))
            guard let t = terminal(of: str("session")) else {
                // Logged anyway: the log is about why the user wanted the terminal, not whether it worked.
                TerminalJump.record?(origin, "")
                return (nil, L("no terminal recorded for this session", "没有记录这个 session 的终端"))
            }
            // The page says which button: a card's session row, the sessions list, Peek, …
            TerminalJump.jump(kind: t.kind, handle: t.handle, from: origin)
            Self.onSeen?(str("session"))
            return (["ok": true], nil)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str("text"), forType: .string)
            return (["ok": true], nil)
        case "openURL":
            guard let url = URL(string: str("url")),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
            else { return (nil, L("only web links can be opened", "只能打开网页链接")) }
            NSWorkspace.shared.open(url)
            return (["ok": true], nil)
        case "openPath": return openPath(str("path"), cwd: str("cwd"))

        // Scheduled jobs — see JobsController.
        // The secretary's chat (SecretaryController): its state, setting it up, a message, stop.
        case "secretary": return await secretary.status()
        case "secretary-setup": return await secretary.setup(lang: str("lang"))
        case "secretary-send": return await secretary.send(str("text"))
        case "secretary-stop": return secretary.stop()
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
            // A task card, or a project's PROJECT.md (the project panel's "Open PROJECT.md").
            guard path.hasSuffix("/TASK.md") || path.hasSuffix("/PROJECT.md"), FileManager.default.fileExists(atPath: path) else {
                return (nil, L("not a task card or project file", "不是任务卡或项目文件"))
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return (["ok": true], nil)
        default:
            return (nil, L("unknown operation", "未知操作"))
        }
    }

    // MARK: - Images

    /// An image pasted or dropped into a message box, saved as a file so its path can go into the
    /// message — Claude Code reads an image from a path in the prompt.
    private func saveImage(dataURL: String) -> (Any?, String?) {
        let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return (nil, L("not an image", "不是图片")) }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]   // image/png;base64
        let mime = String(header.split(separator: ";").first ?? "")
        guard header.hasSuffix(";base64"), let ext = types[mime] else { return (nil, L("unsupported image type \(mime)", "不支持的图片类型 \(mime)")) }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return (nil, L("bad image data", "图片数据有误")) }
        guard data.count <= 20 * 1024 * 1024 else { return (nil, L("image is larger than 20 MB", "图片超过 20 MB")) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/hq/attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(fmt.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased()).\(ext)"
        let url = dir.appending(path: name)
        do { try data.write(to: url) } catch { return (nil, L("could not save the image: \(error.localizedDescription)", "图片没能保存：\(error.localizedDescription)")) }
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

    /// Sessions a Resume is under way for, and those whose woken Orca tab is still watched after
    /// Resume answered (see resumeInOrcaPlace): a second Resume of one is turned away.
    private static var resuming = Set<String>()
    private static var watching = Set<String>()

    /// Picks up an earlier session of a task where it left off: `claude --resume <id>` in the
    /// directory it ran in (Claude Code keeps a conversation under that directory), bound to the
    /// task again. A background place opens a terminal instead — there is nothing to attach to.
    private func resume(task: String, session: String, dir rawDir: String, place: String, skip: Bool,
                        name: String = "", focus: Bool = true) async -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        let dir = (rawDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return (nil, L("no such directory: \(dir)", "没有这个目录：\(dir)"))
        }
        // A second Resume of the same session while the first is still at it (a double click)
        // would wake, type or open a tab twice — and run the session twice.
        guard !Self.resuming.contains(session), !Self.watching.contains(session) else {
            return (nil, L("Already resuming this session — give it a moment", "正在续上这个 session，稍等一下"))
        }
        Self.resuming.insert(session)
        defer { Self.resuming.remove(session) }
        guard let claude = await claudePath() else { return (nil, L("can't find the claude command", "找不到 claude 命令")) }
        let bound = await hq(["bind", task, "--session=\(session)"])
        if let err = bound.1 { return (nil, err) }
        let into = place == "bg" ? "terminal" : place
        let cmd = [claude, "--resume", session] + (skip ? [Self.skipFlag] : [])
        // The tab keeps the session's own name, as the pet and the board show it.
        let title = name.isEmpty ? "\(task) \(session.prefix(8))" : String(name.prefix(60))
        // Orca knows which tab it has this session in, asleep after a restart too — go back there.
        if into == "orca", let back = await resumeInOrcaPlace(session: session, dir: dir, command: cmd, focus: focus) {
            return back
        }
        // A tab this session ran in before — kept by Orca or Terminal across a restart, or left
        // behind by Stop — is reused rather than opening a second one beside it.
        if let reused = await resumeInIdleTab(place: into, title: title, dir: dir, command: cmd, focus: focus) {
            return (["ok": true, "session": session, "where": into, "reused": reused], nil)
        }
        let opened = await openInTerminal(place: into, dir: dir, command: cmd, title: title, focus: focus)
        return opened.1 == nil ? (["ok": true, "session": session, "where": into], nil) : opened
    }

    /// The shell line that runs `command` in `dir`, as `openInTerminal` types it. The shell exits
    /// after it, so when the session ends — Stop, /exit, Ctrl-C twice — its tab closes instead of
    /// piling up at a prompt (Orca and iTerm2 close a tab whose shell exits; Terminal.app does when
    /// its profile says "close if the shell exited cleanly", hence `exit 0`). The `;` also runs it
    /// after a failed `cd`, so a tab the board opened never lingers.
    private static func shellLine(dir: String, command: [String]) -> String {
        var line = "cd \(shq(dir)) && "
        // A board started with HQ_ROOT (tests, a second root) passes it on to the new session.
        if let root = ProcessInfo.processInfo.environment["HQ_ROOT"] { line += "HQ_ROOT=\(shq(root)) " }
        return line + command.map(shq).joined(separator: " ") + "; exit 0"
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

    /// Resumes a session in the Orca tab Orca has it in, or nil when Orca has no usable tab for
    /// it (then the caller looks for an idle tab by title, or opens one). Orca may have it in
    /// several panes; `OrcaPlace.choose` picks one. After a restart a tab sleeps until its
    /// workspace is opened, and Orca then resumes the session in it by itself — so a sleeping
    /// tab is woken and nothing is typed (typing too would run the session twice), unless it
    /// wakes to a bare prompt and stays there (Stop had ended it before the restart). A tab Stop
    /// left at a shell prompt gets the resume command; one that already runs the session is only
    /// brought forward; one another session or program runs in is left alone.
    private func resumeInOrcaPlace(session: String, dir: String, command: [String],
                                   focus: Bool) async -> (Any?, String?)? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else { return nil }
        let cli = app.appending(path: "Contents/Resources/bin/orca").path
        let asked = await Self.run(cli, ["agent", "show", session, "--json"], timeout: Self.orcaTimeout)
        guard let id = OrcaPlace.orcaSessionID(showOutput: asked.out) else { return nil }
        let shown = await Self.run(cli, ["agent", "show", "orca_session_id:\(id)", "--json"], timeout: Self.orcaTimeout)
        let places = OrcaPlace.places(showOutput: shown.out)
        guard !places.isEmpty else { return nil }
        func terminals() async -> [[String: Any]]? {
            let list = await Self.run(cli, ["terminal", "list", "--json"], timeout: Self.orcaTimeout)
            guard list.status == 0, let data = list.out.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
        }
        func bringForward(_ handle: String) async {
            guard focus else { return }
            _ = await Self.run(cli, ["terminal", "switch", "--terminal", handle, "--json"], timeout: Self.orcaTimeout)
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.orcaBundleID).first?.activate()
        }
        let line = Self.shellLine(dir: dir, command: command)
        /// Types the resume command; an error when Orca doesn't confirm it — falling back to
        /// another tab then could type it twice.
        func type(_ handle: String) async -> String? {
            let sent = await Self.run(cli, ["terminal", "send", "--terminal", handle, "--text", line, "--enter", "--json"],
                                      timeout: Self.orcaSendTimeout)
            guard sent.status == 0, TerminalTarget.orcaSwitchSucceeded(sent.out) else {
                return L("Orca didn't confirm typing the resume command into the session's tab — check that tab before trying again",
                         "Orca 没确认把续上的命令输进这个 session 的标签页——先看看那个标签页再重试")
            }
            return nil
        }
        guard let terms = await terminals() else {
            return (nil, L("Couldn't read Orca's terminals — try Resume again", "读不到 Orca 的终端列表——再点一次 Resume 试试"))
        }
        let done: (String, Bool) -> (Any?, String?) = { handle, woke in
            var r: [String: Any] = ["ok": true, "session": session, "where": "orca", "reused": handle]
            if woke { r["woke"] = true }
            return (r, nil)
        }
        let woken: OrcaPlace.Place
        switch OrcaPlace.choose(places: places, terminals: terms, session: session, recorded: Self.liveSessionsByHandle()) {
        case .bringForward(_, let handle)?:
            await bringForward(handle)
            return done(handle, false)
        case .type(_, let handle)?:
            if let err = await type(handle) { return (nil, err) }
            await bringForward(handle)
            return done(handle, false)
        case nil:
            return nil   // every tab it is in runs something else
        case .wake(let place)?:
            woken = place
        }
        // Asleep: opening its workspace wakes the tab, and Orca resumes the session in it.
        let woke = await Self.run(cli, ["worktree", "activate", "--worktree", OrcaPlace.worktreeSelector(woken), "--json"],
                                  timeout: Self.orcaSendTimeout)
        guard woke.status == 0, TerminalTarget.orcaSwitchSucceeded(woke.out) else {
            return (nil, L("This session sleeps in an Orca tab the board can't wake — open its workspace in Orca and Orca resumes it there",
                           "这个 session 在 Orca 一个休眠的标签页里，board 叫不醒——在 Orca 里打开它所在的工作区，Orca 会在原标签页里恢复它"))
        }
        /// Polls the woken tab for up to 10 s: brought forward once it is live, and given the
        /// resume command if it stays at a bare prompt (see OrcaPlace.WakeWatch). Answers the
        /// tab's handle when one was seen, and the error if typing failed.
        func watch() async -> (handle: String?, error: String?) {
            var w = OrcaPlace.WakeWatch()
            var seen: String?
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let terms = await terminals() else { continue }
                let step = w.step(places: places, woken: woken, terminals: terms, session: session,
                                  recorded: Self.liveSessionsByHandle())
                switch step {
                case .arrived(let h):
                    if h != seen { await bringForward(h) }
                    return (h, nil)
                case .type(let h):
                    if h != seen { await bringForward(h) }
                    return (h, await type(h))   // once
                case .wait(let h?) where h != seen:
                    seen = h
                    await bringForward(h)
                case .wait:
                    continue
                }
            }
            return (seen, nil)
        }
        // Staying on the board: nothing to switch to, so answer now. The watch still has to run
        // (a tab that wakes to a bare prompt needs the command), so it carries on in the
        // background, and a second Resume of the session is turned away until it is over.
        guard focus else {
            Self.watching.insert(session)
            Task { @MainActor in
                _ = await watch()
                Self.watching.remove(session)
            }
            return (["ok": true, "session": session, "where": "orca", "woke": true], nil)
        }
        let watched = await watch()
        if let err = watched.error { return (nil, err) }
        if let h = watched.handle { return done(h, true) }
        return (["ok": true, "session": session, "where": "orca", "woke": true], nil)
    }

    /// Orca CLI calls on Resume's path get this long before they are ended — a hung Orca must
    /// not leave Resume (and its in-flight guard) stuck. `terminal send` waits up to 5 s itself
    /// to see the line submitted, and waking a workspace can take a while, so those get longer.
    private static let orcaTimeout: TimeInterval = 5
    private static let orcaSendTimeout: TimeInterval = 10

    /// Terminal handles that a live Claude Code session is recorded in — those tabs are not idle.
    private static func liveTerminalHandles() -> Set<String> { Set(liveSessionsByHandle().keys) }

    /// Which Claude Code session the pet records live in each terminal handle — Orca's own
    /// `agentIdentity` names only the provider, so this is how Resume tells its session's tab
    /// from one another session runs in.
    private static func liveSessionsByHandle() -> [String: String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions")
        var out: [String: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, ProcessProbe.isClaude(pid: pid),
                  let handle = (obj["terminal"] as? [String: Any])?["handle"] as? String else { continue }
            out[handle] = (obj["sessionId"] as? String) ?? f.deletingPathExtension().lastPathComponent
        }
        return out
    }

    /// Ends a terminal session's Claude Code process — what Ctrl-C twice would do in its tab.
    /// The conversation is kept and Resume picks it up. A tab the board opened closes with it
    /// (see `shellLine`); one you started yourself stays at its prompt, and Resume reuses it.
    /// The pid comes from the pet's own record and must still be a Claude Code process, so a
    /// reused pid is never signalled.
    private func stopSession(_ session: String) async -> (Any?, String?) {
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 1 else {
            return (nil, L("no process recorded for this session", "没有记录这个 session 的进程"))
        }
        guard ProcessProbe.isClaude(pid: pid) else { return (nil, L("that session is not running any more", "这个 session 已经不在运行了")) }
        // Claude Code's own file for the pid names the session it is on now (it follows /clear,
        // and a reused pid has its new owner's file); the command line is the fallback.
        let sessionsFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions/\(pid).json")
        guard SessionControl.processIsSession(session, sessionsFile: try? Data(contentsOf: sessionsFile),
                                              arguments: ProcessProbe.arguments(pid: pid)) else {
            return (nil, L("that process is on another session now — stop it in its terminal", "这个进程现在已经是另一个 session 了 — 请在它的终端里停掉"))
        }
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if !ProcessProbe.isClaude(pid: pid) { return (["ok": true, "pid": Int(pid)], nil) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        kill(pid, SIGTERM)   // a second interrupt is how Claude Code is told "really quit"
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return ProcessProbe.isClaude(pid: pid) ? (nil, L("it did not stop — close it in its terminal", "它没有停下 — 请在它的终端里关掉"))
                                               : (["ok": true, "pid": Int(pid)], nil)
    }

    /// Opens a scheduled run's session to carry on talking to it: `claude --resume` in the job's
    /// folder. Not bound to any task — a job belongs to none.
    private func resumeJob(id: String, session: String, place: String, skip: Bool, focus: Bool) async -> (Any?, String?) {
        guard let job = JobsController.shared.store.load(id) else { return (nil, L("No such job", "没有这个任务")) }
        guard session.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                            options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        guard let claude = await claudePath() else { return (nil, L("can't find the claude command", "找不到 claude 命令")) }
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
            return (nil, L("no such directory: \(dir)", "没有这个目录：\(dir)"))
        }
        guard let claude = await claudePath() else { return (nil, L("can't find the claude command", "找不到 claude 命令")) }
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
                return (nil, L("Orca is not installed", "没有安装 Orca"))
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
            // iTerm2 comes to the front on its own when it makes a window or tab (and when it has
            // to launch), even without `activate`; in the background, the app that was in front
            // — the board — is brought back.
            let before = NSWorkspace.shared.frontmostApplication
            let r = await Self.run("/usr/bin/osascript", ["-e", script])
            if !focus, let before { await Self.keepInFront(before) }
            return r.status == 0 ? (["ok": true], nil) : (nil, "\(place): " + (r.err.isEmpty ? r.out : r.err).prefix(300))
        default:
            return (nil, L("unknown place to open: \(place)", "不知道要在哪里打开：\(place)"))
        }
    }

    private static let terminalBundleIDs: Set<String> = ["com.googlecode.iterm2", TerminalJump.terminalAppBundleID]

    /// Puts `app` back in front whenever iTerm2 or Terminal takes the front during the next
    /// `seconds` — a terminal can activate itself after osascript has returned (while it
    /// launches, or once its new window is up). Only a terminal is pushed back: once the user
    /// switches to any other app, the watch ends and that app is left alone.
    private static func keepInFront(_ app: NSRunningApplication, seconds: Double = 1.5) async {
        let end = Date().addingTimeInterval(seconds)
        var lastTry = Date.distantPast
        while true {
            if let front = NSWorkspace.shared.frontmostApplication, front != app {
                guard let id = front.bundleIdentifier, terminalBundleIDs.contains(id) else { return }
                // Activation takes a moment to show in frontmostApplication; don't ask again
                // on every tick while the first request is still landing.
                if Date().timeIntervalSince(lastTry) >= 0.3 {
                    bringBack(app)
                    lastTry = Date()
                }
            }
            if Date() >= end { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Activates `app`. The pet itself is an accessory app asking from the background, where a
    /// plain `activate()` is only a request that macOS 14+ often refuses — so it insists, and
    /// orders the board window front regardless (as BoardWindow.present does).
    private static func bringBack(_ app: NSRunningApplication) {
        guard app.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            app.activate()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let board = NSApp.windows.first(where: { $0 is BoardWindow && $0.isVisible }) {
            board.orderFrontRegardless()
            board.makeKey()
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
            guard !cwd.isEmpty else { return (nil, L("relative path and no working directory", "是相对路径，但没有工作目录")) }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return (nil, L("not found: \(url.path)", "找不到：\(url.path)"))
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

    /// The secretary, running hq the way the board does.
    private var secretary: SecretaryController {
        let s = SecretaryController.shared
        if s.hq == nil {
            s.hq = { [weak self] args in
                guard let self else { return (nil, "closed") }
                let r = await self.hq(args)
                return (r.0 as? String, r.1)
            }
        }
        return s
    }

    private var hqPath: String {
        // HQ_BIN: a worktree's hq for `--render-board` while developing; the installed one otherwise.
        if let dev = ProcessInfo.processInfo.environment["HQ_BIN"], !dev.isEmpty { return dev }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/hq/bin/hq").path
    }

    /// Runs hq and hands its stdout back as text; the page parses JSON itself.
    private func hq(_ args: [String]) async -> (Any?, String?) {
        guard FileManager.default.isExecutableFile(atPath: hqPath) else {
            return (nil, L("HQ is not installed — run hq/install.sh --root <dir>", "没有安装 HQ — 运行 hq/install.sh --root <dir>"))
        }
        let r = await Self.run(hqPath, args)
        if r.status != 0 {
            return (nil, r.err.isEmpty ? L("hq exited \(r.status)", "hq 退出码 \(r.status)") : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
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
        guard !text.isEmpty else { return (nil, L("empty message", "消息是空的")) }
        guard let t = terminal(of: session) else {
            if !bg.isEmpty { return await sendBackground(session: session, bgId: bg, text: text, busy: queue, skip: skip) }
            return (nil, L("no terminal recorded for this session", "没有记录这个 session 的终端"))
        }
        // Typing into a tab whose session has ended would hand the message to the shell as a
        // command. The board's list can be seconds old, so check the process itself.
        if let pid = Self.recordedPid(session) {
            guard ProcessProbe.isClaude(pid: pid),
                  SessionControl.processIsSession(session, sessionsFile: try? Data(contentsOf:
                      FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions/\(pid).json")),
                                                  arguments: ProcessProbe.arguments(pid: pid))
            else { return (nil, L("that session is not running any more — Resume it first", "这个 session 已经不在运行了 — 先 Resume 它")) }
        }
        // A permission prompt or a question menu takes typed keys as its answer: the Return would
        // pick the highlighted option ("Yes") for something the user has not seen. The board
        // disables Send for such a session; this is the backstop for a list seconds old.
        if BoardSend.refuses(state: Self.currentState(session)) {
            return (nil, L("it is waiting on a prompt in its terminal — answer it there (Jump) first",
                           "它在终端里等你确认或回答 — 先去那里（跳转）处理"))
        }
        switch t.kind {
        case "terminal":
            guard TerminalTarget.isSafeTTYPath(t.handle) else { return (nil, L("unexpected Terminal tty", "Terminal 的 tty 不对劲")) }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: TerminalJump.terminalAppBundleID).isEmpty
            else { return (nil, L("Terminal is not running", "Terminal 没有在运行")) }
            // Terminal.app types `do script` text into the tab as if from the keyboard: one line,
            // with no control characters, as a bracketed paste followed by the Return key
            // (IdleTab.terminalTypeScript).
            let typed = BoardSend.typeable(text)
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, L("empty message", "消息是空的")) }
            let before = Self.lastPromptAt(session)
            let r = await Self.run("/usr/bin/osascript", ["-e", IdleTab.terminalTypeScript(tty: t.handle, text: typed)])
            guard r.status == 0, r.out.contains("ok") else {
                return (nil, r.out.contains("notfound") ? L("its Terminal tab is gone", "它的 Terminal 标签页已经没了") :
                        "Terminal: " + (r.err.isEmpty ? r.out : r.err).prefix(200))
            }
            if queue { return (["ok": true, "queued": true], nil) }
            if !BoardSend.startsTurn(typed) { return (["ok": true], nil) }
            if await Self.turnStarted(session, since: before) { return (["ok": true], nil) }
            if Self.currentState(session) == .busy { return (["ok": true, "queued": true], nil) }
            return (nil, L("typed into its Terminal tab, but no turn started — check the tab and press Return there", "已经输入到它的 Terminal 标签页，但没有开始新一轮 — 去那个标签页看看，在那里按回车"))
        case "orca":
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orcaBundleID) else {
                return (nil, L("Orca is not installed", "没有安装 Orca"))
            }
            let cli = app.appending(path: "Contents/Resources/bin/orca").path
            let r = await Self.run(cli, ["terminal", "send", "--terminal", t.handle, "--text", text,
                                         "--enter", "--json"] + (queue ? [] : ["--wait-submit", "5"]))
            return r.status == 0 ? (["ok": true, "queued": queue, "detail": r.out], nil)
                                 : (nil, "orca: \(r.err.isEmpty ? r.out : r.err)".prefix(300).description)
        case "iterm2":
            let uuid = TerminalTarget.iTermUUID(from: t.handle)
            guard TerminalTarget.isSafeITermUUID(uuid) else { return (nil, L("unexpected iTerm2 session id", "iTerm2 session id 不对劲")) }
            // One line, with no control characters. The text and its Return go in separately:
            // arriving together, Claude Code takes them as one paste and the Return becomes a
            // newline in its input instead of submitting it (TerminalTarget.iTermTypeScript).
            let typed = BoardSend.typeable(text)
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, L("empty message", "消息是空的")) }
            let before = Self.lastPromptAt(session)
            let r = await Self.run("/usr/bin/osascript", ["-e", TerminalTarget.iTermTypeScript(uuid: uuid, text: typed)])
            guard r.status == 0, r.out.contains("ok") else {
                return (nil, r.out.contains("notfound") ? L("iTerm2 session not found", "找不到 iTerm2 session") :
                        "iTerm2: " + (r.err.isEmpty ? r.out : r.err).prefix(200))
            }
            if queue { return (["ok": true, "queued": true], nil) }
            if !BoardSend.startsTurn(typed) { return (["ok": true], nil) }
            if await Self.turnStarted(session, since: before) { return (["ok": true], nil) }
            if Self.currentState(session) == .busy { return (["ok": true, "queued": true], nil) }
            return (nil, L("typed into its iTerm2 session, but no turn started — check it and press Return there", "已经输入到它的 iTerm2 session，但没有开始新一轮 — 去那里看看，在那里按回车"))
        default:
            return (nil, L("sending to \(t.kind) terminals is not supported yet — use Jump", "还不支持给 \(t.kind) 终端发消息 — 请用跳转"))
        }
    }

    /// The Claude Code process the pet recorded for the session, if it recorded one.
    private static func recordedPid(_ session: String) -> Int32? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet/sessions/\(session).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 1 else { return nil }
        return pid
    }

    /// Like Orca's --wait-submit: watches up to 5 s for the session to take a new prompt.
    private static func turnStarted(_ session: String, since before: String) async -> Bool {
        for _ in 0..<25 {
            if lastPromptAt(session) != before { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// The session's state as the pet shows it now. A recorded wait that has since been approved,
    /// or that Claude Code has closed, counts as what it became — a stale "waiting" in the file
    /// must not lock the board out of a session that has moved on. Nil when nothing is recorded.
    /// After a send, busy with no new prompt means the message went into Claude Code's queue
    /// behind a turn the board did not know had started.
    private static func currentState(_ session: String) -> SessionActivity? {
        guard !session.isEmpty, !session.contains("/"),
              let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                  .appending(path: ".claude/pet/sessions/\(session).json")),
              let s = SessionState.decode(from: data) else { return nil }
        if StateAggregator.wasApproved(s) { return .busy }
        return (StateAggregator.waitEnded(s) ?? s).state
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
              bgId.range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression) != nil else { return (nil, L("not a session id", "不是有效的 session id")) }
        if busy { return (nil, L("it is busy — try again when its turn ends", "它正忙 — 等这一轮结束再试")) }
        guard let claude = await claudePath() else { return (nil, L("can't find the claude command", "找不到 claude 命令")) }
        func listing() async -> SessionControl.Listing {
            let list = await Self.run(claude, ["agents", "--json"])
            return SessionControl.listing(exitStatus: list.status, output: list.out, session: session)
        }
        // Resuming a session that is still running starts a second copy of it, so "can't tell"
        // is never read as "not running".
        switch await listing() {
        case .unknown:
            return (nil, L("couldn't check whether it is running (claude agents failed) — try again", "没法确认它是否在运行（claude agents 失败）— 请再试一次"))
        case .absent:
            break
        case .running(let st):
            guard SessionControl.betweenTurns(st) else {
                return (nil, st == "waiting" ? L("it is waiting on a prompt in its turn — Attach to answer it", "它在等一个确认或回答，这一轮还没结束 — 用 Attach 去回答")
                                             : L("it is busy — try again when its turn ends", "它正忙 — 等这一轮结束再试"))
            }
            _ = await Self.run(claude, ["stop", bgId])
            var stopped = false
            for _ in 0..<25 {
                if await listing() == .absent { stopped = true; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if !stopped { return (nil, L("it did not stop to take the message — Attach to talk to it", "它没有停下来接收消息 — 用 Attach 和它对话")) }
        }
        var dir = Self.sessionCwd(session)
        if dir == nil {   // a background session the pet never saw: `claude agents` knows its folder
            let all = await Self.run(claude, ["agents", "--json", "--all"])
            if let data = all.out.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let cwd = rows.first(where: { ($0["sessionId"] as? String) == session })?["cwd"] as? String,
               FileManager.default.fileExists(atPath: cwd) { dir = cwd }
        }
        guard let dir else { return (nil, L("can't tell which folder that session ran in", "不知道那个 session 是在哪个文件夹运行的")) }
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

    /// Runs a tool to the end. With a `timeout`, a tool still running then is ended (SIGTERM,
    /// then SIGKILL a second later) and answers whatever it printed, with its signal status.
    private nonisolated static func run(_ tool: String, _ args: [String], cwd: String? = nil,
                                        timeout: TimeInterval? = nil) async -> Result {
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
                    if let timeout {
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                            guard p.isRunning else { return }
                            p.terminate()
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                            }
                        }
                    }
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
