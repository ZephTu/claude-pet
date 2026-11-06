import Foundation

/// What a session's transcript says about the conversation as a whole: how
/// many turns it has had and how full its context window is.
///
/// Turns: the hook keeps a counter of its own (`turn` in the session file), but
/// that file is deleted at SessionEnd, so a resumed session started again from
/// 1 while its conversation went on from 40. The transcript is the one record
/// that survives: Claude Code appends to the same file across resumes and
/// compactions.
///
/// A turn is a prompt a person typed. Claude Code marks those lines with
/// `"origin":{"kind":"human"}` — tool results, injected context, task
/// notifications and compaction summaries do not carry it. A message typed
/// while a turn is still running joins that turn and repeats its promptId, so
/// it is not counted again.
///
/// Context: every reply records the tokens its request sent, which is how full
/// the window was at that moment, and a compaction shows up as the next reply
/// sending far fewer. The statusline is told the same number as a percentage,
/// but it only runs while Claude Code is drawing and only when wired up; the
/// transcript is always there.
///
/// Transcripts run to a hundred megabytes, so this reads by bytes, never
/// parses JSON, and picks up where the last call stopped.
public enum TranscriptStats {
    public struct Progress: Sendable, Equatable {
        /// Bytes already read: always the start of a line.
        public var offset = 0
        public var turns = 0
        public var lastPrompt = ""
        /// Tokens the last reply's request sent; 0 before the first reply.
        public var contextTokens = 0
        /// The model that request asked for, "[1m]" and all.
        public var model = ""

        public init() {}

        /// How full the context window is, 0-100, or nil before any reply.
        public var contextPercent: Int? {
            guard contextTokens > 0 else { return nil }
            let window = max(TranscriptStats.window(model: model), contextTokens)
            return min(100, Int((Double(contextTokens) * 100 / Double(window)).rounded()))
        }
    }

    static let marker = Array(#""origin":{"kind":"human"}"#.utf8)
    static let promptKey = Array(#""promptId":""#.utf8)
    /// Only a reply's own usage starts this way; the keys inside it follow.
    static let usageKey = Array(#""usage":{"input_tokens":"#.utf8)
    static let tokenKeys = [usageKey, Array(#""cache_creation_input_tokens":"#.utf8),
                            Array(#""cache_read_input_tokens":"#.utf8)]
    static let requestedModelKey = Array(#""requestedModel":""#.utf8)
    static let modelKey = Array(#""model":""#.utf8)

    /// `progress` moved on through `data`, the whole transcript as it is now.
    /// A line still being written is left for next time.
    public static func advance(_ progress: Progress, through data: Data) -> Progress {
        // Shorter than what was read: not the file that was read.
        var p = data.count < progress.offset ? Progress() : progress
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var end = raw.count
            // Everything up to the last whole line can be read now.
            while end > p.offset, base[end - 1] != 0x0A { end -= 1 }
            guard end > p.offset else { return }

            var at = p.offset
            while let hit = find(marker, in: base, from: at, to: end) {
                let line = bounds(of: hit, in: base, from: at, to: end)
                let prompt = string(after: promptKey, in: base, line)
                if prompt.isEmpty || prompt != p.lastPrompt { p.turns += 1 }
                p.lastPrompt = prompt
                at = line.upperBound + 1
            }

            // Only the newest reply matters, so look for it from the end.
            var last: Range<Int>?
            at = p.offset
            while let hit = find(usageKey, in: base, from: at, to: end) {
                let line = bounds(of: hit, in: base, from: at, to: end)
                at = line.upperBound + 1
                // An API error is written as a reply with no tokens behind it.
                if tokens(in: base, from: hit, to: line.upperBound) > 0 { last = line }
            }
            if let last, let hit = find(usageKey, in: base, from: last.lowerBound, to: last.upperBound) {
                p.contextTokens = tokens(in: base, from: hit, to: last.upperBound)
                let requested = string(after: requestedModelKey, in: base, last)
                p.model = requested.isEmpty ? string(after: modelKey, in: base, last) : requested
            }
            p.offset = end
        }
        return p
    }

    /// The context window Claude Code gives a model, from the table it ships.
    /// Every model since Opus 4.7 and Sonnet 5 has a million tokens natively;
    /// before that it was 200k unless "[1m]" asked for more. A model this does
    /// not know is assumed to be new, and so to have the million.
    public static func window(model: String) -> Int {
        let m = model.lowercased()
        if m.contains("[1m]") { return 1_000_000 }
        let older = ["claude-3", "claude-haiku-4", "claude-sonnet-4", "claude-opus-4-0",
                     "claude-opus-4-1", "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-2"]
        return older.contains { m.hasPrefix($0) } ? 200_000 : 1_000_000
    }

    /// Where Claude Code keeps a session's transcript when the hook did not
    /// say: the working directory with every non-alphanumeric turned into "-".
    public static func defaultTranscript(cwd: String, sessionId: String, home: String) -> String {
        let folder = String(cwd.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        return home + "/.claude/projects/" + folder + "/" + sessionId + ".jsonl"
    }

    /// input + cache creation + cache read, read from the usage at `from`.
    private static func tokens(in base: UnsafePointer<UInt8>, from: Int, to: Int) -> Int {
        tokenKeys.reduce(0) { sum, key in
            guard let k = find(key, in: base, from: from, to: to) else { return sum }
            var i = k + key.count, n = 0
            while i < to, base[i] >= 0x30, base[i] <= 0x39 {
                n = n * 10 + Int(base[i] - 0x30)
                i += 1
            }
            return sum + n
        }
    }

    /// The line around `hit`, without its newline. `from` is a line start and
    /// `to` ends a line, so both ends are found.
    private static func bounds(of hit: Int, in base: UnsafePointer<UInt8>,
                               from: Int, to: Int) -> Range<Int> {
        var start = hit
        while start > from, base[start - 1] != 0x0A { start -= 1 }
        let stop = find([0x0A], in: base, from: hit, to: to) ?? to
        return start..<stop
    }

    private static func string(after key: [UInt8], in base: UnsafePointer<UInt8>,
                               _ line: Range<Int>) -> String {
        guard let k = find(key, in: base, from: line.lowerBound, to: line.upperBound) else { return "" }
        let start = k + key.count
        var stop = start
        while stop < line.upperBound, base[stop] != 0x22 { stop += 1 }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: stop - start),
                      as: UTF8.self)
    }

    private static func find(_ needle: [UInt8], in base: UnsafePointer<UInt8>,
                             from: Int, to: Int) -> Int? {
        guard to - from >= needle.count else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let found = memmem(base + from, to - from, n.baseAddress, n.count) else { return nil }
            return UnsafeRawPointer(found) - UnsafeRawPointer(base)
        }
    }
}
