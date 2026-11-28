#if os(Windows)
import ClaudePetCore
import Foundation
import PetUIA
import WinSDK

/// Jumping to a session's terminal on Windows: the hook's half (`identify`, which terminal a
/// session runs in) and `pet-emit --jump <session>` (bring that tab to the front), which the
/// Electron shell runs when a row in the panel is clicked.
///
/// Kinds, as written to the session file's `terminal`:
/// - `orca`: from `TerminalTarget.identify`, as on the Mac. Orca's CLI switches the tab.
/// - `wt`: Windows Terminal (`WT_SESSION` set, no `TERM_PROGRAM`). The handle is WT_SESSION, kept
///   for the record; the jump works from the session's pid instead (see `jumpConsole`).
/// - `console`: a console window of its own (conhost), seen by attaching to the session's console.
enum WindowsJump {
    // MARK: - The hook's half

    /// The terminal of a session `TerminalTarget.identify` found nothing for. Nil when a
    /// TERM_PROGRAM names a terminal we can't address (VS Code, say): a WT_SESSION it inherited
    /// would point at some other window.
    static func identify(environment env: [String: String], claudePID: Int32?) -> TerminalRef? {
        guard (env["TERM_PROGRAM"] ?? "").isEmpty else { return nil }
        if let wt = env["WT_SESSION"], isSafeToken(wt) { return TerminalRef(kind: "wt", handle: wt) }
        // No terminal variables at all: a console window of its own, or no console (an editor
        // extension, a GUI) - only the console itself can tell.
        guard let pid = claudePID, let window = consoleWindow(of: pid),
              IsWindowVisible(window) || GetWindow(window, UINT(GW_OWNER)) != nil
        else { return nil }
        return TerminalRef(kind: "console", handle: "console")
    }

    /// The console window of `pid`'s console. For a ConPTY session (Windows Terminal) this is a
    /// hidden pseudo window owned by the terminal's window; for conhost it is the window itself.
    private static func consoleWindow(of pid: Int32) -> HWND? {
        // The hook often shares the session's console already: then there is nothing to attach.
        var pids = [DWORD](repeating: 0, count: 64)
        let count = Int(GetConsoleProcessList(&pids, DWORD(pids.count)))
        if count > 0, pids.prefix(min(count, pids.count)).contains(DWORD(bitPattern: pid)) {
            return GetConsoleWindow()
        }
        return withConsole(of: pid) { GetConsoleWindow() } ?? nil
    }

