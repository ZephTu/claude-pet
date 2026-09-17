import Foundation

/// One line of the connection report.
public struct HealthCheck: Sendable, Equatable {
    /// Deliberately five states rather than a boolean.
    ///
    /// "Not configured" and "needs attention" look identical to a tick-or-cross
    /// and mean opposite things: one is a feature the user never turned on, the
    /// other is something they did turn on that has stopped working. Telling a
    /// user to fix the first is how a diagnostic stops being believed.
    public enum Status: String, Sendable, Equatable {
        case ok
        case notConfigured
        case unsupported
        case needsAttention
        case unknown

        public var label: String {
            switch self {
            case .ok: return "OK"
            case .notConfigured: return "Not set up"
            case .unsupported: return "Not supported"
            case .needsAttention: return "Needs attention"
            case .unknown: return "Unknown"
            }
        }
    }

    public let name: String
    public let status: Status
    public let detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// Turns collected facts into a report the user can act on.
///
/// Pure: the host layer finds out what is true, this decides what it means. The
/// split matters because "no events yet" and "the hooks are broken" produce the
/// same observation and need different answers.
public enum HealthReport {
    /// Beyond this with no events at all, on a machine that has sessions
    /// running, something is probably wrong rather than merely quiet.
    public static let quietTooLong: TimeInterval = 24 * 60 * 60

    public static func claudeCode(version: String, path: String) -> HealthCheck {
        guard !path.isEmpty else {
            return HealthCheck(name: "Claude Code", status: .needsAttention,
                               detail: "not found on PATH — the pet has nothing to watch")
        }
        let detail = version.isEmpty ? redact(path) : "\(version) at \(redact(path))"
        return HealthCheck(name: "Claude Code", status: .ok, detail: detail)
    }

    /// - Parameters:
    ///   - installed: how many of the pet's hooks are present in settings.json.
    ///   - expected: how many it installs.
    public static func hooks(installed: Int, expected: Int, binaryExists: Bool) -> HealthCheck {
        guard binaryExists else {
            return HealthCheck(name: "Hooks", status: .needsAttention,
                               detail: "settings.json points at pet-emit but the file is missing — reinstall")
        }
        if installed == 0 {
            return HealthCheck(name: "Hooks", status: .notConfigured,
                               detail: "none installed — run ./scripts/install.sh")
        }
        if installed < expected {
            return HealthCheck(name: "Hooks", status: .needsAttention,
                               detail: "\(installed) of \(expected) installed — reinstall to add the rest")
        }
        return HealthCheck(name: "Hooks", status: .ok, detail: "\(installed) installed")
    }

    /// Never reports "stuck". Nothing arriving means nothing arrived; whether
    /// that is a problem depends on whether anything should have.
    public static func recentEvents(lastAt: Date?, liveSessions: Int, now: Date) -> HealthCheck {
        guard let lastAt else {
            return HealthCheck(
                name: "Events", status: liveSessions > 0 ? .unknown : .notConfigured,
                detail: liveSessions > 0
                    ? "none received yet — hooks only take effect in sessions started after installing"
                    : "none received yet")
        }
        let ago = now.timeIntervalSince(lastAt)
        if ago > quietTooLong, liveSessions > 0 {
            return HealthCheck(name: "Events", status: .unknown,
                               detail: "last one \(Chatter.duration(until: now, now: lastAt)) ago, with sessions running")
        }
        return HealthCheck(name: "Events", status: .ok,
                           detail: "last one \(Chatter.duration(until: now, now: lastAt)) ago")
    }

    /// The distinction the panel cannot show: processes that exist versus
    /// sessions we have heard from.
    public static func sessions(running: Int, known: Int) -> HealthCheck {
        if running > known {
            return HealthCheck(
                name: "Sessions", status: .unknown,
                detail: "\(running) running, \(known) reporting — the rest started before the hooks did")
        }
        return HealthCheck(name: "Sessions", status: running == 0 ? .notConfigured : .ok,
                           detail: running == 0 ? "none running" : "\(known) of \(running) reporting")
    }

    public static func terminals(kinds: Set<String>, lastFailure: String) -> HealthCheck {
        if kinds.isEmpty {
            return HealthCheck(name: "Terminal jump", status: .unsupported,
                               detail: "no session is in a terminal the pet can address")
        }
        let names = kinds.sorted().joined(separator: ", ")
        guard lastFailure.isEmpty else {
            return HealthCheck(name: "Terminal jump", status: .needsAttention,
                               detail: "\(names); last attempt failed: \(lastFailure)")
        }
        return HealthCheck(name: "Terminal jump", status: .ok, detail: names)
    }

    public static func usage(source: String, capturedAt: Date?, now: Date,
                             stale: Bool) -> HealthCheck {
        guard !source.isEmpty, let capturedAt else {
            return HealthCheck(name: "Quota", status: .notConfigured,
                               detail: "no source — install claude-hud, or the statusline hook")
        }
        let age = Chatter.duration(until: now, now: capturedAt)
        return HealthCheck(name: "Quota", status: stale ? .unknown : .ok,
                           detail: stale ? "\(source), last read \(age) ago (stale)"
                                         : "\(source), read \(age) ago")
    }

    public static func stateFiles(writable: Bool, count: Int, corrupt: Int) -> HealthCheck {
        guard writable else {
            return HealthCheck(name: "State files", status: .needsAttention,
                               detail: "~/.claude/pet is not writable")
        }
        guard corrupt == 0 else {
            // Not "attention": one unreadable file is skipped and everything
            // else works. Saying it is broken would be a lie.
            return HealthCheck(name: "State files", status: .unknown,
                               detail: "\(count) files, \(corrupt) unreadable (skipped)")
        }
        return HealthCheck(name: "State files", status: .ok, detail: "\(count) files")
    }

    /// A summary the user can paste into an issue.
    ///
    /// Home directories are collapsed to `~`. Nothing here carries a command, a
    /// file inside a project, or anything read from a session — the report is
    /// about the plumbing, and a diagnostic that leaks what you were working on
    /// is one people learn not to share.
    public static func summary(_ checks: [HealthCheck]) -> String {
        checks.map { "\($0.status.label.padding(toLength: 16, withPad: " ", startingAt: 0))\($0.name): \(redact($0.detail))" }
            .joined(separator: "\n")
    }

    /// Replaces the user's home directory with `~`.
    public static func redact(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
