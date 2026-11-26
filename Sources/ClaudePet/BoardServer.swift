import AppKit
import ClaudePetCore
import CoreImage
import Foundation
import Network
import SystemConfiguration
import WebKit

/// How the board starts sessions — skip permissions, where they open — and what finishing a task
/// does to its live sessions, kept by the app rather than in one page's storage, so the Mac's
/// board and every phone's do the same.
@MainActor
enum BoardPrefs {
    /// The page's own storage keys; the values are the strings it stores ("1"/"0", "orca"…).
    static let keys = ["hq-skip-perms", "hq-launch", "hq-finish-stop"]
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

/// Quick phrases: replies the user sends often, offered under the board's message and answer
/// boxes. Kept by the app like BoardPrefs, so the Mac's board and every phone's share one list.
@MainActor
enum BoardPhrases {
    private static let defaultsKey = "boardQuickPhrases"

    static var current: [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }

    /// One change (QuickPhrases.apply) to the list as stored now; nil when the request makes no sense.
    static func change(action: String, text: String, at: Int?) -> [String]? {
        guard let list = QuickPhrases.apply(current, action: action, text: text, at: at) else { return nil }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        return list
    }

    /// What the user has typed to sessions again and again (Claude Code's prompt history, which
    /// holds the board's answers too), minus the phrases already kept.
    static func suggestions() async -> [[String: Any]] {
        let have = current
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/history.jsonl")
        let found = await Task.detached(priority: .utility) { () -> [QuickPhrases.Suggestion] in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            return QuickPhrases.suggest(historyLines: text.split(separator: "\n").map(String.init), have: have)
        }.value
        return found.map { ["text": $0.text, "count": $0.count] }
    }
}

/// Phone access: the board, served over the local network to a paired phone's browser — and,
/// when turned on as well, over Tailscale to the user's own devices (Tailnet).
///
/// The same pages the Mac's window shows, from the same files, and the same operations: a phone's
/// `POST /api` goes to BoardBridge.handle as the window's messages do. What only the Mac may do
/// (pair more phones, a folder picker) is refused — see RemoteAccess. Off until turned on in the
/// board's settings; then it listens on every interface, answers only private addresses (and
/// Tailscale ones of the user's own devices), and runs nothing for a request without a paired
/// phone's token.
@MainActor
final class BoardServer {
    static let shared = BoardServer()
    private static let enabledKey = "boardServerEnabled"
    private static let portKey = "boardServerPort"
    private static let devicesKey = "boardServerDevices"
    private static let tailnetKey = "boardServerTailnet"

    private var listener: NWListener?
    private let bridge = BoardBridge()
    private var lastError: String?
    private var lockout = RemoteAccess.Lockout()
    /// Wrong tokens from anywhere while a pairing code waits (RemoteAccess.maxCodeFailures).
    private var codeFailures = 0
    /// Said in Settings until the next pairing: why a code went away.
    private var notice: String?
    /// Connections open now. A phone opens a handful at once; many more is someone flooding.
    private var open = 0
    private static let maxOpen = 48
    /// Files already compressed, by ETag: the board's scripts don't change between loads.
    private var gzipped: [String: Data] = [:]
    /// Phones holding `/events` open, oldest first, with the device each was opened by.
    private var streams: [(conn: Connection, device: String)] = []
    private var pinger: Timer?
    private var watching: NSObjectProtocol?
    private var root: URL? { Bundle.module.url(forResource: "pet", withExtension: nil)?.standardizedFileURL }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    /// Also over Tailscale: off unless turned on, beside phone access itself.
    var tailnetOn: Bool { UserDefaults.standard.bool(forKey: Self.tailnetKey) }
    /// `--serve-board`: a port of its own, so a development copy runs beside the installed pet.
    private var portOverride: UInt16?
    var port: UInt16 {
        if let portOverride { return portOverride }
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(p) ? UInt16(p) : RemoteAccess.defaultPort
    }

