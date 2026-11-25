import CryptoKit
import Foundation

/// Phone access to the HQ board over the local network: the parts of the pet's small web server
/// (BoardServer) that decide, without touching the network — reading a request, who may connect,
/// which phones are paired, what a phone may ask for.
///
/// The threat this is built against: a phone that holds a paired token can do everything the
/// board can — start sessions, answer permission prompts — so the token is the lock. Everything
/// else here (private addresses only, the Host and Origin checks, the lockout) keeps strangers
/// from getting as far as trying it: a router that forwards the port, a web page in the phone's
/// browser aiming at the Mac (DNS rebinding), someone guessing.
public enum RemoteAccess {
    public static let defaultPort: UInt16 = 8790
    /// Request bodies: a pasted image travels as a data URL (base64 of up to 20 MB, see saveImage).
    public static let maxBody = 32 * 1024 * 1024
    public static let maxHeader = 32 * 1024
    /// The header a phone sends its token in. A custom header, not a cookie: a page on another
    /// origin can't set it without a CORS preflight, which this server never answers.
    public static let tokenHeader = "x-hq-token"
    /// What the phone calls itself (see deviceName).
    public static let deviceHeader = "x-hq-device"
    /// How long a pairing code shown on the Mac waits for its phone.
    public static let pairWindow: TimeInterval = 15 * 60
    /// Wrong tokens from one address before it is turned away for a while.
    public static let maxFailures = 20
    public static let lockout: TimeInterval = 10 * 60
    /// Wrong tokens from anywhere while a pairing code waits: past this many, the code is
    /// cancelled. Whatever addresses someone guesses from, a code's odds stay at 100 in 2^40.
    public static let maxCodeFailures = 100

    // MARK: - Requests

