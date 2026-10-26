import Darwin
import Foundation

/// Asks the kernel whether a process is still running, and what it is called.
///
/// This exists so the pet can stop guessing at liveness from timestamps. A
/// session that is open but idle — nobody typing, no tools running — writes no
/// hooks, so its file's `updatedAt` stands still while the session is very much
/// alive. Judging by elapsed time makes those sessions vanish from the panel
/// while the user is still looking at them.
///
/// The name check is what makes a recorded pid safe to trust. Pids are recycled,
/// so a dead session's pid can later belong to something unrelated; requiring the
/// process to still be named `claude` turns a recycled pid back into "dead".
public enum ProcessProbe {
    /// What Claude Code's process is called, matched as a PREFIX.
    ///
    /// The kernel's `p_comm` for it is actually `claude.exe`, not `claude` —
    /// `ps -o comm` shows the basename of argv[0] while `ps -o ucomm` shows
    /// p_comm, and only the latter is what sysctl returns. Matching on the
    /// prefix covers both spellings, so a rename between versions degrades to
    /// "still detected" instead of "every session silently looks dead".
    public static let claudeProcessName = "claude"

    /// Is `pid` alive AND running Claude Code, however this install names it?
    ///
    /// The name alone stopped being enough: the native installer keeps one binary
    /// per release under `~/.local/share/claude/versions/` and launches it from
    /// there, so the kernel calls the process `2.1.310`, not `claude`. Every hook
    /// then failed to find its session's pid, every session fell back to the
    /// fifteen-minute clock, and idle sessions drained out of the panel one by one
    /// while their terminals were still open. The executable's path is what still
    /// says "claude" in that layout.
    public static func isClaude(pid: Int32) -> Bool {
        guard pid > 0, let name = processName(pid: pid), !name.isEmpty else { return false }
        return looksLikeClaude(name: name, path: executablePath(pid: pid))
    }

    /// Pure half of `isClaude`, so both install layouts can be tested without a
    /// real Claude Code process to point at.
    public static func looksLikeClaude(name: String, path: String?) -> Bool {
        if nameMatches(name, claudeProcessName) { return true }
        guard let path, !path.isEmpty else { return false }
        let parts = path.split(separator: "/").map(String.init)
        if let last = parts.last, nameMatches(last, claudeProcessName) { return true }
        // .../claude/versions/<version> — the native installer's layout.
        return parts.count >= 3
            && parts[parts.count - 2] == "versions"
            && parts[parts.count - 3] == claudeProcessName
    }

    /// The full path of the executable `pid` is running, or nil if it is gone.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Is `pid` alive AND still running a process whose name starts with `name`?
    public static func isRunning(pid: Int32, named name: String) -> Bool {
        guard pid > 0, let actual = processName(pid: pid), !actual.isEmpty else { return false }
        return nameMatches(actual, name)
    }

    /// p_comm is truncated to 16 bytes by the kernel, which is the other reason
    /// this is a prefix test rather than equality.
    public static func nameMatches(_ actual: String, _ wanted: String) -> Bool {
        !wanted.isEmpty && actual.hasPrefix(String(wanted.prefix(Int(MAXCOMLEN))))
    }

    /// The kernel's short name for a running process, or nil when there is no
    /// such process.
    public static func processName(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibBuffer -> Int32 in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), &info, &size, nil, 0)
        }
        // size == 0 means the pid was valid input but matched no live process.
        guard result == 0, size > 0 else { return nil }
        return withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    /// Walks up the process tree looking for a process with this name, starting
    /// at `pid`'s parent.
    ///
    /// pet-emit uses this to find the Claude Code process that invoked it: the
    /// hook is run through a shell, so `claude` is the grandparent rather than
    /// the parent, and that shape is an implementation detail that could change.
    /// The depth cap keeps a malformed tree from looping forever.
    public static func findAncestor(named name: String, from pid: Int32, maxDepth: Int = 6) -> Int32? {
        findAncestor(from: pid, maxDepth: maxDepth) { candidate in
            processName(pid: candidate).map { nameMatches($0, name) } ?? false
        }
    }

    /// The nearest ancestor of `pid` that is Claude Code, by `isClaude`'s rules.
    public static func findClaudeAncestor(from pid: Int32, maxDepth: Int = 6) -> Int32? {
        findAncestor(from: pid, maxDepth: maxDepth, where: isClaude)
    }

    private static func findAncestor(
        from pid: Int32, maxDepth: Int, where matches: (Int32) -> Bool
    ) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if matches(parent) {
                return parent
            }
            current = parent
        }
        return nil
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibBuffer -> Int32 in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
