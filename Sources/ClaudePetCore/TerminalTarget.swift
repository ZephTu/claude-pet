import Foundation

/// The parsing and validation half of "jump to the terminal this session runs
/// in". Lives in Core, away from AppKit, so it can be tested without a window
/// server — the same reason PetLayout does.
public enum TerminalTarget {
    /// Works out which terminal tab a shell is running in, from that shell's own
    /// environment.
    ///
    /// TERM_PROGRAM is consulted first and is the whole point of this function.
    /// Both handle variables are ordinary exported variables, so they are
    /// inherited by anything launched from that shell — a shell running under
    /// iTerm2 can still carry a stale ORCA_TERMINAL_HANDLE from whatever started
    /// it, and jumping on that would raise a completely unrelated Orca tab.
    /// TERM_PROGRAM names the terminal that actually owns the shell, so it is the
    /// tie-breaker — and, when it names a terminal we cannot address, it is also
    /// a reason to give up rather than fall back. A shell under Terminal.app that
    /// inherited ORCA_TERMINAL_HANDLE would otherwise offer a jump that raises
    /// some unrelated Orca tab. Bare presence is consulted only when TERM_PROGRAM
    /// is absent entirely, which is the one case where we have nothing better.
    /// - Parameter cwd: the session's directory. Only an editor's terminal
    ///   needs it: the editor has no handle for a terminal, so the jump goes to
    ///   the window that has this directory open instead.
    public static func identify(environment env: [String: String], cwd: String = "") -> TerminalRef? {
        let program = env["TERM_PROGRAM"] ?? ""
        let orca = env["ORCA_TERMINAL_HANDLE"] ?? ""
        let iterm = env["ITERM_SESSION_ID"] ?? ""

        switch program {
        case "iTerm.app":
            return iterm.isEmpty ? nil : TerminalRef(kind: "iterm2", handle: iterm)
        case "Orca":
            return orca.isEmpty ? nil : TerminalRef(kind: "orca", handle: orca)
        case "vscode":
            // VS Code and everything forked from it — Cursor, Windsurf — say
            // "vscode" here. Which one it actually is comes from the app.
            guard let app = editorApp(environment: env), !cwd.isEmpty else { return nil }
            return TerminalRef(kind: "vscode", handle: app + "|" + cwd)
        case "":
            break  // nothing told us; fall through to bare presence
        default:
            return nil  // a terminal we cannot address — any handle here is stale
        }

        if !orca.isEmpty { return TerminalRef(kind: "orca", handle: orca) }
        if !iterm.isEmpty { return TerminalRef(kind: "iterm2", handle: iterm) }
        return nil
    }

    /// Kinds this build knows how to act on. Anything else — including a kind
    /// written by a future pet-emit this binary predates — makes the row
    /// non-clickable rather than giving the user a dead click.
    public static func canJump(kind: String) -> Bool {
        kind == "orca" || kind == "iterm2" || kind == "vscode"
    }

    // MARK: - VS Code and its forks

    /// Which editor owns this terminal: its bundle id, or failing that the path
    /// of its .app.
    ///
    /// macOS sets __CFBundleIdentifier for every app it launches and the
    /// integrated terminal inherits it, so it names Cursor and VS Code apart
    /// even though both report TERM_PROGRAM=vscode. The git askpass helper the
    /// editor injects lives inside its own .app, which is the fallback for an
    /// editor started some other way.
    static func editorApp(environment env: [String: String]) -> String? {
        if let id = env["__CFBundleIdentifier"], isSafeBundleID(id) { return id }
        for key in ["VSCODE_GIT_ASKPASS_NODE", "VSCODE_GIT_ASKPASS_MAIN"] {
            guard let path = env[key], let end = path.range(of: ".app/") else { continue }
            let app = String(path[..<end.lowerBound]) + ".app"
            if app.hasPrefix("/"), !app.contains("|") { return app }
        }
        return nil
    }

    static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// The two halves of a "vscode" handle: the app, then the session's
    /// directory. Split at the first bar, since a directory may contain one
    /// and neither a bundle id nor an accepted app path can.
    public static func editorTarget(handle: String) -> (app: String, cwd: String)? {
        guard let bar = handle.firstIndex(of: "|") else { return nil }
        let app = String(handle[..<bar])
        let cwd = String(handle[handle.index(after: bar)...])
        guard !app.isEmpty, cwd.hasPrefix("/") else { return nil }
        return (app, cwd)
    }

    /// The folder to ask the editor for, so it raises the window that already
    /// has it open rather than opening a second one.
    ///
    /// The session's own directory is often a subfolder of what the window
    /// has open, and asking for a subfolder opens a NEW window. So: the
    /// deepest workspace folder Claude Code's IDE lock files list that
    /// contains the directory, else the enclosing git repository, else the
    /// directory itself.
    ///
    /// - Parameters:
    ///   - workspaces: every `workspaceFolders` entry from ~/.claude/ide/*.lock.
    ///   - isRepoRoot: whether a directory holds a `.git`, file or folder.
    public static func editorFolder(cwd: String, workspaces: [String],
                                    isRepoRoot: (String) -> Bool) -> String {
        let dir = trimmed(cwd)
        let best = workspaces.map(trimmed)
            .filter { dir == $0 || dir.hasPrefix($0 == "/" ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
        if let best { return best }
        var probe = dir
        while probe.count > 1 {
            if isRepoRoot(probe) { return probe }
            probe = (probe as NSString).deletingLastPathComponent
        }
        return dir
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The `workspaceFolders` a lock file lists, or none if it is not one.
    public static func lockWorkspaces(_ data: Data) -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let folders = root["workspaceFolders"] as? [String]
        else { return [] }
        return folders.filter { $0.hasPrefix("/") }
    }

    /// ITERM_SESSION_ID looks like `w0t1p0:0F0C1A5B-…`. The `w`/`t`/`p` prefix is
    /// the tab's position at the moment the shell started and goes stale the
    /// instant tabs are reordered; the uuid after the colon does not. Returns the
    /// input unchanged when there is no colon, so a future format that drops the
    /// prefix keeps working.
    public static func iTermUUID(from sessionID: String) -> String {
        guard let colon = sessionID.firstIndex(of: ":") else { return sessionID }
        return String(sessionID[sessionID.index(after: colon)...])
    }

    /// Did `orca terminal switch --json` actually switch anything?
    ///
    /// The CLI exits 0 even when the handle is stale — a closed tab comes back as
    /// `{"ok": false, "error": {"code": "terminal_handle_stale"}}` with status 0.
    /// Trusting the exit status alone would raise Orca to the foreground on some
    /// unrelated tab, which reads as the jump going to the wrong place.
    public static func orcaSwitchSucceeded(_ stdout: String) -> Bool {
        guard
            let data = stdout.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["ok"] as? Bool == true
    }

    /// Is this safe to interpolate into an AppleScript string literal?
    ///
    /// This is the one genuinely dangerous input in the feature: the value comes
    /// from an environment variable, is written to a file by one process, and is
    /// read back by another that pastes it into a script it then executes. A
    /// quote or a newline in it would end the literal and let the rest run as
    /// code. Allowing only hex digits and dashes — the shape of every uuid iTerm2
    /// has ever issued — makes that impossible rather than merely unlikely.
    public static func isSafeITermUUID(_ uuid: String) -> Bool {
        !uuid.isEmpty && uuid.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}
