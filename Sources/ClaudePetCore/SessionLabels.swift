import Foundation

/// What a session is called, and whether the user has pinned it.
///
/// Both are keyed by `sessionId` rather than by project directory. Two sessions
/// in one repo are two different things to the user; merging them by path would
/// give one of them the other's name, and pin both when only one was pinned.
/// A session id is never reused, so a departed one's preferences can simply be
/// dropped.
public enum SessionLabels {
    public struct Prefs: Sendable, Equatable {
        public var alias: String
        public var pinned: Bool

        public init(alias: String = "", pinned: Bool = false) {
            self.alias = alias
            self.pinned = pinned
        }

        public var isEmpty: Bool { alias.isEmpty && !pinned }
    }

    /// Longest alias worth storing. Past this a name stops being a label and
    /// starts being a sentence the panel cannot show.
    public static let maxAliasLength = 40

    public static func sanitiseAlias(_ raw: String) -> String {
        // Control characters and newlines would break the single-line row
        // layout; the panel renders as plain text, so nothing here is about
        // markup — only about staying on one line.
        let flattened = raw
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(maxAliasLength))
    }

    /// The name to show, in the order the user would expect it:
    /// their own alias, then the terminal tab's title, then the directory.
    ///
    /// - Parameter title: the terminal tab title, if there is a useful one.
    public static func displayName(
        for session: SessionState,
        prefs: [String: Prefs],
        title: String = ""
    ) -> String {
        let alias = prefs[session.sessionId]?.alias ?? ""
        if !alias.isEmpty { return alias }
        if !title.isEmpty, !TerminalTitles.isUseless(title) { return title }
        if !session.project.isEmpty { return session.project }
        // Last resort: enough of the id to tell two apart, not the whole uuid.
        return String(session.sessionId.prefix(8))
    }

    public static func isPinned(_ session: SessionState, prefs: [String: Prefs]) -> Bool {
        prefs[session.sessionId]?.pinned ?? false
    }

    /// Ordering inside a group: pinned sessions rise, but never above something
    /// that actually wants the user. Pinning says "I care about this one", not
    /// "show me this instead of the thing that is blocked".
    public static func ordered(_ sessions: [SessionState], prefs: [String: Prefs]) -> [SessionState] {
        sessions.enumerated().sorted { a, b in
            let pa = isPinned(a.element, prefs: prefs)
            let pb = isPinned(b.element, prefs: prefs)
            if pa != pb { return pa }
            return a.offset < b.offset   // otherwise keep the order handed in
        }.map(\.element)
    }

    public static func pruned(_ prefs: [String: Prefs], keeping sessions: [SessionState]) -> [String: Prefs] {
        let live = Set(sessions.map(\.sessionId))
        return prefs.filter { live.contains($0.key) && !$0.value.isEmpty }
    }

    // MARK: - Storage

    public static func decode(_ data: Data) -> [String: Prefs] {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let entries = (raw as? [String: Any])?["sessions"] as? [String: [String: Any]]
        else { return [:] }

        var prefs: [String: Prefs] = [:]
        for (id, entry) in entries {
            let p = Prefs(alias: sanitiseAlias(entry["alias"] as? String ?? ""),
                          pinned: entry["pinned"] as? Bool ?? false)
            if !p.isEmpty { prefs[id] = p }
        }
        return prefs
    }

    public static func encode(_ prefs: [String: Prefs]) -> Data {
        var entries: [String: [String: Any]] = [:]
        for (id, p) in prefs where !p.isEmpty {
            entries[id] = ["alias": p.alias, "pinned": p.pinned]
        }
        return (try? JSONSerialization.data(withJSONObject: ["sessions": entries])) ?? Data()
    }
}

/// The git branch or worktree a session's directory sits in.
///
/// Parsing only — running git is the host layer's job, and it must not happen
/// inside a hook: a hook runs on every single event and has to return fast, so
/// spawning a subprocess there would tax every tool call in every session.
public enum GitLabel {
    /// Reads a branch name out of `.git/HEAD`'s contents.
    ///
    /// Reading the file beats running `git`: no subprocess, and it works the
    /// same in a worktree, where `.git` is a file pointing elsewhere.
    public static func branch(fromHEAD contents: String) -> String {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: ") else {
            // Detached HEAD: a bare sha. Short form, or it eats the row.
            let sha = line.prefix(7)
            return sha.count == 7 && sha.allSatisfy(\.isHexDigit) ? String(sha) : ""
        }
        let ref = line.dropFirst("ref: ".count)
        guard let name = ref.split(separator: "/").last, !name.isEmpty else { return "" }
        // refs/heads/feature/foo → feature/foo, not just foo.
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return String(name)
    }

    /// Only worth showing when it is not the obvious one.
    public static func isWorthShowing(_ branch: String) -> Bool {
        !branch.isEmpty && branch != "main" && branch != "master"
    }
}
