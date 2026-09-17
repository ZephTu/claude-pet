import AppKit
import ClaudePetCore

/// Finds out what is actually true about the install, so `HealthReport` can say
/// what it means.
///
/// Read-only by design. Every check here looks; none of them repairs. A
/// diagnostic that quietly rewrites settings.json is one that can turn a
/// question into an outage, and the safe installer already exists for repairs.
@MainActor
enum HealthCollector {
    struct Facts {
        var sessions: [SessionState] = []
        var lastEventAt: Date?
        var runningProcesses = 0
        var corruptStateFiles = 0
        var stateFileCount = 0
        var writable = false
        var usageSource = ""
        var usageCapturedAt: Date?
        var usageStale = true
        var lastJumpFailure = ""
    }

    static func run(petHome: URL, sessions: [SessionState], usage: UsageSnapshot?,
                    lastJumpFailure: String, now: Date = Date()) -> [HealthCheck] {
        var facts = Facts()
        facts.sessions = sessions
        facts.lastEventAt = sessions.map(\.updatedAt).max()
        facts.lastJumpFailure = lastJumpFailure

        let sessionsDir = petHome.appending(path: "sessions")
        let fm = FileManager.default
        facts.writable = fm.isWritableFile(atPath: petHome.path)
            || (try? fm.createDirectory(at: petHome, withIntermediateDirectories: true)) != nil
        if let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            let json = files.filter { $0.pathExtension == "json" }
            facts.stateFileCount = json.count
            facts.corruptStateFiles = json.filter { url in
                guard let data = try? Data(contentsOf: url) else { return true }
                return (try? JSONSerialization.jsonObject(with: data)) == nil
            }.count
        }

        if let usage {
            facts.usageSource = "claude-hud cache"
            facts.usageCapturedAt = usage.capturedAt
            facts.usageStale = !usage.percentagesUsable(now: now)
        }

        let (version, path) = claudeCodeLocation()
        let (installed, expected, binaryOK) = hookState(petHome: petHome)
        facts.runningProcesses = countClaudeProcesses()

        let kinds = Set(sessions.compactMap { $0.terminal?.kind }
            .filter { TerminalTarget.canJump(kind: $0) })

        return [
            HealthReport.claudeCode(version: version, path: path),
            HealthReport.hooks(installed: installed, expected: expected, binaryExists: binaryOK),
            HealthReport.recentEvents(lastAt: facts.lastEventAt,
                                      liveSessions: sessions.count, now: now),
            HealthReport.sessions(running: max(facts.runningProcesses, sessions.count),
                                  known: sessions.count),
            HealthReport.terminals(kinds: kinds, lastFailure: facts.lastJumpFailure),
            HealthReport.usage(source: facts.usageSource, capturedAt: facts.usageCapturedAt,
                               now: now, stale: facts.usageStale),
            HealthReport.stateFiles(writable: facts.writable, count: facts.stateFileCount,
                                    corrupt: facts.corruptStateFiles),
        ]
    }

    /// Where Claude Code is and what version it reports.
    ///
    /// Two subprocesses, run only when the user opens this window — never on a
    /// timer. `claude --version` is not free.
    private static func claudeCodeLocation() -> (version: String, path: String) {
        let path = shell("/usr/bin/which", ["claude"])
        guard !path.isEmpty else { return ("", "") }
        let version = shell(path, ["--version"])
            .split(separator: "\n").first.map(String.init) ?? ""
        return (version, path)
    }

    /// How many of the pet's hooks settings.json actually carries.
    private static func hookState(petHome: URL) -> (installed: Int, expected: Int, binaryOK: Bool) {
        let expected = 8
        let emit = petHome.appending(path: "pet-emit")
        let binaryOK = FileManager.default.isExecutableFile(atPath: emit.path)

        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
        guard
            let data = try? Data(contentsOf: settings),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return (0, expected, binaryOK) }

        var installed = 0
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let hasPet = groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains("pet/pet-emit") == true }
            }
            if hasPet { installed += 1 }
        }
        return (installed, expected, binaryOK)
    }

    private static func countClaudeProcesses() -> Int {
        let out = shell("/usr/bin/pgrep", ["-x", ProcessProbe.claudeProcessName])
        return out.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
