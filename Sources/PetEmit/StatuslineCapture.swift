import ClaudePetCore
import Foundation

/// The `--statusline` mode: read the payload Claude Code sends a statusline,
/// keep the quota numbers, and hand everything on untouched.
///
/// Deliberately NOT installed by `--patch-settings`. A statusline command is
/// arbitrary shell the user wrote — this machine's is a `bash -c` with three
/// levels of nested quoting — and rewriting one safely, in place, without ever
/// getting it wrong is not a bet worth taking for an optional feature. The
/// README explains how to add it by hand. Uninstalling removes this binary, so
/// scripts/uninstall.sh stops when the statusline still calls it.
enum StatuslineCapture {
    /// Keeps whatever this payload can tell us. Silent on every failure.
    ///
    /// Two separate things come out of one payload, and they are kept apart on
    /// purpose: the quota belongs to the ACCOUNT, the context window belongs to
    /// THIS SESSION. Mixing them would let a busy session's context read as the
    /// whole account's usage.
    static func record(_ input: Data) {
        let now = Date()
        let directory = HookEmit.baseDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let snapshot = StatuslineUsage.parse(input, now: now) {
            let data = StatuslineUsage.encode(snapshot)
            // Atomic: the app watches the folder for files landing in it (a rename), and a reader
            // must never see half a file.
            if !data.isEmpty { try? data.write(to: StatuslineUsage.cacheURL(petHome: directory), options: .atomic) }
        }

        if let insight = SessionInsights.parse(input, now: now) {
            let folder = SessionInsights.directory(petHome: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = SessionInsights.encode(insight)
            // Atomic for the same reason, and more: the app re-reads this folder only when its
            // modification time moves, which a rename does and an in-place write does not. Written
            // in place, a session's file was read once and its model and context aged out of the
            // hover card 30 minutes later however often the statusline wrote.
            if !data.isEmpty {
                try? data.write(to: folder.appending(
                    path: SessionInsights.fileName(sessionId: insight.sessionId)), options: .atomic)
            }
        }
    }

    /// Runs the user's own statusline command with the same input, forwarding
    /// its output and exit code. With no command, echoes the input's own
    /// statusline text if there is one, so a bare wrapper is still valid.
    static func forward(_ input: Data, to command: [String]) -> Int32 {
        // "--" separates our flags from theirs, the way every wrapper does it.
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        guard let executable = argv.first else { return 0 }

        let task = Process()
        let path = resolve(executable)
        task.executableURL = URL(fileURLWithPath: path)
        // Going through env means the bare name is looked up on PATH exactly as
        // the shell would have; the name has to be passed along as argv[0].
        task.arguments = path.hasSuffix("/env") ? argv : Array(argv.dropFirst())

        let stdin = Pipe()
        task.standardInput = stdin
        // stdout and stderr are inherited, so the wrapped command writes
        // straight to where Claude Code is reading. Nothing is buffered or
        // reinterpreted on the way.
        do { try task.run() } catch { return 0 }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Absolute paths are used as given; a bare name goes through the shell's
    /// PATH the same way it would have without this wrapper.
    private static func resolve(_ executable: String) -> String {
        executable.contains("/") ? executable : "/usr/bin/env"
    }
}
