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
        /// Tokens the last reply's request sent.
        public let tokens: Int
        /// Tokens at which this session compacts.
        public let budget: Int

        public init(tokens: Int, budget: Int) {
            self.tokens = tokens
            self.budget = max(1, budget)
        }

        /// Share of the budget, 0-999. Past 100 when the session is already over
        /// it — one started before a lower window was set, or a model that is
        /// not set at all — which is exactly the case worth seeing.
        public var percent: Int {
            min(999, Int((Double(tokens) * 100 / Double(budget)).rounded()))
        }

        /// Past this the session is worth one reminder: each turn now re-sends
        /// two thirds of what it may carry.
        public var remindAt: Int { budget * 2 / 3 }
    }

    public static func parse(_ data: Data) -> Settings {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Settings()
        }
        var s = Settings()
        if let models = root["modelSettings"] as? [String: Any] {
            for (model, value) in models {
                if let w = ((value as? [String: Any])?["autoCompactWindow"] as? NSNumber)?.intValue,
                   w > 0 {
                    s.windows[modelKey(model)] = w
                }
            }
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
        } else if let w = settings.windows[modelKey(model)] {
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
        if tokens >= 1_000_000 {
            let m = (Double(tokens) / 1_000_000 * 10).rounded() / 10
            return m == m.rounded() ? "\(Int(m))M" : "\(m)M"
        }
        return "\(Int((Double(tokens) / 1000).rounded()))k"
    }
}

/// When a session's context deserves one word from the pet.
///
/// Fires on CROSSING `Reading.remindAt`, never on sitting above it: a session
/// the pet first sees already past it (on launch, or one it had not read yet)
/// is not news, and saying it every few minutes would be nagging. A crossing
/// the pet could not say yet — another line had the bubble, a session was
/// waiting on the user — stays due until it is said or the session drops back
/// under (compacted, or cleared). Dropping back under re-arms it.
public struct ContextAlarm: Sendable, Equatable {
    /// sessionId → tokens at the last observation.
    public private(set) var last: [String: Int] = [:]
    /// Sessions that crossed and have not been told about yet, oldest first.
    public private(set) var due: [String] = []

    public init() {}

    public mutating func observe(_ readings: [String: ContextBudget.Reading]) {
        for (sid, r) in readings {
            if let before = last[sid], before < r.remindAt, r.tokens >= r.remindAt,
               !due.contains(sid) {
                due.append(sid)
            }
            if r.tokens < r.remindAt { due.removeAll { $0 == sid } }
            last[sid] = r.tokens
        }
        // Gone from the screen: forget it, so it is not told about later.
        last = last.filter { readings[$0.key] != nil }
        due.removeAll { readings[$0] == nil }
    }

    /// The line was said.
    public mutating func said(_ sessionId: String) {
        due.removeAll { $0 == sessionId }
    }
}
