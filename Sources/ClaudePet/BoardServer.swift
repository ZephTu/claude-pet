import AppKit
import ClaudePetCore
import CoreImage
import Foundation
import Network
import SystemConfiguration
import WebKit

/// How the board starts sessions — skip permissions, where they open — kept by the app rather than
/// in one page's storage, so the Mac's board and every phone's start them the same way.
@MainActor
enum BoardPrefs {
    /// The page's own storage keys; the values are the strings it stores ("1"/"0", "orca"…).
    static let keys = ["hq-skip-perms", "hq-launch"]
    private static let defaultsKey = "boardSharedPrefs"

    static var current: [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func save(_ prefs: [String: Any]) {
        var all = current
        for k in keys { if let v = prefs[k] as? String { all[k] = String(v.prefix(40)) } }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    static var skip: Bool? { current["hq-skip-perms"].map { $0 == "1" } }
}

/// Phone access: the board, served over the local network to a paired phone's browser.
///
/// The same pages the Mac's window shows, from the same files, and the same operations: a phone's
/// `POST /api` goes to BoardBridge.handle as the window's messages do. What only the Mac may do
/// (pair more phones, a folder picker) is refused — see RemoteAccess. Off until turned on in the
/// board's settings; then it listens on every interface, answers only private addresses, and
/// runs nothing for a request without a paired phone's token.
@MainActor
final class BoardServer {
    static let shared = BoardServer()
    private static let enabledKey = "boardServerEnabled"
    private static let portKey = "boardServerPort"
    private static let devicesKey = "boardServerDevices"

    private var listener: NWListener?
    private let bridge = BoardBridge()
    private var lastError: String?
    /// Wrong tokens by address: how many, and since when.
    private var failures: [String: (count: Int, since: Date)] = [:]
    private var root: URL? { Bundle.module.url(forResource: "pet", withExtension: nil)?.standardizedFileURL }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// `--serve-board`: a port of its own, so a development copy runs beside the installed pet.
    private var portOverride: UInt16?
    var port: UInt16 {
        if let portOverride { return portOverride }
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(p) ? UInt16(p) : RemoteAccess.defaultPort
    }

    func startIfEnabled() { if enabled { start() } }

    func setEnabled(_ on: Bool) -> (Any?, String?) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
        return (status(), nil)
    }

    private func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .failed(let error) = state {
                        self.lastError = Self.describe(error)
                        NSLog("ClaudePet: phone access stopped — \(error)")
                        self.listener?.cancel()
                        self.listener = nil
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// `ClaudePet --serve-board PORT`: the server alone, for development — prints a pairing link.
    func serveForDevelopment(port: UInt16) {
        portOverride = port
        start()
        if let e = lastError { print("serve-board: \(e)"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let url = (pair().0 as? [String: Any])?["url"] as? String else { print("serve-board: failed"); exit(1) }
            print(url.replacingOccurrences(of: baseURLs().first ?? "", with: "http://localhost:\(port)"))
            fflush(stdout)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        lastError = nil
    }

    private static func describe(_ error: Error) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return L("the port is taken by another program", "端口被别的程序占用了")
        }
        return error.localizedDescription
    }

    // MARK: - Paired phones

    private var devices: [RemoteAccess.Device] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.devicesKey) else { return [] }
            return (try? JSONDecoder().decode([RemoteAccess.Device].self, from: data)) ?? []
        }
        set {
            let live = RemoteAccess.live(newValue, now: Date())
            UserDefaults.standard.set(try? JSONEncoder().encode(live), forKey: Self.devicesKey)
        }
    }

    /// A pairing code for one more phone: the address to open, with a fresh token after `#` (a
    /// fragment never leaves the phone's browser — not in a request, not in a log), and the same
    /// as a QR code to scan. The token is kept only as its hash.
    func pair() -> (Any?, String?) {
        guard listener != nil else { return (nil, L("turn phone access on first", "先打开手机访问")) }
        let token = RemoteAccess.newToken()
        var all = RemoteAccess.live(devices, now: Date())
        all.append(RemoteAccess.Device(id: UUID().uuidString.prefix(8).lowercased(), name: L("New phone", "新手机"),
                                       hash: RemoteAccess.hash(token), created: Date()))
        devices = all
        let url = "\(baseURLs().first ?? "http://localhost:\(port)")/board/board.html#pair=\(token)"
        return (["url": url, "qr": Self.qrCode(url) ?? ""], nil)
    }

    func revoke(_ id: String) -> (Any?, String?) {
        devices = devices.filter { $0.id != id }
        return (status(), nil)
    }

    func status() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = RemoteAccess.live(devices, now: Date()).map { d in
            var o: [String: Any] = ["id": d.id, "name": d.name, "paired": d.paired != nil]
            if let s = d.lastSeen { o["lastSeen"] = iso.string(from: s) }
            if let a = d.lastAddress { o["lastAddress"] = a }
            return o
        }
        var o: [String: Any] = ["enabled": enabled, "running": listener != nil, "port": Int(port),
                                "urls": baseURLs(), "devices": list]
        if let e = lastError { o["error"] = e }
        return o
    }

    /// How a phone reaches this Mac: its Bonjour name (stays the same when the router hands out
    /// another address), then each private IPv4 address it has.
    private func baseURLs() -> [String] {
        var hosts: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { hosts.append("\(name).local") }
        hosts += Self.addresses()
        return hosts.map { "http://\($0):\(port)" }
    }

    private static func addresses() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let bytes = withUnsafeBytes(of: addr.s_addr) { Array($0) }
            // Private ones only: a phone on this network can reach those; and not 169.254 (no DHCP).
            guard RemoteAccess.isLocal(bytes), bytes[0] != 169, bytes[0] != 127 else { continue }
            let s = bytes.map(String.init).joined(separator: ".")
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    private static func qrCode(_ text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSBitmapImageRep(ciImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: - Connections

    private func accept(_ conn: NWConnection) {
        // Turned away before a byte is read: a peer outside the local network.
        guard let address = Self.peerBytes(conn.endpoint), RemoteAccess.isLocal(address) else {
            conn.cancel()
            return
        }
        let c = Connection(conn: conn, peer: Self.peerName(conn.endpoint)) { [weak self] req, peer in
            await self?.respond(to: req, from: peer) ?? RemoteAccess.response(status: 500, type: "text/plain", body: Data())
        }
        c.start()
    }

    private static func peerBytes(_ endpoint: NWEndpoint) -> [UInt8]? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return Array(a.rawValue)
        case .ipv6(let a): return Array(a.rawValue)
        default: return nil
        }
    }

    private static func peerName(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "?" }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".replacingOccurrences(of: "::ffff:", with: "")
        default: return "\(host)"
        }
    }

    private func respond(to req: RemoteAccess.Request, from peer: String) async -> Data {
        let names = [(SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""].filter { !$0.isEmpty }
        guard RemoteAccess.hostAllowed(req.headers["host"], names: names) else {
            return text(403, "This address can't be used for the board.")
        }
        if req.path == "/api" {
            guard req.method == "POST" else { return text(405, "POST only") }
            return await api(req, from: peer)
        }
        guard req.method == "GET" || req.method == "HEAD" else { return text(405, "GET only") }
        if req.path == "/" || req.path == "/board" || req.path == "/board/" {
            return RemoteAccess.response(status: 302, type: "text/plain", body: Data(),
                                         extra: ["Location": "/board/board.html"])
        }
        if req.path == "/manifest.webmanifest" { return manifest() }
        return file(req.path)
    }

    private func text(_ status: Int, _ s: String) -> Data {
        RemoteAccess.response(status: status, type: "text/plain; charset=utf-8", body: Data(s.utf8))
    }

    private func json(_ status: Int, _ obj: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return RemoteAccess.response(status: status, type: "application/json", body: data)
    }

    /// The pet's own files (the board, the guide, the skin pictures), as the Mac's window loads
    /// them over pet:// — with the language and "remote" set at the top of each page.
    private func file(_ rawPath: String) -> Data {
        guard let root else { return text(404, "not found") }
        let relative = rawPath.removingPercentEncoding ?? rawPath
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else {
            return text(404, "not found")
        }
        let type = PetSchemeHandler.mimeType(for: url)
        guard url.pathExtension == "html" else { return RemoteAccess.response(status: 200, type: type, body: data) }
        let skin = BoardWindow.currentSkin()
        let tags = """
        <script>\(UILanguage.pageScript) window.HQ_REMOTE = true;</script>
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="theme-color" content="#23201d">
        <link rel="manifest" href="/manifest.webmanifest">
        <link rel="apple-touch-icon" href="/skins/\(skin)/assets/idle.png">
        """
        // A phone zooms into a text box whose type is smaller than 16px, and stays zoomed: the
        // page's scale is held at 1 instead (pinching still zooms). Full screen under the notch.
        let html = RemoteAccess.inject(tags, into: String(decoding: data, as: UTF8.self))
            .replacingOccurrences(of: #"content="width=device-width, initial-scale=1""#,
                                  with: #"content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover""#)
        return RemoteAccess.response(status: 200, type: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    /// What "Add to Home Screen" makes of it: an app of its own, full screen, named HQ.
    private func manifest() -> Data {
        let skin = BoardWindow.currentSkin()
        let m: [String: Any] = ["name": "HQ", "short_name": "HQ", "start_url": "/board/board.html",
                                "display": "standalone", "background_color": "#23201d", "theme_color": "#23201d",
                                "icons": [["src": "/skins/\(skin)/assets/idle.png", "sizes": "any", "type": "image/png"]]]
        let data = (try? JSONSerialization.data(withJSONObject: m)) ?? Data()
        return RemoteAccess.response(status: 200, type: "application/manifest+json", body: data)
    }

    /// `POST /api` with `{op, …}`: answered `{result}` or `{error}`, as the window's messages are.
    private func api(_ req: RemoteAccess.Request, from peer: String) async -> Data {
        guard RemoteAccess.originAllowed(req.headers["origin"], host: req.headers["host"]) else {
            return text(403, "cross-origin request refused")
        }
        let now = Date()
        if let f = failures[peer], f.count >= RemoteAccess.maxFailures {
            if now.timeIntervalSince(f.since) < RemoteAccess.lockout {
                return json(429, ["error": L("Too many wrong tokens from this address — try again in 10 minutes",
                                             "这个地址试错 token 的次数太多——10 分钟后再试")])
            }
            failures[peer] = nil
        }
        var all = devices
        guard let i = RemoteAccess.match(req.headers[RemoteAccess.tokenHeader], in: all, now: now) else {
            let f = failures[peer]
            failures[peer] = (count: (f?.count ?? 0) + 1, since: f?.since ?? now)
            return json(401, ["error": L("This phone isn't paired, or was removed — pair it again from the Mac's board: Settings → Phone access",
                                         "这台手机还没配对，或已被移除——到 Mac 上的看板「设置 → 手机访问」重新配对"),
                              "pair": true])
        }
        failures[peer] = nil
        if all[i].paired == nil {
            all[i].paired = now
            all[i].name = RemoteAccess.deviceName(given: req.headers[RemoteAccess.deviceHeader]?.removingPercentEncoding,
                                                  userAgent: req.headers["user-agent"])
        }
        // Written at most once a minute: the board asks every few seconds.
        if all[i].lastSeen.map({ now.timeIntervalSince($0) > 60 }) ?? true || all[i].lastAddress != peer {
            all[i].lastSeen = now
            all[i].lastAddress = peer
            devices = all
        }
        guard var body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let op = body["op"] as? String else { return json(400, ["error": "bad request"]) }
        guard RemoteAccess.allowed(op: op) else {
            return json(200, ["error": L("Only on the Mac", "只能在 Mac 上做")])
        }
        // Sessions start the way the Mac's board starts them (one shared choice, BoardPrefs).
        if ["launch", "resume", "job-resume", "send"].contains(op), body["skip"] != nil, let skip = BoardPrefs.skip {
            body["skip"] = skip
        }
        let (result, error) = await bridge.handle(body)
        if let error { return json(200, ["error": error]) }
        return json(200, ["result": result ?? NSNull()])
    }
}

/// One request on one connection: read it whole, answer, close.
@MainActor
private final class Connection {
    private let conn: NWConnection
    private let peer: String
    private let handler: (RemoteAccess.Request, String) async -> Data
    private var buffer = Data()
    private var done = false

    init(conn: NWConnection, peer: String, handler: @escaping (RemoteAccess.Request, String) async -> Data) {
        self.conn = conn
        self.peer = peer
        self.handler = handler
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: done = true
                default: break
                }
            }
        }
        conn.start(queue: .main)
        // A request that never finishes arriving doesn't hold the connection forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in
            if !done { conn.cancel() }
        }
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                if let data { buffer.append(data) }
                switch RemoteAccess.parse(buffer) {
                case .request(let req):
                    Task { @MainActor in
                        var out = await handler(req, peer)
                        if req.method == "HEAD", let end = out.range(of: Data("\r\n\r\n".utf8)) {
                            out = out.subdata(in: out.startIndex..<end.upperBound)
                        }
                        send(out)
                    }
                case .reject(let status):
                    send(RemoteAccess.response(status: status, type: "text/plain", body: Data()))
                case .incomplete:
                    if isComplete || error != nil { finish() } else { receive() }
                }
            }
        }
    }

    private func send(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { [self] _ in
            MainActor.assumeIsolated { finish() }
        })
    }

    private func finish() {
        done = true
        conn.cancel()
    }
}

/// `--render-url`: a web page snapshotted in a plain web view, with no bridge to the app — how a
/// phone's browser sees the board BoardServer serves. Development only.
@MainActor
enum PageShot {
    private static var keep: [AnyObject] = []

    static func render(url: String, to path: String, script: String, size: NSSize, done: @escaping @MainActor (Bool) -> Void) {
        guard let u = URL(string: url) else { return done(false) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        keep = [view, window]
        view.load(URLRequest(url: u))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            view.evaluateJavaScript(script.isEmpty ? "null" : script) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    view.takeSnapshot(with: nil) { image, _ in
                        MainActor.assumeIsolated {
                            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                                  let png = rep.representation(using: .png, properties: [:]) else { return done(false) }
                            done((try? png.write(to: URL(fileURLWithPath: path))) != nil)
                        }
                    }
                }
            }
        }
    }
}
