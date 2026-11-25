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

    /// Reads one HTTP/1.1 request from the bytes received so far.
    public static func parse(_ data: Data, maxBody: Int = maxBody) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeader ? .reject(431) : .incomplete
        }
        guard end.lowerBound <= maxHeader else { return .reject(431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .reject(400) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Chunked bodies are not something a browser sends with fetch(); refusing them keeps the
        // reader to one shape.
        if headers["transfer-encoding"] != nil { return .reject(400) }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .reject(400) }
            length = n
        } else {
            length = 0
        }
        guard length <= maxBody else { return .reject(413) }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let target = String(first[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        return .request(Request(method: String(first[0]), path: path, headers: headers, body: body))
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
        return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
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
        /// nil until the phone first uses its token: an unused pairing code lapses (pairWindow).
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

    // MARK: - Pages

    /// Puts `tags` at the top of the page's head: the language and remote flags have to be set
    /// before the page's own scripts run, as the Mac's window does with a user script.
    public static func inject(_ tags: String, into html: String) -> String {
        guard let head = html.range(of: "<head>", options: .caseInsensitive) else { return tags + html }
        return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: "\n" + tags)
    }
}
