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
            case .ok: return L("OK", "正常")
            case .notConfigured: return L("Not set up", "未设置")
            case .unsupported: return L("Not supported", "不支持")
            case .needsAttention: return L("Needs attention", "需要处理")
            case .unknown: return L("Unknown", "不确定")
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
                               detail: L("not found on PATH — the pet has nothing to watch",
                                         "PATH 里找不到 — 小猫没有 session 可看"))
        }
        let detail = version.isEmpty ? redact(path) : L("\(version) at \(redact(path))", "\(version)，位于 \(redact(path))")
        return HealthCheck(name: "Claude Code", status: .ok, detail: detail)
    }

    /// - Parameters:
    ///   - installed: how many of the pet's hooks are present in settings.json.
    ///   - expected: how many it installs.
    public static func hooks(installed: Int, expected: Int, binaryExists: Bool) -> HealthCheck {
        guard binaryExists else {
            return HealthCheck(name: "Hooks", status: .needsAttention,
                               detail: L("settings.json points at pet-emit but the file is missing — reinstall",
                                         "settings.json 指向 pet-emit，但这个文件不见了 — 请重新安装"))
        }
        if installed == 0 {
            return HealthCheck(name: "Hooks", status: .notConfigured,
                               detail: L("none installed — run ./scripts/install.sh", "一个都没装 — 运行 ./scripts/install.sh"))
        }
        if installed < expected {
            return HealthCheck(name: "Hooks", status: .needsAttention,
                               detail: L("\(installed) of \(expected) installed — reinstall to add the rest",
                                         "装了 \(expected) 个中的 \(installed) 个 — 重新安装补上其余的"))
        }
        return HealthCheck(name: "Hooks", status: .ok, detail: L("\(installed) installed", "已装 \(installed) 个"))
    }

    /// Never reports "stuck". Nothing arriving means nothing arrived; whether
    /// that is a problem depends on whether anything should have.
    public static func recentEvents(lastAt: Date?, liveSessions: Int, now: Date) -> HealthCheck {
        guard let lastAt else {
            return HealthCheck(
                name: L("Events", "事件"), status: liveSessions > 0 ? .unknown : .notConfigured,
                detail: liveSessions > 0
                    ? L("none received yet — hooks only take effect in sessions started after installing",
                        "还没收到 — hook 只对安装之后启动的 session 生效")
                    : L("none received yet", "还没收到"))
        }
        let ago = now.timeIntervalSince(lastAt)
        if ago > quietTooLong, liveSessions > 0 {
            return HealthCheck(name: L("Events", "事件"), status: .unknown,
                               detail: L("last one \(Chatter.duration(until: now, now: lastAt)) ago, with sessions running",
                                         "最近一次在 \(Chatter.duration(until: now, now: lastAt)) 前，而 session 都在运行"))
        }
        return HealthCheck(name: L("Events", "事件"), status: .ok,
                           detail: L("last one \(Chatter.duration(until: now, now: lastAt)) ago",
                                     "最近一次在 \(Chatter.duration(until: now, now: lastAt)) 前"))
    }

    /// The distinction the panel cannot show: processes that exist versus
    /// sessions we have heard from.
    public static func sessions(running: Int, known: Int) -> HealthCheck {
        if running > known {
            return HealthCheck(
                name: "Sessions", status: .unknown,
                detail: L("\(running) running, \(known) reporting — the rest started before the hooks did",
                          "\(running) 个在运行，\(known) 个有上报 — 其余的是在 hook 装好之前启动的"))
        }
        return HealthCheck(name: "Sessions", status: running == 0 ? .notConfigured : .ok,
                           detail: running == 0 ? L("none running", "没有在运行的")
                                                : L("\(known) of \(running) reporting", "\(running) 个中 \(known) 个有上报"))
    }

    public static func terminals(kinds: Set<String>, lastFailure: String) -> HealthCheck {
        if kinds.isEmpty {
            return HealthCheck(name: L("Terminal jump", "跳到终端"), status: .unsupported,
                               detail: L("no session is in a terminal the pet can address",
                                         "没有 session 开在小猫能跳过去的终端里"))
        }
        let names = kinds.sorted().joined(separator: ", ")
        guard lastFailure.isEmpty else {
            return HealthCheck(name: L("Terminal jump", "跳到终端"), status: .needsAttention,
                               detail: L("\(names); last attempt failed: \(lastFailure)",
                                         "\(names)；上次跳转失败：\(lastFailure)"))
        }
        return HealthCheck(name: L("Terminal jump", "跳到终端"), status: .ok, detail: names)
    }

    public static func usage(source: String, capturedAt: Date?, now: Date,
                             stale: Bool) -> HealthCheck {
        guard !source.isEmpty, let capturedAt else {
            return HealthCheck(name: L("Quota", "额度"), status: .notConfigured,
                               detail: L("no source — install claude-hud, or the statusline hook",
                                         "没有数据来源 — 装上 claude-hud，或 statusline hook"))
        }
        let age = Chatter.duration(until: now, now: capturedAt)
        return HealthCheck(name: L("Quota", "额度"), status: stale ? .unknown : .ok,
                           detail: stale ? L("\(source), last read \(age) ago (stale)", "\(source)，最后读到是 \(age) 前（已过时）")
                                         : L("\(source), read \(age) ago", "\(source)，\(age) 前读到"))
    }

    public static func stateFiles(writable: Bool, count: Int, corrupt: Int) -> HealthCheck {
        guard writable else {
            return HealthCheck(name: L("State files", "状态文件"), status: .needsAttention,
                               detail: L("~/.claude/pet is not writable", "~/.claude/pet 不可写"))
        }
        guard corrupt == 0 else {
            // Not "attention": one unreadable file is skipped and everything
            // else works. Saying it is broken would be a lie.
            return HealthCheck(name: L("State files", "状态文件"), status: .unknown,
                               detail: L("\(count) files, \(corrupt) unreadable (skipped)",
                                         "\(count) 个文件，\(corrupt) 个读不了（已跳过）"))
        }
        return HealthCheck(name: L("State files", "状态文件"), status: .ok, detail: L("\(count) files", "\(count) 个文件"))
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
