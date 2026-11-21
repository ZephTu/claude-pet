import Foundation

/// How much context a session carries against what it is allowed to carry
/// before Claude Code compacts it.
///
/// The pet used to show context as a share of the model's whole window — a
/// million tokens for every current model. That made a 500k session read as a
/// calm "50%" while every one of its turns re-sent half a million tokens, which
/// is where a five-hour quota goes (T-069). What the user controls, and what
/// the number should be measured against, is the auto-compact window set with
/// `/autocompact`: Claude Code summarizes the conversation as it nears that
/// size, so 100% here means "about to compact".
///
/// Read from the user's `~/.claude/settings.json`:
/// - `modelSettings.<model>.autoCompactWindow` — what `/autocompact 300k` writes;
/// - `env.CLAUDE_CODE_AUTO_COMPACT_WINDOW` — wins over the per-model setting;
/// - `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` — compact at this share of the window.
/// Nothing set means the model's whole window, as before.
public enum ContextBudget {
    public struct Settings: Sendable, Equatable {
        /// Model key (see `modelKey`) → autoCompactWindow.
        public var windows: [String: Int] = [:]
        public var envWindow: Int?
        /// 1-100.
        public var percentOverride: Double?

        public init(windows: [String: Int] = [:], envWindow: Int? = nil,
                    percentOverride: Double? = nil) {
            self.windows = windows
            self.envWindow = envWindow
            self.percentOverride = percentOverride
        }
    }

    /// One session's context, measured against its budget.
    public struct Reading: Sendable, Equatable {
        /// Tokens the last reply's request sent; 0 for a bare percentage.
        public let tokens: Int
        /// Tokens at which this session compacts; 0 for a bare percentage.
        public let budget: Int
        private let bare: Int?

        public init(tokens: Int, budget: Int) {
            self.tokens = tokens
            self.budget = max(1, budget)
            self.bare = nil
        }

        /// Only a percentage of some window, with no tokens behind it — the
        /// statusline's reading while the transcript has none. Shown as it is,
        /// and never reminded about: there is nothing to measure.
        public init(percentOnly: Int) {
            self.tokens = 0
            self.budget = 0
            self.bare = percentOnly
        }

        public var hasTokens: Bool { bare == nil }

        /// Share of the budget, 0-999. Past 100 when the session is already over
        /// it — one started before a lower window was set, or a model that is
        /// not set at all — which is exactly the case worth seeing.
        public var percent: Int {
            if let bare { return bare }
            return min(999, Int((Double(tokens) * 100 / Double(budget)).rounded()))
        }

        /// Past this the session is worth one reminder: each turn now re-sends
        /// two thirds of what it may carry.
        public var remindAt: Int { budget * 2 / 3 }
        /// Back under this — compacted, or cleared — it may be reminded again.
        /// Lower than `remindAt` so a session hovering at the line is not told
        /// every ten minutes.
        public var rearmAt: Int { budget / 2 }
    }

    public static func parse(_ data: Data) -> Settings {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Settings()
        }
        var s = Settings()
        if let models = root["modelSettings"] as? [String: Any] {
            var exact: [String: Int] = [:], stripped: [String: Int] = [:]
            for (model, value) in models {
                if let w = ((value as? [String: Any])?["autoCompactWindow"] as? NSNumber)?.intValue,
                   w > 0 {
                    exact[model.lowercased()] = w
                    stripped[modelKey(model)] = w
                }
            }
            // A key as written wins over another that only strips down to it
            // ("x" over "x[1m]"), so which one counts never depends on order.
            s.windows = stripped.merging(exact) { _, e in e }
        }
        let env = root["env"] as? [String: Any] ?? [:]
        if let w = number(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]), w > 0 { s.envWindow = Int(w) }
        if let p = number(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]), p > 0, p <= 100 {
            s.percentOverride = p
        }
        return s
    }

    /// "claude-opus-5-5[1m]" and "claude-opus-5-5-20261001" are both the
    /// "claude-opus-5-5" that settings are keyed by.
    public static func modelKey(_ model: String) -> String {
        var m = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        if let dash = m.lastIndex(of: "-") {
            let tail = m[m.index(after: dash)...]
            if tail.count == 8, tail.allSatisfy(\.isNumber) { m = String(m[..<dash]) }
        }
        return m
    }

    /// Tokens at which a session on `model` compacts.
    public static func budget(model: String, settings: Settings) -> Int {
        let whole = TranscriptStats.window(model: model)
        var window = whole
        if let w = settings.envWindow {
            window = min(w, whole)
        } else if let w = settings.windows[model.lowercased()] ?? settings.windows[modelKey(model)] {
            window = min(w, whole)
        }
        if let p = settings.percentOverride {
            window = max(1, Int(Double(window) * p / 100))
        }
        return window
    }

    /// settings.json env values are strings, but a hand-written number works too.
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// "48k", "300k", "1.2M": short enough for a row.
    public static func short(_ tokens: Int) -> String {
        if tokens >= 999_500 {
            let m = (Double(tokens) / 1_000_000 * 10).rounded() / 10
            return m == m.rounded() ? "\(Int(m))M" : "\(m)M"
        }
        return "\(Int((Double(tokens) / 1000).rounded()))k"
    }
}

/// When a session's context deserves one word from the pet.
///
/// Fires on CROSSING `Reading.remindAt`, never on sitting above it: a session
/// the pet first sees already past it (on launch, after a pause, or one it had
/// not read yet) is not news, and saying it every few minutes would be
/// nagging. Lowering the window under a session does not count as crossing
/// either. A crossing the pet could not say yet — another line had the bubble,
/// a session was waiting on the user — stays due until it is said or the
/// session drops back under. Once said (or first seen above), it is said again
/// only after the session falls under `rearmAt` — a compaction — and crosses again.
public struct ContextAlarm: Sendable, Equatable {
    /// sessionId → tokens at the last observation.
    public private(set) var last: [String: Int] = [:]
    /// Sessions that crossed and have not been told about yet, oldest first.
    public private(set) var due: [String] = []
    /// Told about, or first seen already past the line: quiet until re-armed.
    public private(set) var spent: Set<String> = []

    public init() {}

    public mutating func observe(_ readings: [String: ContextBudget.Reading]) {
        for (sid, r) in readings where r.hasTokens {
            let before = last[sid]
            if before == nil, r.tokens >= r.remindAt { spent.insert(sid) }
            if r.tokens < r.rearmAt { spent.remove(sid) }
            if let before, before < r.remindAt, r.tokens >= r.remindAt,
               !spent.contains(sid), !due.contains(sid) {
                due.append(sid)
            }
            if r.tokens < r.remindAt { due.removeAll { $0 == sid } }
            last[sid] = r.tokens
        }
        // Gone from the screen, or no tokens to go by: forget it, so it is not
        // told about later.
        let kept = { (sid: String) in readings[sid]?.hasTokens == true }
        last = last.filter { kept($0.key) }
        due.removeAll { !kept($0) }
        spent = spent.filter(kept)
    }

    /// The line was said.
    public mutating func said(_ sessionId: String) {
        due.removeAll { $0 == sessionId }
        spent.insert(sessionId)
    }
}
