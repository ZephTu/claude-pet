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
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let parentName = processName(pid: parent), nameMatches(parentName, name) {
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
