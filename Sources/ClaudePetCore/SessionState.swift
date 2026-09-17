import Foundation

/// What a single Claude Code session is doing right now.
public enum SessionActivity: String, Sendable, Decodable {
    case idle
    case busy
    case waiting
}

/// Which terminal tab a session is running in, when we could identify one.
///
/// Optional on purpose: a session started from a terminal we cannot address
/// simply has no reference, and its row in the panel is not clickable. Being a
/// plain Optional is also what lets state files written before this existed
/// still decode — a missing key decodes to nil rather than throwing.
public struct TerminalRef: Sendable, Equatable, Decodable {
    /// "orca" or "iterm2". Free-form rather than an enum so an unknown value
    /// written by a newer pet-emit degrades to "no jump" instead of failing the
    /// whole decode and dropping the session from the panel.
    public let kind: String
    /// Whatever that terminal uses to address a tab. Orca issues its own handle;
    /// iTerm2's is the raw ITERM_SESSION_ID, parsed at jump time.
    public let handle: String

    public init(kind: String, handle: String) {
        self.kind = kind
        self.handle = handle
    }
}

/// One session's state, mirrored from ~/.claude/pet/sessions/<sessionId>.json
/// Decodable only: nothing in the project ever encodes one. A synthesised
/// Encodable would not round-trip anyway — decode sets .iso8601 for dates and
/// an encoder would default to seconds-since-2001.
public struct SessionState: Sendable, Equatable, Decodable {
    public let sessionId: String
    public let project: String
    public let cwd: String
    public let state: SessionActivity
    public let tool: String
    public let detail: String
    public let since: Date
    public let updatedAt: Date
    public let terminal: TerminalRef?
    /// The Claude Code process this session belongs to, when pet-emit could find
    /// it. Liveness is decided from this rather than from `updatedAt`: an open
    /// but idle session writes no hooks, so its timestamp stands still while the
    /// session is very much alive. Optional so files written before this existed
    /// still decode — those fall back to the timeout.
    public let pid: Int32?
    /// When the user last typed into this session, as opposed to the session
    /// doing things on its own. Drives un-hiding: a muted session comes back
    /// only when the human speaks to it again. Nil for sessions last written
    /// before this field existed, and for ones never spoken to.
    public let lastPromptAt: Date?
    /// A short phrase naming what this session is waiting for approval on, e.g.
    /// "rm -rf build/" or "Edit AppMain.swift". Empty when it is not waiting, or
    /// when the session predates PermissionRequest support.
    public let waitingOn: String

    public init(
        sessionId: String,
        project: String,
        cwd: String,
        state: SessionActivity,
        tool: String,
        detail: String,
        since: Date,
        updatedAt: Date,
        terminal: TerminalRef? = nil,
        pid: Int32? = nil,
        lastPromptAt: Date? = nil,
        waitingOn: String = ""
    ) {
        self.sessionId = sessionId
        self.project = project
        self.cwd = cwd
        self.state = state
        self.tool = tool
        self.detail = detail
        self.since = since
        self.updatedAt = updatedAt
        self.terminal = terminal
        self.pid = pid
        self.lastPromptAt = lastPromptAt
        self.waitingOn = waitingOn
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, project, cwd, state, tool, detail, since, updatedAt
        case terminal, pid, lastPromptAt, waitingOn
    }

    /// Hand-written so that a damaged OPTIONAL field cannot take the whole
    /// session down with it.
    ///
    /// `Date?` is not lenient: Optional covers a missing key, but a key present
    /// with a value the decoder rejects — `"lastPromptAt": ""` — throws, and a
    /// throw here means the session silently vanishes from the panel. The
    /// required fields still throw on purpose: a state file with no `state` is
    /// not a session, and skipping it is correct.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        project = try c.decode(String.self, forKey: .project)
        cwd = try c.decode(String.self, forKey: .cwd)
        state = try c.decode(SessionActivity.self, forKey: .state)
        tool = try c.decode(String.self, forKey: .tool)
        detail = try c.decode(String.self, forKey: .detail)
        since = try c.decode(Date.self, forKey: .since)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        terminal = try? c.decodeIfPresent(TerminalRef.self, forKey: .terminal)
        pid = try? c.decodeIfPresent(Int32.self, forKey: .pid)
        lastPromptAt = try? c.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        waitingOn = (try? c.decodeIfPresent(String.self, forKey: .waitingOn)) as? String ?? ""
    }

    /// Decode one state file. Returns nil on any malformed input — a broken file
    /// must never take the pet down, it is just skipped.
    public static func decode(from data: Data) -> SessionState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionState.self, from: data)
    }
}