    public struct Request: Equatable, Sendable {
        public var method: String
        /// Without the query string.
        public var path: String
        /// Lower-cased names.
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, headers: [String: String], body: Data) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }
    }

    public enum Parse: Equatable, Sendable {
        case incomplete
        case request(Request)
        /// The status to answer with before closing: 400, 413 or 431.
        case reject(Int)
    }

    /// A request's head, read before its body: what the server decides on before it accepts a
    /// body at all (BoardServer.admit) — a stranger doesn't get to make the pet hold megabytes.
    public enum Head: Equatable, Sendable {
        case incomplete
        /// `request.body` is empty; the body is `length` bytes from `bodyStart` (an offset into
        /// the data read).
        case head(Request, length: Int, bodyStart: Int)
        /// The status to answer with before closing: 400 or 431.
        case reject(Int)
    }

    public static func head(_ data: Data) -> Head {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeader ? .reject(431) : .incomplete
        }
        guard data.distance(from: data.startIndex, to: end.lowerBound) <= maxHeader else { return .reject(431) }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .reject(400) }
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Two different lengths: which one the body has is anyone's guess.
            if name == "content-length", let had = headers[name], had != value { return .reject(400) }
            headers[name] = value
        }
        // Chunked bodies are not something a browser sends with fetch(); refusing them keeps the
        // reader to one shape.
        if headers["transfer-encoding"] != nil { return .reject(400) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .reject(400) }
            length = n
        }
        let target = String(first[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return .head(Request(method: String(first[0]), path: path, headers: headers, body: Data()),
                     length: length, bodyStart: data.distance(from: data.startIndex, to: end.upperBound))
    }

    /// Reads one HTTP/1.1 request from the bytes received so far: a body longer than `maxBody`
    /// is refused (413) before it arrives.
    public static func parse(_ data: Data, maxBody: Int = maxBody) -> Parse {
        switch head(data) {
        case .incomplete: return .incomplete
        case .reject(let status): return .reject(status)
        case .head(var req, let length, let bodyStart):
            guard length <= maxBody else { return .reject(413) }
            guard data.count - bodyStart >= length else { return .incomplete }
            let from = data.index(data.startIndex, offsetBy: bodyStart)
            req.body = Data(data[from..<data.index(from, offsetBy: length)])
            return .request(req)
        }
    }

    /// A whole response, `Connection: close` (one request per connection keeps the reader simple;
    /// on a local network the extra connections cost nothing).
    public static func response(status: Int, type: String, body: Data, extra: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 204: "No Content", 302: "Found", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
                      429: "Too Many Requests", 431: "Request Header Fields Too Large",
                      500: "Internal Server Error"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    // MARK: - Who may connect

    /// A peer on the local network: private IPv4 (10/8, 172.16/12, 192.168/16), link-local,
    /// loopback, or the IPv6 equivalents (fc00::/7, fe80::/10, ::1, and IPv4-mapped ones).
    /// Anything else got here through a forwarded port or a tunnel: not what this is for.
    public static func isLocal(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 {
            let (a, b) = (bytes[0], bytes[1])
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254)
        }
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isLocal(Array(bytes[12..<16]))
        }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }   // ::1
        // Tailscale's addresses (fd7a:115c:a1e0::/48) are unique-local in form, but they reach
        // across the internet — as its 100.x IPv4 ones do, which the rule above already turns away.
        if bytes[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return false }
        return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }

    /// Whether `address` is in the network `net`/`mask` (same length, IPv4 or IPv6). A home network
    /// with IPv6 from the provider gives the phone a public address: it is on the Mac's own network
    /// when it shares the prefix of one of the Mac's interfaces (BoardServer.onLink).
    public static func inSubnet(_ address: [UInt8], net: [UInt8], mask: [UInt8]) -> Bool {
        guard address.count == net.count, net.count == mask.count, !mask.allSatisfy({ $0 == 0 }) else { return false }
        return zip(zip(address, net), mask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
    }

    /// What wrong tokens are counted against: the address, or for IPv6 its /64 — a phone, or
    /// anyone, gets a new IPv6 address from its /64 whenever it likes. Not for link-local ones
    /// (fe80::/64 is every device's), which count by the whole address.
    public static func lockKey(_ bytes: [UInt8]) -> String {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return lockKey(Array(bytes[12..<16]))
        }
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        if bytes.count == 16, bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return bytes.prefix(8).map { String(format: "%02x", $0) }.joined() + "/64"
    }

    /// Wrong tokens by lockKey. An address that reaches maxFailures is turned away until
    /// `lockout` has passed since its last wrong token; a count older than that starts again.
    public struct Lockout {
        struct Entry { var count: Int; var last: Date }
        private var entries: [String: Entry] = [:]

        public init() {}

        public func locked(_ key: String, now: Date) -> Bool {
            guard let e = entries[key] else { return false }
            return e.count >= RemoteAccess.maxFailures && now.timeIntervalSince(e.last) < RemoteAccess.lockout
        }

        public mutating func fail(_ key: String, now: Date) {
            // Forgotten once they no longer count, so the list doesn't grow without end.
            if entries.count > 1000 { entries = entries.filter { now.timeIntervalSince($0.value.last) < RemoteAccess.lockout } }
            var e = entries[key] ?? Entry(count: 0, last: now)
            if now.timeIntervalSince(e.last) >= RemoteAccess.lockout { e.count = 0 }
            e.count += 1
            e.last = now
            entries[key] = e
        }

        public mutating func clear(_ key: String) { entries[key] = nil }

        var count: Int { entries.count }
    }

    /// The host part of a Host header or an origin: no port, no brackets, lower-cased.
    public static func hostName(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = h.range(of: "://") { h = String(h[scheme.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if h.hasPrefix("[") {
            return h.firstIndex(of: "]").map { String(h[h.index(after: h.startIndex)..<$0]) } ?? h
        }
        if let colon = h.lastIndex(of: ":"), h.filter({ $0 == ":" }).count == 1 { h = String(h[..<colon]) }
        return h
    }

    /// The name the phone used for the Mac must be one a local network gives it: an address, a
    /// `.local` name, or the Mac's own name. A page elsewhere that points its own domain at the
    /// Mac's address (DNS rebinding) arrives under that domain, and is turned away.
    public static func hostAllowed(_ header: String?, names: [String]) -> Bool {
        guard let header, !header.isEmpty else { return false }
        let h = hostName(header)
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if names.contains(where: { $0.lowercased() == h }) { return true }
        if h.contains(":") { return h.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" } }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// A request that says where it came from must come from the page this server serves.
    public static func originAllowed(_ origin: String?, host: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }   // not a browser's cross-origin request
        guard let host else { return false }
        return hostName(origin) == hostName(host)
    }

    // MARK: - Paired phones

    public struct Device: Codable, Equatable {
        public var id: String
        /// "iPhone", "iPad"… from the browser that paired, until then "New phone".
        public var name: String
        /// SHA-256 of the token, hex: the token itself is only ever on the phone (and in the
        /// pairing code the Mac showed).
        public var hash: String
        public var created: Date
        /// nil while `hash` is a pairing code's: the code is good for one thing, claiming the
        /// phone's own token (op "pair"), and lapses after pairWindow. Set when it is claimed.
        public var paired: Date?
        public var lastSeen: Date?
        public var lastAddress: String?

        public init(id: String, name: String, hash: String, created: Date, paired: Date? = nil,
                    lastSeen: Date? = nil, lastAddress: String? = nil) {
            self.id = id
            self.name = name
            self.hash = hash
            self.created = created
            self.paired = paired
            self.lastSeen = lastSeen
            self.lastAddress = lastAddress
        }
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 random bytes, URL-safe base64: 256 bits no one guesses.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A pairing code: 8 characters to type on a phone where scanning won't do (a web app on the
    /// Home Screen has storage of its own, and the camera opens Safari). It is one use, lapses in
    /// pairWindow and shares the lockout, so 40 bits are plenty; the phone's own token is 256.
    /// Crockford's base32: no I, L, O or U to misread.
    public static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func newPairingCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in codeAlphabet[Int.random(in: 0..<codeAlphabet.count, using: &g)] })
    }

    /// As typed: case, spaces and dashes don't matter, and O, I and L read as 0, 1 and 1.
    /// nil for anything that isn't 8 code characters.
    public static func normalizeCode(_ typed: String) -> String? {
        let mapped = typed.uppercased().compactMap { c -> Character? in
            switch c {
            case " ", "-": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        }
        guard mapped.count == 8, mapped.allSatisfy(codeAlphabet.contains) else { return nil }
        return String(mapped)
    }

    /// The devices still valid: paired ones, and pairing codes not yet lapsed.
    public static func live(_ devices: [Device], now: Date) -> [Device] {
        devices.filter { $0.paired != nil || now.timeIntervalSince($0.created) < pairWindow }
    }

    /// The device a token belongs to. Compares hashes in full, whatever matches first: no early
    /// exit for a timing difference to measure.
    public static func match(_ token: String?, in devices: [Device], now: Date) -> Int? {
        guard let token, !token.isEmpty else { return nil }
        let h = Array(hash(token).utf8)
        var found: Int?
        for (i, d) in devices.enumerated() {
            let other = Array(d.hash.utf8)
            guard other.count == h.count else { continue }
            var diff: UInt8 = 0
            for k in 0..<h.count { diff |= h[k] ^ other[k] }
            if diff == 0, d.paired != nil || now.timeIntervalSince(d.created) < pairWindow { found = i }
        }
        return found
    }

    /// What to call a phone: the name its page sends (it can tell an iPad, whose Safari says
    /// "Macintosh", by its touch screen), else its browser's User-Agent.
    public static func deviceName(given: String?, userAgent: String?) -> String {
        let clean = (given ?? "").filter { $0.isLetter || $0.isNumber || " -_·'".contains($0) }
            .trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty { return String(clean.prefix(40)) }
        let ua = userAgent ?? ""
        for (key, name) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"),
                            ("Macintosh", "Mac"), ("Windows", "Windows"), ("Linux", "Linux")] where ua.contains(key) {
            return name
        }
        return "Browser"
    }

    // MARK: - What a phone may ask for

    /// Operations only the Mac's own window may run: managing phone access (a phone must not mint
    /// more tokens or undo a revoke), and a folder picker — a modal dialog on the Mac's screen,
    /// waiting for someone who isn't there.
    public static let macOnly: Set<String> = ["remote", "remote-enable", "remote-pair", "remote-revoke", "pick-folder"]

    public static func allowed(op: String) -> Bool { !macOnly.contains(op) }

    /// A phone opening its pairing link trades the code for a token of its own: the code — seen in
    /// a QR code, maybe pasted somewhere — is spent, and the token never leaves the phone.
    public static let claimOp = "pair"


    // MARK: - Pages

    /// Puts `tags` at the top of the page's head: the language and remote flags have to be set
    /// before the page's own scripts run, as the Mac's window does with a user script.
    public static func inject(_ tags: String, into html: String) -> String {
        guard let head = html.range(of: "<head>", options: .caseInsensitive) else { return tags + html }
        return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: "\n" + tags)
    }
}
