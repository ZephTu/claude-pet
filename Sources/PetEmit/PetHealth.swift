import ClaudePetCore
import Foundation

/// `pet-emit --health [--quick] [--jump-failure TEXT]`: the connection report for a shell that is
/// not the Mac app (the Windows tray's "Connection Status..."), the Mac's HealthCollector over
/// Windows' paths, judged by the same HealthReport. Prints one JSON document:
///   {"checks": [{"key", "name", "status", "label", "detail"}], "summary": "<HealthReport.summary>"}
/// With `--quick` (HealthCollector.quickProblemKeyed, cheap enough for every tray rebuild):
///   {"problem": {"key", "name", "status", "label", "detail"}}, or {} when nothing is wrong.
/// `--jump-failure` is the shell's last failed jump: the shell runs the jumps, so only it knows.
///
/// Read-only, as the Mac's: every check looks, none repairs (the state-file check writes and
/// removes one probe file). The Mac app does not use it.
enum PetHealth {
    static func run(_ arguments: [String]) -> Int32 {
        var quick = false
        var jumpFailure = ""
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--quick": quick = true
            case "--jump-failure": jumpFailure = rest.popFirst() ?? ""
            default:
                FileHandle.standardError.write(Data("usage: pet-emit --health [--quick] [--jump-failure TEXT]\n".utf8))
                return 2
            }
        }
        let doc: [String: Any]
        if quick {
            doc = quickProblem().map { ["problem": item($0.key, $0.check)] } ?? [:]
        } else {
            let checks = collect(jumpFailure: jumpFailure)
            doc = ["checks": checks.map { item($0.key, $0.check) },
                   "summary": HealthReport.summary(checks.map(\.check))]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return 1 }
        do { try FileHandle.standardOutput.write(contentsOf: json + Data("\n".utf8)) } catch { return 1 }
        return 0
    }

    static func item(_ key: String, _ c: HealthCheck) -> [String: Any] {
        ["key": key, "name": c.name, "status": c.status.rawValue, "label": c.status.label, "detail": c.detail]
    }

    /// HealthCollector.run, each check with a key that does not change with the language.
    static func collect(jumpFailure: String, now: Date = Date()) -> [(key: String, check: HealthCheck)] {
        let all = PetWatch.scan(HookEmit.sessionsDirectory)
        let live = StateAggregator.aggregate(all, now: now).sessions
        let (version, path) = claudeCode()
        let usage = UsageSources.pick(PetQuota.candidates(), now: now)
        let files = stateFiles()
        // A row offers a jump only to these, and to wt / console only with a pid (PetWatch.row).
        let kinds = Set(live.compactMap { s -> String? in
            guard let t = s.terminal, PetWatch.jumpKinds.contains(t.kind), t.kind == "orca" || s.pid != nil
            else { return nil }
            return terminalName(t.kind)
        })
        return [
            ("claudeCode", HealthReport.claudeCode(version: version, path: path)),
            ("hooks", hooks()),
            ("events", HealthReport.recentEvents(lastAt: all.map(\.updatedAt).max(),
                                                 liveSessions: live.count, now: now)),
            ("sessions", HealthReport.sessions(running: max(runningClaude(), live.count), known: live.count)),
            ("terminals", HealthReport.terminals(kinds: kinds, lastFailure: jumpFailure)),
            ("quota", HealthReport.usage(source: usage.map { $0.source.isEmpty ? L("unknown source", "来源不明") : $0.source } ?? "",
                                         capturedAt: usage?.capturedAt, now: now,
                                         stale: !(usage?.percentagesUsable(now: now) ?? false))),
            ("stateFiles", HealthReport.stateFiles(writable: files.writable, count: files.count, corrupt: files.corrupt)),
        ]
    }

    /// HealthCollector.quickProblemKeyed: only what means "the pet cannot see your sessions".
    static func quickProblem() -> (key: String, check: HealthCheck)? {
        let checks: [(key: String, check: HealthCheck)] = [
            ("hooks", hooks()),
            ("stateFiles", HealthReport.stateFiles(writable: writable(), count: 0, corrupt: 0)),
        ]
        return checks.first { $0.check.status == .needsAttention }
    }

    static func terminalName(_ kind: String) -> String {
        switch kind {
        case "orca": return "Orca"
        case "wt": return "Windows Terminal"
        case "console": return L("console window", "控制台窗口")
        default: return kind
        }
    }

    // MARK: - Hooks

    /// HealthReport.hooks over settings.json, with Windows' installer named when none is there.
    static func hooks() -> HealthCheck {
        let (installed, binaryOK) = hookState()
        if installed == 0 {
            return HealthCheck(name: "Hooks", status: .notConfigured,
                               detail: L("none installed — run install.ps1", "一个都没装 — 运行 install.ps1"))
        }
        return HealthReport.hooks(installed: installed, expected: SettingsPatch.events.count, binaryExists: binaryOK)
    }

    /// How many hook events carry the pet's command, and whether the file they run is there (in
    /// the pet's folder, as the Mac's HealthCollector looks; Git Bash finds the .exe). settings.json
    /// is where Claude Code reads it: CLAUDE_CONFIG_DIR, else ~\.claude.
    static func hookState() -> (installed: Int, binaryOK: Bool) {
        #if os(Windows)
        let binary = HookEmit.baseDirectory.appending(path: "pet-emit.exe")
        #else
        let binary = HookEmit.baseDirectory.appending(path: "pet-emit")
        #endif
        let binaryOK = FileManager.default.fileExists(atPath: binary.path)
        let claude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        guard let data = try? Data(contentsOf: claude.appending(path: "settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return (0, binaryOK) }
        let installed = hooks.values.filter { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains("pet/pet-emit") == true }
            }
        }.count
        return (installed, binaryOK)
    }

    // MARK: - State files

    static func stateFiles() -> (writable: Bool, count: Int, corrupt: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: HookEmit.sessionsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let corrupt = files.filter { url in
            guard let data = try? Data(contentsOf: url) else { return true }
            return (try? JSONSerialization.jsonObject(with: data)) == nil
        }.count
        return (writable(), files.count, corrupt)
    }

    /// Whether the pet's folder takes a file: one written and removed (isWritableFile does not
    /// read Windows' ACLs).
    static func writable() -> Bool {
        let home = HookEmit.baseDirectory
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let probe = home.appending(path: ".health-\(ProcessInfo.processInfo.processIdentifier)")
        guard (try? Data().write(to: probe)) != nil else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    // MARK: - Claude Code

    /// Claude Code's processes, one per session (ProcessProbe.claudePIDs).
    static func runningClaude() -> Int {
        #if os(Windows)
        return ProcessProbe.claudePIDs().count
        #else
        return 0
        #endif
    }

    /// Where Claude Code is (as the board's findClaude looks: PATH's claude.exe, the native binary
    /// beside npm's claude.cmd, then ~\.local\bin) and what `--version` says.
    static func claudeCode() -> (version: String, path: String) {
        let path = findClaude()
        guard !path.isEmpty else { return ("", "") }
        let version = run(path, ["--version"], timeout: 5)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return (version, shown(path))
    }

    /// A path as the report shows it: Windows' separators, the home folder as `~` (Foundation's
    /// paths here have `/`, which HealthReport.redact's home never matches).
    static func shown(_ path: String) -> String {
        #if os(Windows)
        let native = path.replacingOccurrences(of: "/", with: "\\")
        let home = FileManager.default.homeDirectoryForCurrentUser.path.replacingOccurrences(of: "/", with: "\\")
        let trimmed = home.hasSuffix("\\") ? String(home.dropLast()) : home
        guard trimmed.count > 3, let r = native.range(of: trimmed, options: [.caseInsensitive, .anchored]),
              r.upperBound == native.endIndex || native[r.upperBound] == "\\"
        else { return native }
        return "~" + native[r.upperBound...]
        #else
        return path
        #endif
    }

    static func findClaude() -> String {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let pathVar = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        #if os(Windows)
        let dirs = pathVar.split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter { !$0.isEmpty }
        for dir in dirs {
            let exe = URL(fileURLWithPath: dir).appending(path: "claude.exe").path
            if fm.fileExists(atPath: exe) { return exe }
        }
        for dir in dirs where fm.fileExists(atPath: URL(fileURLWithPath: dir).appending(path: "claude.cmd").path) {
            let exe = URL(fileURLWithPath: dir)
                .appending(path: "node_modules/@anthropic-ai/claude-code/bin/claude.exe").path
            if fm.fileExists(atPath: exe) { return exe }
        }
        let local = fm.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude.exe").path
        return fm.fileExists(atPath: local) ? local : ""
        #else
        for dir in pathVar.split(separator: ":") {
            let exe = URL(fileURLWithPath: String(dir)).appending(path: "claude").path
            if fm.isExecutableFile(atPath: exe) { return exe }
        }
        return ""
        #endif
    }

    /// A child's stdout, trimmed; "" when it cannot start or outlives `timeout` (then it is ended).
    /// Pipes for both outputs: FileHandle.nullDevice breaks a child on Windows Foundation.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return "" }
        let done = DispatchSemaphore(value: 0)
        let box = Output()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        DispatchQueue.global().async { _ = err.fileHandleForReading.readDataToEndOfFile() }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.terminate()
            return ""
        }
        task.waitUntilExit()
        return String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written by the reader before it signals, read after the wait.
    private final class Output: @unchecked Sendable { var data = Data() }
}
