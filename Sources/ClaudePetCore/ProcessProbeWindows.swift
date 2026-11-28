#if !canImport(Darwin)
import Foundation
#if os(Windows)
import WinSDK
#endif

/// The process questions `ProcessProbe` answers with sysctl on macOS, answered on Windows from a
/// Toolhelp snapshot. Names come back without ".exe", so "ClaudePet.exe" is "ClaudePet" here as it
/// is on the Mac.
///
/// Not answered on Windows: a process's controlling tty (there is none). It returns nil, which
/// every caller already reads as "can't tell" (no Ghostty handle).
/// Elsewhere (Linux) everything returns "can't tell"; nothing ships there.
extension ProcessProbe {
    public struct Entry {
        public let pid: Int32
        public let parent: Int32
        public let name: String
    }

    /// Every running process, or empty when the snapshot cannot be taken.
    public static func snapshot() -> [Entry] {
        #if os(Windows)
        let snap = CreateToolhelp32Snapshot(DWORD(0x2 /* TH32CS_SNAPPROCESS */), 0)
        guard let snap, snap != HANDLE(bitPattern: -1) else { return [] }
        defer { CloseHandle(snap) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var all: [Entry] = []
        var more = Process32FirstW(snap, &entry)
        while more {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw -> String in
                String(decodingCString: raw.baseAddress!.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
            }
            all.append(Entry(pid: Int32(bitPattern: entry.th32ProcessID),
                             parent: Int32(bitPattern: entry.th32ParentProcessID),
                             name: withoutExe(name)))
            more = Process32NextW(snap, &entry)
        }
        return all
        #else
        return []
        #endif
    }

    static func withoutExe(_ name: String) -> String {
        name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    public static func processName(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        return snapshot().first { $0.pid == pid }?.name
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        return snapshot().first { $0.pid == pid }?.parent
    }

    public static func childPIDs(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        return snapshot().filter { $0.parent == pid }.map(\.pid)
    }

    public static func isAnyRunning(named name: String) -> Bool {
        snapshot().contains { $0.name == name }
    }

    /// The Claude Code processes running now, by `isClaude`'s rules over one snapshot (asking
    /// `isClaude` per pid would take a snapshot each time). A Claude Code started by another one
    /// is not counted, so this is one per session. The connection report's count (PetHealth).
    public static func claudePIDs() -> [Int32] {
        let all = snapshot()
        let claude = Set(all.filter { entry in
            // The path is read only for a name that could be the native installer's version.
            looksLikeClaude(name: entry.name,
                            path: entry.name.first?.isNumber == true ? executablePath(pid: entry.pid) : nil)
        }.map(\.pid))
        return all.filter { claude.contains($0.pid) && !claude.contains($0.parent) }.map(\.pid)
    }

    public static func executablePath(pid: Int32) -> String? {
        #if os(Windows)
        guard pid > 0,
              let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return nil }
        defer { CloseHandle(process) }
        var buffer = [WCHAR](repeating: 0, count: 2048)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size) else { return nil }
        return String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
        #else
        return nil
        #endif
    }

    public static func startTime(pid: Int32) -> Date? {
        #if os(Windows)
        guard pid > 0,
              let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return nil }
        defer { CloseHandle(process) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &created, &exited, &kernel, &user) else { return nil }
        // 100ns ticks since 1601-01-01.
        let ticks = UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        #else
        return nil
        #endif
    }

    public static func controllingTTY(pid: Int32) -> String? { nil }

    /// The process's argv joined by spaces, as the Mac's KERN_PROCARGS2 reading gives it: the
    /// command line read from the process (NtQueryInformationProcess, ProcessCommandLineInformation)
    /// and split as the C runtime splits it, so Claude Code's tool shell
    /// (`bash.exe -c "source …/shell-snapshots/snapshot-… && eval '…' && pwd -P …"`) reads as
    /// it does on the Mac. nil when it is gone or not ours.
    public static func arguments(pid: Int32) -> String? {
        #if os(Windows)
        guard pid > 0, let line = commandLine(pid: pid) else { return nil }
        let argv = WindowsCommandLine.split(line)
        return argv.isEmpty ? nil : argv.joined(separator: " ")
        #else
        return nil
        #endif
    }

    #if os(Windows)
    private typealias NtQueryInformationProcess = @convention(c) (
        HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG

    /// A process's command line as it was started. ntdll's NtQueryInformationProcess with class 60
    /// (Windows 8.1+) needs only PROCESS_QUERY_LIMITED_INFORMATION; it fills a UNICODE_STRING
    /// whose buffer follows it in the same block. Looked up at run time: the WinSDK module does
    /// not declare it.
    static func commandLine(pid: Int32) -> String? {
        guard let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return nil }
        defer { CloseHandle(process) }
        guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let found = GetProcAddress(ntdll, "NtQueryInformationProcess")
        else { return nil }
        let query = unsafeBitCast(found, to: NtQueryInformationProcess.self)
        var needed: ULONG = 0
        _ = query(process, 60, nil, 0, &needed)   // STATUS_INFO_LENGTH_MISMATCH, with the size
        guard needed > 0, needed < 1 << 20 else { return nil }
        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 16)
        defer { block.deallocate() }
        guard query(process, 60, block, needed, &needed) >= 0 else { return nil }
        // UNICODE_STRING: USHORT Length (bytes), USHORT MaximumLength, then the buffer pointer
        // at the next pointer-aligned offset.
        let bytes = Int(block.load(as: UInt16.self))
        guard bytes > 0,
              let chars = block.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.stride,
                                     as: UnsafePointer<UInt16>?.self)
        else { return nil }
        return String(decoding: UnsafeBufferPointer(start: chars, count: bytes / 2), as: UTF16.self)
    }
    #endif

    /// Is a process with this id still there? `kill(pid, 0)` on the Mac.
    public static func exists(pid: Int32) -> Bool {
        #if os(Windows)
        guard pid > 0,
              let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return false }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        guard GetExitCodeProcess(process, &code) else { return false }
        return code == 259 /* STILL_ACTIVE */
        #else
        return false
        #endif
    }
}
#endif
