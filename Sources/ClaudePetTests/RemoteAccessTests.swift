import ClaudePetCore
import Foundation

/// Phone access (BoardServer): reading a request, who may connect, paired phones' tokens.
enum RemoteAccessTests {
    static func run(_ t: Harness) {
        print("\n-- phone access (the board over the local network)")

        func req(_ s: String) -> RemoteAccess.Parse { RemoteAccess.parse(Data(s.utf8)) }
        let post = "POST /api?x=1 HTTP/1.1\r\nHost: mac.local:8790\r\nContent-Length: 13\r\nX-HQ-Token: abc\r\n\r\n{\"op\":\"pet\"}"
        // The body is 12 bytes and Content-Length says 13: still arriving.
        t.check("a body shorter than its length is incomplete", req(post) == .incomplete)
        if case .request(let r) = req(post + " ") {
            t.check("a whole request is read: method, path without query, headers lower-cased, body",
                    r.method == "POST" && r.path == "/api" && r.headers["x-hq-token"] == "abc"
                    && r.headers["host"] == "mac.local:8790" && r.body.count == 13)
        } else {
            t.check("a whole request is read", false)
        }
        t.check("headers still arriving are incomplete", req("GET / HTTP/1.1\r\nHost: a") == .incomplete)
        t.check("a GET without a body is whole", {
            if case .request(let r) = req("GET /board/board.html HTTP/1.1\r\nHost: x\r\n\r\n") { return r.body.isEmpty }
            return false
        }())
        t.check("a body over the limit is refused (413)",
                RemoteAccess.parse(Data("POST /api HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8), maxBody: 50) == .reject(413))
        t.check("chunked bodies are refused", req("POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .reject(400))
        t.check("garbage is refused", req("hello\r\n\r\n") == .reject(400))
        t.check("endless headers are refused (431)",
                RemoteAccess.parse(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000)).utf8)) == .reject(431))
        // The head is read alone first: the server decides before taking a body.
        if case .head(let h, let length, let start) = RemoteAccess.head(Data(post.utf8)) {
            t.check("a head is read without its body: its length, and where the body starts",
                    h.path == "/api" && h.body.isEmpty && length == 13 && start == post.utf8.count - 12)
        } else {
            t.check("a head is read without its body", false)
        }
        t.check("a GET with a body, where none is allowed, is refused (413)",
                RemoteAccess.parse(Data("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8), maxBody: 0) == .reject(413))
        t.check("two different lengths are refused",
                req("POST /api HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab") == .reject(400))

        // Who may connect: the local network only.
        t.check("192.168.x, 10.x, 172.16–31.x and loopback are local",
                RemoteAccess.isLocal([192, 168, 1, 20]) && RemoteAccess.isLocal([10, 0, 0, 5])
                && RemoteAccess.isLocal([172, 20, 1, 1]) && RemoteAccess.isLocal([127, 0, 0, 1]))
        t.check("public addresses and 172.32.x are not",
                !RemoteAccess.isLocal([8, 8, 8, 8]) && !RemoteAccess.isLocal([172, 32, 0, 1])
                && !RemoteAccess.isLocal([100, 100, 1, 1]))
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 9]
        let mappedPublic: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4]
        let linkLocal: [UInt8] = [0xfe, 0x80] + Array(repeating: 0, count: 13) + [1]
        let ula: [UInt8] = [0xfd, 0x12] + Array(repeating: 0, count: 14)
        let global: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 12)
        let tailnet: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0xab, 0x12] + Array(repeating: 0, count: 7) + [9]
        t.check("Tailscale's IPv6 addresses are not local (they reach across the internet)", !RemoteAccess.isLocal(tailnet))
        let net6: [UInt8] = [0x24, 0x09, 0x89, 0x20, 0x11, 0x00, 0xab, 0xcd] + Array(repeating: 0, count: 8)
        let mask64: [UInt8] = Array(repeating: 0xff, count: 8) + Array(repeating: 0, count: 8)
        let sameNet = Array(net6.prefix(8)) + [1, 2, 3, 4, 5, 6, 7, 8]
        let otherNet = [0x24, 0x09, 0x89, 0x20, 0x11, 0x00, 0xab, 0xce] + [1, 2, 3, 4, 5, 6, 7, 8] as [UInt8]
        t.check("a public IPv6 address in the Mac's own /64 is on its network; one next door is not",
                RemoteAccess.inSubnet(sameNet, net: net6, mask: mask64) && !RemoteAccess.inSubnet(otherNet, net: net6, mask: mask64))
        t.check("a zero mask, or IPv4 against IPv6, is no network",
                !RemoteAccess.inSubnet(sameNet, net: net6, mask: Array(repeating: 0, count: 16))
                && !RemoteAccess.inSubnet([192, 168, 0, 2], net: net6, mask: mask64))
        t.check("wrong tokens count against an address, for IPv6 its /64",
                RemoteAccess.lockKey([192, 168, 0, 9]) == "192.168.0.9" && RemoteAccess.lockKey(mapped) == "192.168.0.9"
                && RemoteAccess.lockKey(sameNet) == "240989201100abcd/64"
                && RemoteAccess.lockKey(sameNet) == RemoteAccess.lockKey(Array(net6.prefix(8)) + Array(repeating: 9, count: 8)))
        var lock = RemoteAccess.Lockout()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for k in 0..<(RemoteAccess.maxFailures - 1) { lock.fail("a", now: t0.addingTimeInterval(Double(k))) }
        t.check("below the limit, an address isn't shut out", !lock.locked("a", now: t0.addingTimeInterval(30)))
        let last = t0.addingTimeInterval(500)
        lock.fail("a", now: last)
        t.check("at the limit it is, for 10 minutes from its last wrong token",
                lock.locked("a", now: last.addingTimeInterval(RemoteAccess.lockout - 1))
                && !lock.locked("a", now: last.addingTimeInterval(RemoteAccess.lockout)) && !lock.locked("b", now: last))
        lock.fail("a", now: last.addingTimeInterval(RemoteAccess.lockout + 1))
        t.check("a count older than the lockout starts again", !lock.locked("a", now: last.addingTimeInterval(RemoteAccess.lockout + 2)))
        lock.clear("a")
        t.check("a right token clears the count", !lock.locked("a", now: last))
        t.check("IPv6: mapped private, link-local, ULA and ::1 are local; global and mapped public are not",
                RemoteAccess.isLocal(mapped) && RemoteAccess.isLocal(linkLocal) && RemoteAccess.isLocal(ula)
                && RemoteAccess.isLocal(Array(repeating: 0, count: 15) + [1])
                && !RemoteAccess.isLocal(global) && !RemoteAccess.isLocal(mappedPublic))

        // The name the phone used for the Mac (DNS rebinding arrives under someone else's name).
        t.check("a .local name, an address and the Mac's own name are accepted",
                RemoteAccess.hostAllowed("Zephs-Mac.local:8790", names: [])
                && RemoteAccess.hostAllowed("192.168.0.4:8790", names: [])
                && RemoteAccess.hostAllowed("[fe80::1]:8790", names: [])
                && RemoteAccess.hostAllowed("zephs-mac:8790", names: ["Zephs-Mac"]))
        t.check("another domain, or none, is refused",
                !RemoteAccess.hostAllowed("evil.example.com:8790", names: ["Zephs-Mac"])
                && !RemoteAccess.hostAllowed("1.2.3.4.evil.com", names: []) && !RemoteAccess.hostAllowed(nil, names: []))
        t.check("an origin must be the page's own",
                RemoteAccess.originAllowed("http://mac.local:8790", host: "mac.local:8790")
                && RemoteAccess.originAllowed(nil, host: "mac.local:8790")
                && !RemoteAccess.originAllowed("http://evil.example.com", host: "mac.local:8790"))

        // Paired phones.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tok = RemoteAccess.newToken()
        t.check("a token is 43 URL-safe characters (256 bits), and new each time",
                tok.count == 43 && tok.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                && tok != RemoteAccess.newToken())
        let paired = RemoteAccess.Device(id: "a", name: "iPhone", hash: RemoteAccess.hash(tok),
                                         created: now.addingTimeInterval(-86_400), paired: now.addingTimeInterval(-86_000))
        let fresh = RemoteAccess.Device(id: "b", name: "New", hash: RemoteAccess.hash("fresh"), created: now.addingTimeInterval(-60))
        let lapsed = RemoteAccess.Device(id: "c", name: "New", hash: RemoteAccess.hash("old"), created: now.addingTimeInterval(-3_600))
        let all = [paired, fresh, lapsed]
        t.check("a paired phone's token matches it", RemoteAccess.match(tok, in: all, now: now) == 0)
        t.check("a pairing code works within its window", RemoteAccess.match("fresh", in: all, now: now) == 1)
        t.check("an unused pairing code lapses", RemoteAccess.match("old", in: all, now: now) == nil)
        t.check("a wrong or missing token matches nothing",
                RemoteAccess.match("nope", in: all, now: now) == nil && RemoteAccess.match(nil, in: all, now: now) == nil
                && RemoteAccess.match("", in: all, now: now) == nil)
        t.check("only the hash is kept", !paired.hash.contains(tok) && paired.hash.count == 64)
        t.check("lapsed codes are dropped, paired phones kept", RemoteAccess.live(all, now: now).map(\.id) == ["a", "b"])

        t.check("a phone is named by its page, else its browser",
                RemoteAccess.deviceName(given: "iPad", userAgent: "Macintosh") == "iPad"
                && RemoteAccess.deviceName(given: nil, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)") == "iPhone"
                && RemoteAccess.deviceName(given: "<script>", userAgent: nil) == "script")

        t.check("pairing more phones and the folder picker are the Mac's alone",
                !RemoteAccess.allowed(op: "remote-pair") && !RemoteAccess.allowed(op: "remote-enable")
                && !RemoteAccess.allowed(op: "pick-folder") && RemoteAccess.allowed(op: "launch")
                && RemoteAccess.allowed(op: "decide") && RemoteAccess.allowed(op: "board"))

        let page = RemoteAccess.inject("<script>x</script>", into: "<!doctype html>\n<html><head>\n<title>HQ</title>")
        t.check("the flags go first in the head", page.contains("<head>\n<script>x</script>\n<title>"))
        let resp = String(decoding: RemoteAccess.response(status: 401, type: "application/json", body: Data("{}".utf8)), as: UTF8.self)
        t.check("a response says its length, closes, and isn't cached",
                resp.hasPrefix("HTTP/1.1 401 Unauthorized\r\n") && resp.contains("Content-Length: 2\r\n")
                && resp.contains("Connection: close\r\n") && resp.contains("Cache-Control: no-store\r\n") && resp.hasSuffix("\r\n\r\n{}"))
    }
}
