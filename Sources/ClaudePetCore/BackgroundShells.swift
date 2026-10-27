import Foundation

/// Commands a session left running after its turn ended.
///
/// Claude Code can run a Bash command in the background and end the turn while
/// it keeps going — a dev server, a long build, a watcher. The pet called that
/// session idle, which it is, and said nothing about the process still running
/// under it.
///
/// Read live from the process table rather than from the Stop payload's
/// `background_tasks`: that list is a snapshot of the moment the turn ended,
/// and nothing fires when the command later exits, so it would go on claiming
/// a server that stopped an hour ago. A Bash tool call is a child shell of the
/// Claude process for exactly as long as the command runs — see
/// `ProcessProbe.isToolShell` — so asking the kernel is both cheap and current.
public enum BackgroundShells {
    public struct Shell: Sendable, Equatable {
        /// The command cut down by the same rule as the activity log:
        /// `npm run dev`, `curl …` — never a value that could be a secret.
        public let command: String
        public let since: Date

        public init(command: String, since: Date) {
            self.command = command
            self.since = since
        }
    }

    /// Commands running under Claude Code process `pid`, oldest first.
    ///
    /// Only meaningful for a session that is idle: while a turn is running, its
    /// foreground Bash call is a shell of exactly the same shape.
    public static func running(under pid: Int32) -> [Shell] {
        ProcessProbe.childPIDs(of: pid).compactMap { child in
            guard let arguments = ProcessProbe.arguments(pid: child),
                  ProcessProbe.isToolShell(arguments: arguments),
                  let raw = command(fromShellArguments: arguments),
                  let since = ProcessProbe.startTime(pid: child)
            else { return nil }
            return Shell(command: ActivitySummary.target(toolName: "Bash",
                                                         toolInput: ["command": raw]),
                         since: since)
        }
        .sorted { $0.since < $1.since }
    }

    /// The user's command out of the wrapper Claude Code runs it in:
    /// `zsh -c source <snapshot> … && eval <command> < /dev/null && pwd -P >| …`.
    ///
    /// Quoted only when it has to be: `eval 'npm run dev -- --port 3000'`, with
    /// each inner quote written `'\''`, but a plain `eval ./watch.sh` bare. Both
    /// shapes were seen on the same machine; reading only the quoted one hid
    /// every simple background script.
    public static func command(fromShellArguments arguments: String) -> String? {
        guard let open = arguments.range(of: "&& eval "),
              let close = arguments.range(of: " < /dev/null", options: .backwards,
                                          range: open.upperBound..<arguments.endIndex)
        else { return nil }
        var body = arguments[open.upperBound..<close.lowerBound]
        if body.hasPrefix("'"), body.hasSuffix("'"), body.count >= 2 {
            body = body.dropFirst().dropLast()
            let command = body.replacingOccurrences(of: #"'\''"#, with: "'")
            return command.isEmpty ? nil : command
        }
        let command = String(body)
        return command.isEmpty ? nil : command
    }

    /// "npm run dev · 12m"
    public static func line(_ shell: Shell, now: Date) -> String {
        shell.command + " · " + Chatter.duration(until: now, now: shell.since)
    }
}
