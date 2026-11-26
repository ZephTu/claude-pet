import Foundation

/// What the pet checks before it starts: its arguments, and that no other pet is running.
///
/// Two pets watch the same sessions, answer the same permission prompts and run the same
/// scheduled jobs. That happened in practice: `.build/debug/ClaudePet --help` started a
/// second full pet beside the installed one, because an argument nobody recognised fell
/// through to a normal launch.
public enum PetLaunch {
    /// The flags a normal (pet-starting) launch understands.
    public static let petFlags: Set<String> = ["--demo"]

    public static let usage = """
        usage: ClaudePet [--demo]
          --demo                              cycle through the pet's states
        development checks (render and exit; none of them starts a pet):
          --render-board OUT.png [JS] [--size WxH]
          --render-url URL OUT.png [JS] [--size WxH]
          --render-health OUT.png
          --serve-board PORT
          --probe-skin PATH OUT.png [JS]
          --probe-film PATH DIR FRAMES FPS [JS]
          --hq-snapshot
        """

    public enum Decision: Equatable {
        case start
        case help
        case unknown([String])
    }

    /// Reads the arguments of a launch that reached the pet itself (the development modes
    /// have returned before this). AppKit's own arguments pass: `-psn_…` from Finder on old
    /// systems, and `-Key value` pairs, which set a user default for this run.
    public static func decide(_ arguments: [String]) -> Decision {
        var unknown: [String] = []
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--help" || arg == "-h" { return .help }
            if petFlags.contains(arg) || arg.hasPrefix("-psn_") {
                i += 1
            } else if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 1 {
                i += 2  // -Key value
            } else {
                unknown.append(arg)
                i += 1
            }
        }
        return unknown.isEmpty ? .start : .unknown(unknown)
    }

    /// Where the running pet holds its lock.
    public static func lockURL(petHome: URL) -> URL { petHome.appending(path: "app.lock") }

    /// Takes the one-pet lock, waiting up to `wait` seconds for a pet that is on its way
    /// out: an install kills the old pet and opens the new one straight after, and the
    /// new one must not give up because the old one has not quite exited.
    ///
    /// Returns the open descriptor, which the caller keeps open for the life of the
    /// process (the lock goes with it, even on a crash), or nil when another pet holds it.
    public static func acquireLock(at url: URL, wait: TimeInterval = 0) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(100_000)
        }
        // The holder's pid, for the message a second launch prints.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return fd
    }

    /// The pid the running pet wrote into its lock file, if it can be read.
    public static func holder(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
