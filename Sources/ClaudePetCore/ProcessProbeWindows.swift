#if !canImport(Darwin)
import Foundation
#if os(Windows)
import WinSDK
#endif

/// The process questions `ProcessProbe` answers with sysctl on macOS, answered on Windows from a
/// Toolhelp snapshot. Names come back without ".exe", so "ClaudePet.exe" is "ClaudePet" here as it
/// is on the Mac.
///
/// Not answered on Windows: a process's controlling tty (there is none) and its command line
/// (would need NtQueryInformationProcess). Both return nil, which every caller already reads as
/// "can't tell": no Ghostty handle, no "the user approved it in the terminal" shortcut.
/// Elsewhere (Linux) everything returns "can't tell"; nothing ships there.
extension ProcessProbe {
    struct Entry {
        let pid: Int32
        let parent: Int32
        let name: String
    }

    /// Every running process, or empty when the snapshot cannot be taken.
    static func snapshot() -> [Entry] {
        #if os(Windows)
        let snap = CreateToolhelp32Snapshot(DWORD(0x2 /* TH32CS_SNAPPROCESS */), 0)
        guard let snap, snap != HANDLE(bitPattern: -1) else { return [] }
        defer { CloseHandle(snap) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var all: [Entry] = []
        var more = Process32FirstW(snap, &entry).boolValue
        while more {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw -> String in
                String(decodingCString: raw.baseAddress!.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
            }
            all.append(Entry(pid: Int32(bitPattern: entry.th32ProcessID),
                             parent: Int32(bitPattern: entry.th32ParentProcessID),
                             name: withoutExe(name)))
            more = Process32NextW(snap, &entry).boolValue
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

    public static func executablePath(pid: Int32) -> String? {
        #if os(Windows)
        guard pid > 0,
              let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return nil }
        defer { CloseHandle(process) }
        var buffer = [WCHAR](repeating: 0, count: 2048)
        var size = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &size).boolValue else { return nil }
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
        guard GetProcessTimes(process, &created, &exited, &kernel, &user).boolValue else { return nil }
        // 100ns ticks since 1601-01-01.
        let ticks = UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        #else
        return nil
        #endif
    }

    public static func controllingTTY(pid: Int32) -> String? { nil }

    public static func arguments(pid: Int32) -> String? { nil }

    /// Is a process with this id still there? `kill(pid, 0)` on the Mac.
    public static func exists(pid: Int32) -> Bool {
        #if os(Windows)
        guard pid > 0,
              let process = OpenProcess(DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */), false, DWORD(pid))
        else { return false }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        guard GetExitCodeProcess(process, &code).boolValue else { return false }
        return code == 259 /* STILL_ACTIVE */
        #else
        return false
        #endif
    }
}
#endif