    /// Runs `body` attached to `pid`'s console, and detaches again. Attaching hands a process
    /// started without its own standard handles the console's instead; the hook's stdout must
    /// stay the pipe Claude Code reads (a held prompt's answer goes there), so all three are
    /// put back. While attached, the console's Ctrl+C and Ctrl+Break events (the user's, in that
    /// tab) are ignored: they would end this process mid-way.
    static func withConsole<T>(of pid: Int32, _ body: () -> T) -> T? {
        let saved = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE].map { ($0, GetStdHandle($0)) }
        defer { for (which, handle) in saved { SetStdHandle(which, handle) } }
        FreeConsole()
        guard AttachConsole(DWORD(bitPattern: pid)) else { return nil }
        SetConsoleCtrlHandler(nil, true)
        defer {
            SetConsoleCtrlHandler(nil, false)
            FreeConsole()
        }
        return body()
    }

    // MARK: - pet-emit --jump

    /// Returns the exit code: 0 when the terminal was brought up, 1 when it could not be.
    static func run(session: String) -> Int32 {
        guard isSafeToken(session) else {
            return fail("not a session id: \(session)")
        }
        let file = HookEmit.sessionsDirectory.appending(path: session + ".json")
        guard let data = try? Data(contentsOf: file), let state = SessionState.decode(from: data) else {
            return fail("no session \(session)")
        }
        guard let terminal = state.terminal else { return fail("session \(session) has no terminal") }
        switch terminal.kind {
        case "orca":
            return jumpOrca(handle: terminal.handle)
        case "wt", "console":
            guard let pid = state.pid else { return fail("session \(session) has no pid") }
            // A pid reused by something else (another Claude Code session, even) must not be
            // attached to and retitled: the process must be older than the session's last hook.
            guard ProcessProbe.isClaude(pid: pid),
                  (ProcessProbe.startTime(pid: pid) ?? .distantFuture) <= state.updatedAt
            else { return fail("Claude Code (pid \(pid)) is gone") }
            return jumpConsole(pid: pid)
        default:
            return fail("can't jump to a \(terminal.kind) terminal")
        }
    }

    /// `pet-emit --raise-orca`: Orca's window to the front, after the board opened a tab in it
    /// with `--focus` (which only switches the tab inside Orca). 1 when Orca has no window.
    static func raiseOrca() -> Int32 {
        guard let window = topLevelWindow(ofExecutable: "orca.exe") else { return fail("no Orca window") }
        raise(window)
        return 0
    }

    // MARK: Windows Terminal and conhost

    private static let windowsTerminalClass = "CASCADIA_HOSTING_WINDOW_CLASS"

    /// Attaches to the session's console to find its window. Under Windows Terminal that is the
    /// pseudo window's owner, and the tab is found by its title: the console's title is set to a
    /// one-off mark, UI Automation selects the tab showing it, and the title is put back.
    private static func jumpConsole(pid: Int32) -> Int32 {
        let outcome: Int32? = withConsole(of: pid) {
            guard let console = GetConsoleWindow() else { return fail("pid \(pid) has no console window") }
            guard let host = GetWindow(console, UINT(GW_OWNER)) else {
                // conhost: the console window is the terminal. A hidden, unowned one belongs to
                // a terminal we can't address (WT_SESSION inherited by an IDE, say): raising it
                // would take the focus to nothing.
                guard IsWindowVisible(console) else { return fail("pid \(pid)'s console window is hidden") }
                raise(console)
                return 0
            }
            if className(host) == windowsTerminalClass, !selectTab(in: host) {
                // A profile that ignores titles set by programs never shows the mark: the window
                // still comes up, on whichever tab it was on.
                FileHandle.standardError.write(Data("pet-emit: no tab showed the mark; raising the window only\n".utf8))
            }
            raise(host)
            return 0
        }
        return outcome ?? fail("can't attach to the console of pid \(pid)")
    }

    private static let markPrefix = "claude-pet-jump-"

    private static func selectTab(in window: HWND) -> Bool {
        // Without the title there is nothing to put back.
        guard var original = consoleTitle() else { return false }
        // A mark a killed jump left behind is not a title to keep.
        if original.hasPrefix(markPrefix) { original = "" }
        let mark = markPrefix + UUID().uuidString.prefix(8)
        defer {
            // Put the title back only while the mark still shows: a title the session set since
            // is newer than ours.
            if consoleTitle() == mark { _ = original.withCString(encodedAs: UTF16.self) { SetConsoleTitleW($0) } }
        }
        // retitle: Claude Code animates its title while it works, writing over a mark set once.
        let selected = mark.withCString(encodedAs: UTF16.self) {
            pet_uia_select_tab(Int(bitPattern: window), $0, 1500, 1)
        }
        return selected == 1
    }

    /// Nil when it can't be read (0 means an empty title and a failure alike).
    private static func consoleTitle() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 4096)
        SetLastError(0)
        let length = min(Int(GetConsoleTitleW(&buffer, DWORD(buffer.count))), buffer.count)
        if length == 0, GetLastError() != 0 { return nil }
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }

    // MARK: Typing into a console

    /// One key as the console takes it from the keyboard: a press and a release.
    struct Key {
        var char: UInt16
        var virtualKey: UInt16 = 0
        var scanCode: UInt16 = 0
        var controlState: DWORD = 0

        static let enter = Key(char: 13, virtualKey: UInt16(VK_RETURN), scanCode: 0x1C)
        static let escape = Key(char: 27, virtualKey: UInt16(VK_ESCAPE), scanCode: 0x01)
        /// Ctrl+C as a key, not a signal: Claude Code reads its console raw and takes it as the
        /// user's Ctrl+C (once interrupts or clears, twice in a row quits).
        static let ctrlC = Key(char: 3, virtualKey: 0x43, scanCode: 0x2E, controlState: DWORD(LEFT_CTRL_PRESSED))

        var records: [INPUT_RECORD] {
            [true, false].map { down in
                var r = INPUT_RECORD()
                r.EventType = WORD(KEY_EVENT)
                r.Event.KeyEvent.bKeyDown = WindowsBool(down)
                r.Event.KeyEvent.wRepeatCount = 1
                r.Event.KeyEvent.wVirtualKeyCode = virtualKey
                r.Event.KeyEvent.wVirtualScanCode = scanCode
                r.Event.KeyEvent.uChar.UnicodeChar = char
                r.Event.KeyEvent.dwControlKeyState = controlState
                return r
            }
        }
    }

    /// Writes keys into the input of `pid`'s console, as if typed in its window - the way into a
    /// Windows Terminal tab or a console window, neither of which takes input from outside.
    /// Each group goes in after a pause of its `after` seconds (a Return that arrives with the
    /// text is taken as part of a paste, not as the key that submits it). Returns how many groups
    /// went in whole: 0 when the console can't be reached.
    @discardableResult
    static func type(into pid: Int32, _ groups: [(after: Double, keys: [Key])]) -> Int {
        withConsole(of: pid) { () -> Int in
            // Not the standard input handle: this process may have been given a pipe (the board
            // sends its request on stdin), and attaching leaves such a handle as it was.
            let input = "CONIN$".withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(0xC000_0000), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                            DWORD(OPEN_EXISTING), 0, nil)
            }
            guard let input, input != INVALID_HANDLE_VALUE else { return 0 }
            defer { CloseHandle(input) }
            for (done, group) in groups.enumerated() {
                if group.after > 0 { Sleep(DWORD(group.after * 1000)) }
                var records = group.keys.flatMap(\.records)
                var offset = 0
                while offset < records.count {
                    let count = min(512, records.count - offset)
                    var written: DWORD = 0
                    let ok = records.withUnsafeMutableBufferPointer {
                        WriteConsoleInputW(input, $0.baseAddress! + offset, DWORD(count), &written)
                    }
                    guard ok, written > 0 else { return done }
                    offset += Int(written)
                }
            }
            return groups.count
        } ?? 0
    }

    /// The keys that type `text` (UTF-16 units, as the console carries them).
    static func keys(typing text: String) -> [Key] { text.utf16.map { Key(char: $0) } }

    // MARK: Orca

    private static func jumpOrca(handle: String) -> Int32 {
        guard isSafeToken(handle) else { return fail("not an Orca terminal handle: \(handle)") }
        guard let r = orca(["terminal", "switch", "--terminal", handle, "--json"]) else { return fail("no orca CLI found, or it did not start") }
        // Usually a stale handle: the tab was closed since the hook ran.
        guard TerminalTarget.orcaSwitchSucceeded(r.out) else {
            return fail("orca did not switch (exit \(r.status)): \(r.out.prefix(200)) \(r.err.prefix(300))")
        }
        // Switching the tab does not raise the window; that is a separate step.
        if let window = topLevelWindow(ofExecutable: "orca.exe") { raise(window) }
        return 0
    }

    /// Runs Orca's CLI to the end, or for `timeout` seconds: one still running then is ended and
    /// answers `timedOut` (what it did is unknown). Nil when there is no CLI or it would not start.
    static func orca(_ arguments: [String], timeout: Double = 10)
        -> (status: Int32, out: String, err: String, timedOut: Bool)? {
        guard let cli = orcaCLI() else { return nil }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let finished = DispatchSemaphore(value: 0)
        let expired = Expiry()
        DispatchQueue.global().async {
            if finished.wait(timeout: .now() + timeout) == .timedOut, process.isRunning {
                expired.set()
                process.terminate()
            }
        }
        defer { finished.signal() }
        // Both pipes drain at once: read one after the other, a full stderr would block the CLI
        // while we wait for its stdout to end.
        let complaints = Drain(err.fileHandleForReading)
        let reply = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaint = String(decoding: complaints.wait(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, reply, complaint, expired.value)
    }

    private final class Expiry: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// The CLI Orca's installer puts in its resources, as on the Mac (per user, or for all
    /// users). Not one from PATH: another program may be called orca.exe.
    private static func orcaCLI() -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let local = env["LOCALAPPDATA"] { candidates.append(local + "\\Programs\\orca\\resources\\bin\\orca.exe") }
        if let programs = env["ProgramFiles"] { candidates.append(programs + "\\Orca\\resources\\bin\\orca.exe") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Reads a pipe to its end on a thread of its own.
    private final class Drain: @unchecked Sendable {
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            Thread { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }.start()
        }

        func wait() -> Data {
            done.wait()
            return data
        }
    }

    // MARK: Windows

    /// The first visible, unowned, titled top-level window of a process running `exe`.
    private static func topLevelWindow(ofExecutable exe: String) -> HWND? {
        var window: HWND? = nil
        while let next = FindWindowExW(nil, window, nil, nil) {
            window = next
            guard IsWindowVisible(next), GetWindow(next, UINT(GW_OWNER)) == nil,
                  GetWindowTextLengthW(next) > 0 else { continue }
            var pid: DWORD = 0
            GetWindowThreadProcessId(next, &pid)
            let path = ProcessProbe.executablePath(pid: Int32(bitPattern: pid)) ?? ""
            if path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last?.lowercased() == exe {
                return next
            }
        }
        return nil
    }

    /// Brings a window to the front. Windows lets a process do that when the foreground process
    /// started it - the pet, just clicked - and otherwise only flashes the taskbar button; joining
    /// the foreground thread's input is the usual way past that.
    private static func raise(_ window: HWND) {
        if IsIconic(window) { ShowWindow(window, SW_RESTORE) }
        else if !IsWindowVisible(window) { ShowWindow(window, SW_SHOW) }  // hidden to the tray
        if SetForegroundWindow(window), GetForegroundWindow() == window { return }
        let me = GetCurrentThreadId()
        let front = GetWindowThreadProcessId(GetForegroundWindow(), nil)
        guard front != 0, front != me, AttachThreadInput(me, front, true) else { return }
        BringWindowToTop(window)
        _ = SetForegroundWindow(window)
        AttachThreadInput(me, front, false)
    }

    private static func className(_ window: HWND) -> String {
        var buffer = [WCHAR](repeating: 0, count: 256)
        let length = Int(GetClassNameW(window, &buffer, Int32(buffer.count)))
        return String(decoding: buffer.prefix(max(0, length)), as: UTF16.self)
    }

    /// Letters, digits, `-` and `_`: what Orca's handles and WT_SESSION's GUIDs are made of, and
    /// all that is safe to pass on as an argument.
    static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("pet-emit: \(message)\n".utf8))
        return 1
    }
}
#endif
