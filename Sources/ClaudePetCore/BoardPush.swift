import Foundation

/// The board is told when what it shows may have changed, instead of asking every few seconds.
/// The Mac watches the files the board's reads come from (the HQ root, hq's session bindings, the
/// pet's session states); a change drops the kept reads and tells every open board — the Mac's
/// window through its web view, each phone through a stream it holds open (`/events`, written as
/// Server-Sent Events). Polling stays, slow, for what no file says (a process that died, a hold
/// that ran out) and as the way back while a stream is down.
public enum BoardPush {
    /// The reads a file change can make stale. `claude agents` is left kept: it starts a whole
    /// Claude Code, and changes only when a background session starts or ends.
    public static let staleReads: Set<String> = ["board", "sessions", "status"]

    /// Whether a change at `path` can change what the board shows. Within the watched trees:
    /// not git's own files, lock files, editors' and hq's temporary files, or the pet's files the board
    /// doesn't read (its per-tool activity log — the session's state file changes with it — the
    /// quota cache, the jump log).
    public static func relevant(_ path: String, flags: UInt32 = 0) -> Bool {
        // Events were lost, or a whole folder has to be looked at again: anything may have changed.
        if flags & (mustScanSubDirs | userDropped | kernelDropped) != 0 { return true }
        let parts = path.split(separator: "/")
        guard let name = parts.last else { return false }
        if parts.contains(".git") || parts.contains("locks") || name.hasSuffix(".lock") { return false }
        if name == ".DS_Store" || name.hasPrefix(".hq-") || name.hasPrefix(".#") || name.hasSuffix("~")
            || name.hasSuffix(".swp") || name.hasSuffix(".tmp") { return false }
        if let i = parts.lastIndex(of: "pet"), i > 0, parts[i - 1] == ".claude" {
            let under = parts[(i + 1)...]
            // The folder itself (its own times changed) says nothing; its files say what did.
            if under.isEmpty || under.first == "activity" { return false }
            if under.count == 1, ["hud-usage.json", "usage-seen.json", "jumps.jsonl", "app.lock", "pet-emit"].contains(String(name)) {
                return false
            }
        }
        return true
    }

    /// FSEvents' flags for lost events (kFSEventStreamEventFlagMustScanSubDirs, …UserDropped,
    /// …KernelDropped), spelled out so this file needs no CoreServices.
    public static let mustScanSubDirs: UInt32 = 0x01
    public static let userDropped: UInt32 = 0x02
    public static let kernelDropped: UInt32 = 0x04

    /// The head of the `/events` stream: no length, kept open until either side closes it.
    public static func streamHead() -> Data {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\nX-Accel-Buffering: no\r\n\r\n"
        return Data(head.utf8)
    }

    /// One "something changed" event; `n` counts them.
    public static func event(_ n: Int) -> Data { Data("event: changed\ndata: \(n)\n\n".utf8) }
    /// Said every `keepAlive` seconds on a quiet stream: a NAT or Tailscale's relay drops a
    /// connection that says nothing, and a phone whose stream died stops hearing it.
    public static let ping = Data(": ping\n\n".utf8)
    public static let keepAlive: TimeInterval = 25
    /// Streams held open at once; the oldest goes when another phone opens one.
    public static let maxStreams = 8
}

/// When to tell the boards: a burst of writes (a session's hooks fire in clusters, an hq save is a
/// write and a rename) becomes one push once it has gone quiet for `quiet` — or `maxWait` after its
/// first write, for one that never goes quiet — and pushes come no closer together than `gap`: a
/// busy session writes its state many times a second, and each push costs a read (`hq board` and
/// `hq sessions`, about 0.4 s of CPU). At 4 s, sessions at work cost what polling did; a change
/// after a quiet spell shows in about half a second, and quiet costs nothing.
public struct PushGate: Sendable {
    public let quiet: TimeInterval
    public let maxWait: TimeInterval
    public let gap: TimeInterval
    private var last: Date?
    /// The first change not pushed yet.
    private var first: Date?

    public init(quiet: TimeInterval = 0.3, maxWait: TimeInterval = 1.5, gap: TimeInterval = 4) {
        self.quiet = quiet
        self.maxWait = maxWait
        self.gap = gap
    }

    /// A change at `now`: when to push — the time any push already scheduled moves to.
    public mutating func note(_ now: Date) -> Date {
        let first = self.first ?? now
        self.first = first
        var at = min(now.addingTimeInterval(quiet), first.addingTimeInterval(maxWait))
        if let last, at < last.addingTimeInterval(gap) { at = last.addingTimeInterval(gap) }
        return at
    }

    /// The scheduled push went out at `now`.
    public mutating func fired(_ now: Date) {
        first = nil
        last = now
    }
}
