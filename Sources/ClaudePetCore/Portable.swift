import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// The few file and process calls the hook and the core make that are POSIX on the Mac and
/// something else on Windows. On the Mac each is exactly the call it replaced.
public enum Portable {
    /// Appends `data` to the file at `path`, creating it. On the Mac one `O_APPEND` write, so
    /// hooks firing together never splice their lines into each other; on Windows a
    /// FILE_APPEND_DATA handle, which appends atomically the same way.
    public static func append(_ data: Data, toFile path: String) {
        #if canImport(Darwin)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        #elseif os(Windows)
        let handle = nativePath(path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0x0004 /* FILE_APPEND_DATA */), DWORD(0x7 /* share read|write|delete */),
                        nil, DWORD(4 /* OPEN_ALWAYS */), DWORD(0x80 /* FILE_ATTRIBUTE_NORMAL */), nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { return }
        defer { CloseHandle(handle) }
        data.withUnsafeBytes { raw in
            var written: DWORD = 0
            _ = WriteFile(handle, raw.baseAddress, DWORD(raw.count), &written, nil)
        }
        #else
        if let h = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }() {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
        #endif
    }

    /// Runs `body` holding an exclusive lock on the file at `path` (created if missing). Tries
    /// `attempts` times, `interval` apart, then runs `body` anyway: a hook may not hang, and one
    /// lost update is better than a stuck session.
    public static func withFileLock<T>(_ path: String, attempts: Int, interval: TimeInterval,
                                       _ body: () -> T) -> T {
        #if canImport(Darwin)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        for _ in 0..<attempts {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(fd, LOCK_UN) }
                return body()
            }
            usleep(useconds_t(interval * 1_000_000))
        }
        return body()
        #elseif os(Windows)
        let handle = nativePath(path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0xC000_0000 /* GENERIC_READ | GENERIC_WRITE */),
                        DWORD(0x7 /* share read|write|delete */), nil, DWORD(4 /* OPEN_ALWAYS */),
                        DWORD(0x80 /* FILE_ATTRIBUTE_NORMAL */), nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { return body() }
        defer { CloseHandle(handle) }
        for _ in 0..<attempts {
            var overlapped = OVERLAPPED()
            // LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY
            if LockFileEx(handle, DWORD(0x2 | 0x1), 0, 1, 0, &overlapped).boolValue {
                defer {
                    var release = OVERLAPPED()
                    _ = UnlockFileEx(handle, 0, 1, 0, &release)
                }
                return body()
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return body()
        #else
        return body()
        #endif
    }

    /// The path as the operating system spells it. On Windows Foundation can hand back
    /// "/C:/Users/…"; Win32 wants "C:\Users\…".
    public static func nativePath(_ path: String) -> String {
        #if os(Windows)
        var p = path
        let chars = Array(p)
        if chars.count >= 3, chars[0] == "/", chars[1].isLetter, chars[2] == ":" { p.removeFirst() }
        return p.replacingOccurrences(of: "/", with: "\\")
        #else
        return path
        #endif
    }

    /// Is a process with this id still there? `kill(pid, 0) == 0` on the Mac.
    public static func processExists(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        return kill(pid, 0) == 0
        #else
        return ProcessProbe.exists(pid: pid)
        #endif
    }
}
