import Foundation

/// Quick phrases: replies the user sends often, kept once for the Mac's board and every phone's,
/// and offered by the board's message and answer boxes. Also the suggestions: what the user has
/// typed to sessions again and again, read from Claude Code's prompt history.
public enum QuickPhrases {
    public static let maxCount = 40
    public static let maxLength = 300

    /// A list as the board sent it: trimmed, without empties or repeats (same `key`), clipped.
    public static func clean(_ raw: [Any]) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for case let s as String in raw {
            let t = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            let k = key(t)
            if k.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(t)
            if out.count == maxCount { break }
        }
        return out
    }

    /// What makes two replies the same one: case, runs of white space and closing punctuation
    /// don't count ("进度怎么样了" and "进度怎么样了？").
    public static func key(_ s: String) -> String {
        var t = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = t.last, "。.!！?？~～,，、;；…".contains(c) { t.removeLast() }
        return t
    }

    public struct Suggestion: Equatable, Sendable {
        public let text: String
        public let count: Int
        public init(text: String, count: Int) { self.text = text; self.count = count }
    }

    /// Replies sent at least `minCount` times, most frequent first, leaving out those in `have`.
    /// `lines`: Claude Code's ~/.claude/history.jsonl, one prompt per line (`display`, with pasted
    /// text in `pastedContents`). A board answer arrives there as "[HQ board] …" with one
    /// `"…": Answer: <what you wrote>` line per ask; its canned answers (Yes, No…) are the board's
    /// buttons already, so only the written ones count.
    public static func suggest(historyLines lines: [String], have: [String] = [], minCount: Int = 2,
                               limit: Int = 12) -> [Suggestion] {
        var counts: [String: Int] = [:], variants: [String: [String: Int]] = [:], last: [String: Int] = [:]
        let skip = Set(have.map(key))
        func add(_ raw: String, _ at: Int) {
            let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !t.isEmpty, t.count <= 60, !t.contains("\n") else { return }
            // Commands, shell escapes, memory notes, hook output and pasted things aren't replies;
            // nor is one letter or digit (an option picked in the terminal).
            if let c = t.first, "/!#<[".contains(c) { return }
            if t.count == 1, t.first!.isASCII { return }
            let k = key(t)
            guard !k.isEmpty, !skip.contains(k) else { return }
            counts[k, default: 0] += 1
            variants[k, default: [:]][t, default: 0] += 1
            last[k] = at
        }
        for (i, line) in lines.enumerated() {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  var text = d["display"] as? String else { continue }
            // A paste shows as "[Pasted text #3 +13 lines]": the words are in pastedContents.
            if let pasted = d["pastedContents"] as? [String: Any], text.hasPrefix("[Pasted text #"),
               let only = pasted.values.first as? [String: Any], pasted.count == 1,
               let content = only["content"] as? String {
                text = content
            }
            if text.hasPrefix("[HQ board]") {
                for l in text.split(separator: "\n") {
                    if let r = l.range(of: "\": Answer: ") { add(String(l[r.upperBound...]), i) }
                }
                continue
            }
            if text.contains("\n") { continue }
            add(text, i)
        }
        return counts.filter { $0.value >= minCount }
            .sorted { $0.value != $1.value ? $0.value > $1.value : (last[$0.key] ?? 0) > (last[$1.key] ?? 0) }
            .prefix(limit)
            .map { k, n in
                // Written the way it was written most often.
                let v = variants[k]!.max { $0.value != $1.value ? $0.value < $1.value : $0.key.count > $1.key.count }!.key
                return Suggestion(text: v, count: n)
            }
    }
}
