import Foundation

/// The wording of the two lines that are about the person rather than the work.
///
/// Kept apart from `Chatter` because these are the only lines that translate.
/// Everything else the pet says names a session, a tool or a percentage, and
/// those read the same in any language; "go and refill your water" does not.
///
/// The corpus behind the daily line is NOT here — it is `Resources/pet/quotes.json`,
/// built by `scripts/fetch-quotes.py` and read at launch. What is here is the
/// handful of lines that have to work when that file is missing or corrupt,
/// because the day's first line is not allowed to be the empty string.
public enum Phrases {
    public enum Language: String, Sendable, Equatable, CaseIterable {
        case english
        case chinese

        /// Anything that is not a Chinese locale gets English, and so does an
        /// unknown one: a line nobody can read is worse than a line in the
        /// project's own language.
        public static func resolve(_ preferred: [String]) -> Language {
            guard let first = preferred.first?.lowercased() else { return .english }
            return first.hasPrefix("zh") ? .chinese : .english
        }
    }

    /// How many ways the break nudge can ask. Rotated so that three hours in a
    /// row does not produce the same sentence three times.
    public static let sitLongVariants = 3

    /// - Parameter variant: any integer; wrapped into range here so callers can
    ///   hand over a bucket number without knowing how many variants there are.
    public static func sitLong(hours: Int, variant: Int, language: Language) -> String {
        let pick = ((variant % sitLongVariants) + sitLongVariants) % sitLongVariants
        switch language {
        case .english:
            switch pick {
            case 0: return "\(hours)h at the desk — stand up for a minute"
            case 1: return "\(hours)h without a break — go and refill your water"
            default: return "\(hours)h straight — look out of the window for twenty seconds"
            }
        case .chinese:
            switch pick {
            case 0: return "坐了\(hours)小时了，起来走两步"
            case 1: return "连着\(hours)小时了，去接杯水吧"
            default: return "\(hours)小时没挪窝了，看看窗外二十秒"
            }
        }
    }

    /// The last resort behind the daily line. Deliberately short and plain —
    /// these are what a user sees on the day the resource file fails to load,
    /// and a broken install is the worst moment to be clever.
    public static func builtinQuotes(_ language: Language) -> [String] {
        switch language {
        case .english:
            return [
                "One thing at a time.",
                "Start with the smallest piece that works.",
                "Slow is smooth, smooth is fast.",
                "You do not have to finish it today.",
                "Make it work, then make it right.",
            ]
        case .chinese:
            return [
                "一次做一件事。",
                "先跑通最小的那块。",
                "慢一点反而快。",
                "今天不一定要做完。",
                "先让它能跑，再让它好看。",
            ]
        }
    }

    /// The day's line, picked by day number so it is the same all day and
    /// different tomorrow. Falls back to the built-ins when the corpus is empty.
    public static func greeting(quotes: [String], day: Int, language: Language) -> String {
        let pool = quotes.isEmpty ? builtinQuotes(language) : quotes
        guard !pool.isEmpty else { return "" }
        return pool[((day % pool.count) + pool.count) % pool.count]
    }
}
