import ClaudePetCore
import Foundation

/// The `--statusline` mode: read the payload Claude Code sends a statusline,
/// keep the quota numbers, and hand everything on untouched.
///
/// Deliberately NOT installed by `--patch-settings`. A statusline command is
/// arbitrary shell the user wrote — this machine's is a `bash -c` with three
/// levels of nested quoting — and rewriting one safely, in place, without ever
/// getting it wrong is not a bet worth taking for an optional feature. The
/// README explains how to add it by hand; uninstalling the pet therefore cannot
/// break a statusline it never touched.
enum StatuslineCapture {
    /// Keeps the reading, if there is one to keep. Silent on every failure.
    static func record(_ input: Data) {
        guard let snapshot = StatuslineUsage.parse(input, now: Date()) else { return }
        let directory = HookEmit.baseDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = StatuslineUsage.encode(snapshot)
        guard !data.isEmpty else { return }
        try? data.write(to: StatuslineUsage.cacheURL(petHome: directory))
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
