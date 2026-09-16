import AppKit
import ClaudePetCore
import Foundation

/// Brings the terminal tab a session is running in back to the foreground.
///
/// Two backends, picked by the `kind` that pet-emit recorded from the session's
/// own environment:
///
///  - **orca** talks to Orca's bundled CLI, which reaches Orca's runtime
///    directly. This needs no macOS Automation permission at all, and it works
///    from ClaudePet's environment, which has none of a terminal's variables
///    (verified: `env -i … orca status` still reports runtimeReachable).
///  - **iterm2** goes through AppleScript, because that is the only interface
///    iTerm2 exposes. That DOES require Automation permission: the first jump
///    raises a system prompt, and a denial is silent afterwards. Info.plist
///    carries NSAppleEventsUsageDescription, without which macOS refuses the
///    request outright instead of asking.
///
/// Every failure path is silent-but-logged on purpose. A jump that does not work
/// must never take the pet down or block the UI, and there is no good way to
/// surface an error from a borderless accessory panel.
enum TerminalJump {
    static func jump(kind: String, handle: String) {
        switch kind {
        case "orca": jumpOrca(handle: handle)
        case "iterm2": jumpITerm(sessionID: handle)
        default: NSLog("ClaudePet: unknown terminal kind \(kind)")
        }
    }

    // MARK: - Orca

    private static let orcaBundleID = "com.stablyai.orca"
    private static let iTermBundleID = "com.googlecode.iterm2"

    private static func jumpOrca(handle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: orcaBundleID) else {
            NSLog("ClaudePet: Orca is not installed")
            return
        }
        let cli = app.appending(path: "Contents/Resources/bin/orca")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            NSLog("ClaudePet: no orca CLI at \(cli.path)")
            return
        }
        run(cli, ["terminal", "switch", "--terminal", handle, "--json"]) { ok, stdout in
            guard ok, TerminalTarget.orcaSwitchSucceeded(stdout) else {
                // Usually a stale handle: the tab was closed since the hook ran.
                NSLog("ClaudePet: orca did not switch: \(stdout.prefix(200))")
                return
            }
            // Switching the tab does not raise the window; that is a separate step.
            activate(bundleID: orcaBundleID)
        }
    }

    // MARK: - iTerm2

    private static func jumpITerm(sessionID: String) {
        let uuid = TerminalTarget.iTermUUID(from: sessionID)
        guard TerminalTarget.isSafeITermUUID(uuid) else {
            NSLog("ClaudePet: refusing to script iTerm2 with a suspicious session id")
            return
        }

        // `contains` rather than `is`: iTerm2 has shipped both a bare uuid and a
        // uuid with a suffix as a session's id across versions, and a jump that
        // silently matches nothing is worse than one that matches loosely.
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (id of s as text) contains "\(uuid)" then
                  select w
                  select t
                  select s
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "notfound"
        """
        run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script]) { ok, stdout in
            // The script returns "notfound" when no session matched — that also
            // exits 0, so the tab may be gone even though osascript succeeded.
            guard ok, stdout.contains("ok") else {
                NSLog("ClaudePet: iTerm2 tab not found for this session")
                return
            }
            activate(bundleID: iTermBundleID)
        }
    }

    // MARK: - Titles

    /// Fetches handle → tab title for every live terminal we can address.
    ///
    /// Called when the user opens the session list, not on a timer: it spawns a
    /// process, and a pet nobody is looking at has no business doing that.
    ///
    /// The two backends run one after the other rather than in parallel. They
    /// could overlap, but sharing an accumulator across two completion handlers
    /// is exactly the shape Swift 6 rejects, and the whole thing happens once
    /// per panel-open — the few hundred milliseconds are not worth the ceremony.
    @MainActor
    static func fetchTitles(completion: @escaping @MainActor ([String: String]) -> Void) {
        orcaTitles { orca in
            iTermTitles { iterm in
                var merged = orca
                merged.merge(iterm) { existing, _ in existing }
                completion(merged)
            }
        }
    }

    @MainActor
    private static func orcaTitles(completion: @escaping @MainActor ([String: String]) -> Void) {
        guard
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: orcaBundleID)
        else { return completion([:]) }
        let cli = app.appending(path: "Contents/Resources/bin/orca")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            return completion([:])
        }
        run(cli, ["terminal", "list", "--json"]) { ok, stdout in
            guard ok, let data = stdout.data(using: .utf8) else { return completion([:]) }
            completion(TerminalTitles.parseOrca(data))
        }
    }

    @MainActor
    private static func iTermTitles(completion: @escaping @MainActor ([String: String]) -> Void) {
        // Only ask iTerm2 if it is already running: scripting a stopped app
        // launches it, and launching a terminal because someone opened a pet's
        // session list would be obnoxious.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).isEmpty
        else { return completion([:]) }
        run(URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", TerminalTitles.iTermListScript]) { ok, stdout in
            completion(ok ? TerminalTitles.parseITerm(stdout) : [:])
        }
    }

    // MARK: - Plumbing

    private static func activate(bundleID: String) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate(options: [])
    }

    /// Runs off the main thread: osascript against a busy terminal can take
    /// hundreds of milliseconds, and the pet must not freeze while it waits.
    /// The completion hops back to the main actor because both callers touch
    /// AppKit.
    private static func run(
        _ tool: URL,
        _ arguments: [String],
        completion: @escaping @MainActor (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            var ok = false
            var out = ""
            do {
                try process.run()
                // Read before waiting: a tool that fills the pipe buffer would
                // block forever waiting for someone to drain it.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                out = String(data: outData, encoding: .utf8) ?? ""
                ok = process.terminationStatus == 0
                if !ok {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    NSLog("ClaudePet: \(tool.lastPathComponent) exited \(process.terminationStatus): \(err.prefix(200))")
                }
            } catch {
                NSLog("ClaudePet: could not run \(tool.path): \(error.localizedDescription)")
            }
            let result = ok
            let output = out
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result, output) }
            }
        }
    }
}