    func startIfEnabled() {
        guard enabled else { return }
        start()
        if tailnetOn { Tailnet.shared.refresh() }
    }

    func setTailnet(_ on: Bool) async -> (Any?, String?) {
        UserDefaults.standard.set(on, forKey: Self.tailnetKey)
        // A phone's stream over Tailscale must not outlive the switch: each opens again, and is let in or not.
        if !on { closeStreams { _ in true } }
        if on { await Tailnet.shared.current(force: true) }
        return (status(), nil)
    }

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
            BoardEvents.shared.start()
            if watching == nil {
                watching = NotificationCenter.default.addObserver(forName: BoardEvents.changed, object: nil, queue: .main) { [weak self] note in
                    let n = note.userInfo?["n"] as? Int ?? 0
                    MainActor.assumeIsolated { self?.pushAll(BoardPush.event(n)) }
                }
            }
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
        closeStreams { _ in true }
    }

    // MARK: - Pushes (BoardPush)

    /// A phone opened `/events`: kept until it goes away, its device is removed, or more phones
    /// than maxStreams hold one (the oldest goes — a phone whose stream ends polls, and opens it again).
    private func opened(_ conn: Connection, device: String) {
        streams.append((conn, device))
        while streams.count > BoardPush.maxStreams { streams.removeFirst().conn.close() }
        guard pinger == nil else { return }
        pinger = Timer.scheduledTimer(withTimeInterval: BoardPush.keepAlive, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
    }

    private func streamClosed(_ conn: Connection) {
        streams.removeAll { $0.conn === conn }
        if streams.isEmpty { pinger?.invalidate(); pinger = nil }
    }

    private func pushAll(_ data: Data) {
        for s in streams { s.conn.push(data) }
    }

    /// Keeps quiet streams open, and ends those whose device is gone (removed, or expired) — and,
    /// over Tailscale, those from a device no longer the user's own (asked again as a new
    /// connection would be; Tailnet keeps each answer two minutes).
    private func ping() {
        let live = Set(RemoteAccess.live(devices, now: Date()).filter { $0.paired != nil }.map(\.id))
        closeStreams { !live.contains($0) }
        pushAll(BoardPush.ping)
        for s in streams where s.conn.peer.tailnet {
            let conn = s.conn
            Task { @MainActor [weak self] in
                let ok = await Tailnet.shared.allows(conn.peer.name)
                if !ok || self?.tailnetOn != true { conn.close() }
            }
        }
    }

    private func closeStreams(where gone: (String) -> Bool) {
        for s in streams where gone(s.device) { s.conn.close() }
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

    /// A pairing code for one more phone: the address to open, with the code after `#` (a
    /// fragment never leaves the phone's browser — not in a request, not in a log), the same as a
    /// QR code to scan, and the code alone to type. The code is kept only as its hash.
    /// `overTailnet`: the link and QR code use the Mac's Tailscale name, for a phone away from home.
    func pair(overTailnet: Bool = false) -> (Any?, String?) {
        guard listener != nil else { return (nil, L("turn phone access on first", "先打开手机访问")) }
        let base: String
        if overTailnet {
            guard tailnetOn, let url = tailnetURL() else {
                return (nil, L("Tailscale isn't ready on this Mac", "这台 Mac 上的 Tailscale 还没就绪"))
            }
            base = url
        } else {
            base = baseURLs().first ?? "http://localhost:\(port)"
        }
        let token = RemoteAccess.newPairingCode()
        // One code waits at a time: a new one cancels the last, if it went unused.
        var all = RemoteAccess.live(devices, now: Date()).filter { $0.paired != nil }
        let id = UUID().uuidString.prefix(8).lowercased()
        all.append(RemoteAccess.Device(id: id, name: L("New phone", "新手机"), hash: RemoteAccess.hash(token), created: Date()))
        devices = all
        codeFailures = 0
        notice = nil
        let url = "\(base)/board/board.html#pair=\(token)"
        let shown = "\(token.prefix(4))-\(token.suffix(4))"
        return (["url": url, "qr": Self.qrCode(url) ?? "", "code": shown, "id": id], nil)
    }

    func revoke(_ id: String) -> (Any?, String?) {
        devices = devices.filter { $0.id != id }
        closeStreams { $0 == id }
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
        if let notice { o["notice"] = notice }
        if tailnetOn {
            let t = Tailnet.shared
            t.refresh()
            var tn: [String: Any] = ["on": true]
            if let url = tailnetURL() { tn["url"] = url }
            if let login = t.me?.login { tn["login"] = login }
            if let problem = t.problem {
                tn["problem"] = problem
            } else if let me = t.me, me.running, me.login == nil {
                tn["problem"] = L("This Mac is a tagged device on its tailnet, so it has no user whose devices could be let in",
                                  "这台 Mac 在 tailnet 里是带标签的设备，没有所属用户，所以没法判断哪些是你的设备")
            }
            o["tailnet"] = tn
        } else {
            o["tailnet"] = ["on": false]
        }
        return o
    }

    /// The Mac's address over Tailscale: its MagicDNS name, the same at home and away.
    private func tailnetURL() -> String? {
        guard let me = Tailnet.shared.me, me.running, me.login != nil, let name = me.name else { return nil }
        return "http://\(name):\(port)"
    }

    /// How a phone reaches this Mac: its Bonjour name (stays the same when the router hands out
    /// another address), then each private IPv4 address it has on a real network — not a VPN's.
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
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  !Self.isTunnel(ifa) else { continue }
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
        // Turned away before a byte is read: a peer outside the local network — unless it comes
        // over Tailscale, which is turned on, from a device of this Mac's own user.
        guard let address = Self.peerBytes(conn.endpoint), open < Self.maxOpen else {
            conn.cancel()
            return
        }
        var gate: (@MainActor () async -> Bool)?
        if !(RemoteAccess.isLocal(address) || Self.onLink(address)) {
            guard tailnetOn, RemoteAccess.isTailnet(address) else {
                conn.cancel()
                return
            }
            // Started at once (the handshake waits on it), but not a byte read until Tailscale
            // says whose device it is.
            let name = Self.peerName(conn.endpoint)
            gate = { [weak self] in
                guard await Tailnet.shared.allows(name), let self else { return false }
                return self.tailnetOn && self.listener != nil
            }
        }
        open += 1
        let peer = Peer(name: Self.peerName(conn.endpoint), key: RemoteAccess.lockKey(address), tailnet: gate != nil)
        let c = Connection(conn: conn, peer: peer, gate: gate,
                           admit: { [weak self] req, peer in self?.admit(req, from: peer) ?? .refuse(Data()) },
                           handler: { [weak self] req, peer in
                               await self?.respond(to: req, from: peer)
                                   ?? .whole(RemoteAccess.response(status: 500, type: "text/plain", body: Data()))
                           },
                           streaming: { [weak self] conn, device in self?.opened(conn, device: device) },
                           closed: { [weak self] conn in
                               self?.open -= 1
                               self?.streamClosed(conn)
                           })
        c.start()
    }

    /// A VPN's interface (Tailscale, a company VPN: utun…, point-to-point, tap…, ZeroTier's feth…)
    /// or a virtual machine's network (vmenet…, bridge100…): its addresses are for the far end or
    /// the VM, not for a phone on the Wi-Fi.
    private static func isTunnel(_ ifa: ifaddrs) -> Bool {
        let name = String(cString: ifa.ifa_name)
        return (ifa.ifa_flags & UInt32(IFF_POINTOPOINT)) != 0
            || ["utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "tap", "feth", "vmenet", "bridge1"].contains(where: name.hasPrefix)
    }

    /// A peer in a network the Mac is on itself — a public IPv6 address from the home router, say.
    /// Tunnels (Tailscale, VPNs: utun…) don't count: their peers are anywhere.
    private static func onLink(_ peer: [UInt8]) -> Bool {
        let mapped = peer.count == 16 && peer[0..<10].allSatisfy { $0 == 0 } && peer[10] == 0xff && peer[11] == 0xff
        let address = mapped ? Array(peer[12..<16]) : peer
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  !isTunnel(ifa), let sa = ifa.ifa_addr, let nm = ifa.ifa_netmask else { continue }
            let net: [UInt8], mask: [UInt8]
            switch Int32(sa.pointee.sa_family) {
            case AF_INET6:
                net = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                mask = nm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
            case AF_INET:
                net = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
                mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
            default: continue
            }
            if RemoteAccess.inSubnet(address, net: net, mask: mask) { return true }
        }
        return false
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

    /// Decided on a request's head, before its body is read: everything that turns a request away
    /// without running anything — so only a paired phone gets to send a body (a pasted picture).
    fileprivate func admit(_ req: RemoteAccess.Request, from peer: Peer) -> Admit {
        var names = [(SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""].filter { !$0.isEmpty }
        // Over Tailscale: the Mac's MagicDNS name, whole or its first part.
        if tailnetOn, let name = Tailnet.shared.me?.name {
            names += [name, String(name.prefix { $0 != "." })]
        }
        guard RemoteAccess.hostAllowed(req.headers["host"], names: names) else {
            return .refuse(text(403, "This address can't be used for the board."))
        }
        guard req.path == "/api" || req.path == "/events" else {
            guard req.method == "GET" || req.method == "HEAD" else { return .refuse(text(405, "GET only")) }
            return .read(maxBody: 0)
        }
        guard req.method == "POST" else { return .refuse(text(405, "POST only")) }
        guard RemoteAccess.originAllowed(req.headers["origin"], host: req.headers["host"]) else {
            return .refuse(text(403, "cross-origin request refused"))
        }
        let now = Date()
        if lockout.locked(peer.key, now: now) {
            return .refuse(json(429, ["error": L("Too many wrong tokens from this address — try again in 10 minutes",
                                                 "这个地址试错 token 的次数太多——10 分钟后再试")]))
        }
        let all = devices
        guard RemoteAccess.match(Self.presented(req), in: all, now: now) != nil else {
            lockout.fail(peer.key, now: now)
            if RemoteAccess.live(all, now: now).contains(where: { $0.paired == nil }) {
                codeFailures += 1
                if codeFailures >= RemoteAccess.maxCodeFailures {
                    devices = all.filter { $0.paired != nil }
                    codeFailures = 0
                    notice = L("Too many wrong pairing codes were tried, so the code was cancelled — press Pair a phone for a new one",
                               "有人试了太多错误的配对码，这个码已作废——点「配对手机」重新生成")
                    NSLog("ClaudePet: phone access — pairing code cancelled after \(RemoteAccess.maxCodeFailures) wrong tries")
                }
            }
            return .refuse(unpaired())
        }
        lockout.clear(peer.key)
        return .read(maxBody: RemoteAccess.maxBody)
    }

    /// The token a request carries; a pairing code as the phone may have typed it.
    private static func presented(_ req: RemoteAccess.Request) -> String? {
        req.headers[RemoteAccess.tokenHeader].map { RemoteAccess.normalizeCode($0) ?? $0 }
    }

    private func unpaired() -> Data {
        json(401, ["error": L("This phone isn't paired, or was removed — pair it again from the Mac's board: Settings → Phone access",
                              "这台手机还没配对，或已被移除——到 Mac 上的看板「设置 → 手机访问」重新配对"),
                   "pair": true])
    }

    fileprivate func respond(to req: RemoteAccess.Request, from peer: Peer) async -> Reply {
        // admit has turned away a foreign Host, a wrong method, and an /api or /events request without a token.
        if req.path == "/api" { return .whole(await api(req, from: peer.name)) }
        if req.path == "/events" { return events(req, from: peer.name) }
        if req.path == "/" || req.path == "/board" || req.path == "/board/" {
            return .whole(RemoteAccess.response(status: 302, type: "text/plain", body: Data(),
                                                extra: ["Location": "/board/board.html"]))
        }
        if req.path == "/manifest.webmanifest" { return .whole(manifest()) }
        return .whole(file(req))
    }

    /// `POST /events`: held open, told of every change (BoardPush). POST, with the token in its
    /// header as /api has it: the page reads it with fetch, not EventSource, which can't send one.
    private func events(_ req: RemoteAccess.Request, from peer: String) -> Reply {
        var all = devices
        guard let i = RemoteAccess.match(Self.presented(req), in: all, now: Date()), all[i].paired != nil else {
            return .whole(unpaired())
        }
        if seen(&all[i], from: peer) { devices = all }
        return .stream(device: all[i].id)
    }

    /// Notes when and from where a phone last asked — written at most once a minute (the board asks
    /// every few seconds). Whether `d` changed and is to be saved.
    private func seen(_ d: inout RemoteAccess.Device, from peer: String) -> Bool {
        let now = Date()
        guard d.lastSeen.map({ now.timeIntervalSince($0) > 60 }) ?? true || d.lastAddress != peer else { return false }
        d.lastSeen = now
        d.lastAddress = peer
        return true
    }

    private func text(_ status: Int, _ s: String) -> Data {
        RemoteAccess.response(status: status, type: "text/plain; charset=utf-8", body: Data(s.utf8))
    }

    private func json(_ status: Int, _ obj: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return RemoteAccess.response(status: status, type: "application/json", body: data)
    }

    /// Compressed when the phone takes gzip and it's worth it: over a slow link the board's
    /// scripts and its data are most of the wait.
    private func encoded(_ body: Data, type: String, for req: RemoteAccess.Request, etag: String? = nil) -> Data {
        var extra: [String: String] = [:]
        if let etag { extra["ETag"] = etag }
        var body = body
        if body.count > 1024, RemoteAccess.compressible(type), RemoteAccess.acceptsGzip(req.headers["accept-encoding"]) {
            let z: Data?
            if let etag, let kept = gzipped[etag] { z = kept } else { z = RemoteAccess.gzip(body) }
            if let z, z.count < body.count {
                if let etag {
                    if gzipped.count > 64 { gzipped = [:] }
                    gzipped[etag] = z
                }
                body = z
                extra["Content-Encoding"] = "gzip"
                extra["Vary"] = "Accept-Encoding"
            }
        }
        return RemoteAccess.response(status: 200, type: type, body: body, extra: extra, cached: etag != nil)
    }

    /// The pet's own files (the board, the guide, the skin pictures), as the Mac's window loads
    /// them over pet:// — with the language and "remote" set at the top of each page.
    private func file(_ req: RemoteAccess.Request) -> Data {
        let rawPath = req.path
        guard let root else { return text(404, "not found") }
        let relative = rawPath.removingPercentEncoding ?? rawPath
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else {
            return text(404, "not found")
        }
        let type = PetSchemeHandler.mimeType(for: url)
        guard url.pathExtension == "html" else { return cachable(data, type: type, for: req) }
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
        return cachable(Data(html.utf8), type: "text/html; charset=utf-8", for: req)
    }

    /// A file the phone may keep: sent again only when it has changed (304 otherwise).
    private func cachable(_ body: Data, type: String, for req: RemoteAccess.Request) -> Data {
        let etag = RemoteAccess.etag(body)
        if RemoteAccess.unchanged(req.headers["if-none-match"], etag: etag) {
            return RemoteAccess.response(status: 304, type: type, body: Data(), extra: ["ETag": etag], cached: true)
        }
        return encoded(body, type: type, for: req, etag: etag)
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
        let now = Date()
        var all = devices
        // Matched in admit; gone since only if removed while the body arrived.
        guard let i = RemoteAccess.match(Self.presented(req), in: all, now: now) else { return unpaired() }
        guard var body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let op = body["op"] as? String else { return json(400, ["error": "bad request"]) }
        // A pairing code buys the phone its own token, once, and nothing else.
        if all[i].paired == nil {
            guard op == RemoteAccess.claimOp else { return unpaired() }
            let token = RemoteAccess.newToken()
            all[i].hash = RemoteAccess.hash(token)
            all[i].paired = now
            all[i].name = RemoteAccess.deviceName(given: req.headers[RemoteAccess.deviceHeader]?.removingPercentEncoding,
                                                  userAgent: req.headers["user-agent"])
            all[i].lastSeen = now
            all[i].lastAddress = peer
            devices = all
            return json(200, ["result": ["token": token]])
        }
        if op == RemoteAccess.claimOp { return json(200, ["error": L("This phone is paired already", "这台手机已经配对过了")]) }
        if seen(&all[i], from: peer) { devices = all }
        guard RemoteAccess.allowed(op: op) else {
            return json(200, ["error": L("Only on the Mac", "只能在 Mac 上做")])
        }
        if op == "job-save" {
            let job = body["job"] as? [String: Any] ?? [:]
            let stored = (job["id"] as? String).flatMap { JobsController.shared.store.load($0) }?.kind.rawValue
            guard RemoteAccess.phoneMaySave(job: job, storedKind: stored) else {
                return json(200, ["error": L("Shell jobs are set up on the Mac", "Shell 定时任务只能在 Mac 上设置")])
            }
        }
        // Sessions start the way the Mac's board starts them (one shared choice, BoardPrefs).
        if ["launch", "resume", "job-resume", "send"].contains(op), body["skip"] != nil, let skip = BoardPrefs.skip {
            body["skip"] = skip
        }
        let (result, error) = await bridge.handle(body)
        if let error { return json(200, ["error": error]) }
        // The board asks for the same things every few seconds, and the answer — the whole
        // board, over a megabyte — is mostly the same as last time: a phone that says which
        // version it has (its tag) is told only that nothing changed.
        let data = (try? JSONSerialization.data(withJSONObject: result ?? NSNull(), options: [.fragmentsAllowed])) ?? Data("null".utf8)
        let tag = String(RemoteAccess.etag(data).dropFirst().dropLast())   // hex, without the quotes
        if req.headers[RemoteAccess.haveHeader] == tag { return json(200, ["same": true]) }
        let whole = Data(#"{"result":"#.utf8) + data + Data(#","tag":"\#(tag)"}"#.utf8)
        return encoded(whole, type: "application/json", for: req)
    }
}

/// Who sent a request: the address to show, and what wrong tokens count against (lockKey).
private struct Peer: Sendable {
    let name: String
    let key: String
    /// Came over Tailscale: let in only while `tailscale whois` says it is the user's own device.
    var tailnet = false
}

/// What a request is answered with.
private enum Reply {
    /// A whole response, then the connection closes.
    case whole(Data)
    /// The `/events` stream's head, then the connection stays open for pushes (BoardPush).
    case stream(device: String)
}

/// What to do with a request once its head has arrived.
private enum Admit {
    /// Answer this and close, the body unread.
    case refuse(Data)
    /// Read a body of up to this many bytes, then respond.
    case read(maxBody: Int)
}

/// One request on one connection: read its head, decide whether to read the rest, answer, close —
/// or, for `/events`, keep it open and write each push to it.
@MainActor
private final class Connection {
    private let conn: NWConnection
    let peer: Peer
    private let admit: (RemoteAccess.Request, Peer) -> Admit
    private let handler: (RemoteAccess.Request, Peer) async -> Reply
    private let streaming: (Connection, String) -> Void
    private let closed: (Connection) -> Void
    /// Asked before the request is read, when there's something to ask (a Tailscale peer).
    private let gate: (@MainActor () async -> Bool)?
    private var buffer = Data()
    /// Set once the head is admitted.
    private var maxBody: Int?
    private var done = false
    private var counted = true
    /// Holding `/events` open.
    private var isStream = false

    init(conn: NWConnection, peer: Peer, gate: (@MainActor () async -> Bool)? = nil,
         admit: @escaping (RemoteAccess.Request, Peer) -> Admit,
         handler: @escaping (RemoteAccess.Request, Peer) async -> Reply,
         streaming: @escaping (Connection, String) -> Void, closed: @escaping (Connection) -> Void) {
        self.conn = conn
        self.peer = peer
        self.gate = gate
        self.admit = admit
        self.handler = handler
        self.streaming = streaming
        self.closed = closed
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: finish()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        // A request that never finishes arriving doesn't hold the connection forever (a stream is
        // held on purpose: it ends when the phone goes, or a ping can't be sent).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [self] in if !isStream { finish() } }
        guard let gate else { return receive() }
        Task { @MainActor [self] in
            let ok = await gate()
            if ok { receive() } else { finish() }
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard !done else { return }
                if let data { buffer.append(data) }
                if maxBody == nil {
                    switch RemoteAccess.head(buffer) {
                    case .incomplete:
                        return isComplete || error != nil ? finish() : receive()
                    case .reject(let status):
                        return send(RemoteAccess.response(status: status, type: "text/plain", body: Data()))
                    case .head(let req, _, _):
                        switch admit(req, peer) {
                        case .refuse(let out): return send(out)
                        case .read(let n): maxBody = n
                        }
                    }
                }
                switch RemoteAccess.parse(buffer, maxBody: maxBody ?? 0) {
                case .request(let req):
                    Task { @MainActor in
                        switch await handler(req, peer) {
                        case .whole(var out):
                            if req.method == "HEAD", let end = out.range(of: Data("\r\n\r\n".utf8)) {
                                out = out.subdata(in: out.startIndex..<end.upperBound)
                            }
                            send(out)
                        case .stream(let device):
                            openStream(device)
                        }
                    }
                case .reject(let status):
                    send(RemoteAccess.response(status: status, type: "text/plain", body: Data()))
                case .incomplete:
                    if isComplete || error != nil { finish() } else { receive() }
                }
            }
        }
    }

    /// The stream's head, then a comment long enough that a browser hands over what it has at
    /// once rather than waiting for more; then it waits for pushes, and for the phone to hang up.
    private func openStream(_ device: String) {
        guard !done else { return }
        isStream = true
        buffer = Data()
        push(BoardPush.streamHead() + Data((": " + String(repeating: " ", count: 2048) + "\n\n").utf8))
        streaming(self, device)
        drain()
    }

    /// Writes to an open stream; one that can't be written to is over.
    func push(_ data: Data) {
        guard isStream, !done else { return }
        conn.send(content: data, completion: .contentProcessed { [self] error in
            MainActor.assumeIsolated { if error != nil { finish() } }
        })
    }

    func close() { finish() }

    /// A stream's phone sends nothing more: what arrives is dropped, and its end ends the stream.
    private func drain() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [self] _, _, isComplete, error in
            MainActor.assumeIsolated {
                guard !done else { return }
                if isComplete || error != nil { finish() } else { drain() }
            }
        }
    }

    private func send(_ data: Data) {
        buffer = Data()
        conn.send(content: data, completion: .contentProcessed { [self] _ in
            MainActor.assumeIsolated { finish() }
        })
    }

    private func finish() {
        guard !done else { return }
        done = true
        buffer = Data()
        conn.cancel()
        if counted { counted = false; closed(self) }
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
