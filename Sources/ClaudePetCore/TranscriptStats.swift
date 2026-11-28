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
/// the window was at that moment. A compaction writes a boundary line saying
/// how big the conversation is now (`postTokens`), and that stands until the
/// next reply: after `/compact` there may be none for a long while. It is the
/// conversation alone, though — the next request also sends the system prompt,
/// the tools and the files Claude Code attaches again, 25-55k more — so what
/// that came to the last time is added: the reply after the previous
/// compaction less its `postTokens`, or before any, the session's first reply.
/// The statusline is told the same number as a percentage,
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
        /// The session's first reply, and what a request sent besides the conversation
        /// the last time a compaction was followed by one (0 until then).
        public var firstContext = 0
        public var overhead = 0
        /// A compaction with no reply after it yet: the size it gave (nil when it did not say).
        public var compacted: Int?? = nil

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
    static let boundaryKey = Array(#""subtype":"compact_boundary""#.utf8)
    static let postTokensKey = Array(#""postTokens":"#.utf8)
    /// A first reply is mostly system prompt and tools (25-55k); past this its prompt was a
    /// long paste, which a compaction does not carry over.
    public static let firstReplyCap = 60_000

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

            // Compactions in this stretch, in order, with the size each gave.
            var boundaries: [(at: Int, post: Int?)] = []
            at = p.offset
            while let hit = find(boundaryKey, in: base, from: at, to: end) {
                let line = bounds(of: hit, in: base, from: at, to: end)
                at = line.upperBound + 1
                boundaries.append((line.lowerBound, number(after: postTokensKey, in: base, line)))
            }

            // Replies in order: the newest is the reading; the first after a compaction
            // shows what a request sends on top of the conversation.
            var last: Range<Int>?, b = 0
            at = p.offset
            while let hit = find(usageKey, in: base, from: at, to: end) {
                let line = bounds(of: hit, in: base, from: at, to: end)
                at = line.upperBound + 1
                // An API error is written as a reply with no tokens behind it.
                let n = tokens(in: base, from: hit, to: line.upperBound)
                guard n > 0 else { continue }
                while b < boundaries.count, boundaries[b].at < line.lowerBound {
                    p.compacted = .some(boundaries[b].post)
                    b += 1
                }
                if case let .some(post?) = p.compacted, post > 0 { p.overhead = max(0, n - post) }
                p.compacted = nil
                if p.firstContext == 0 { p.firstContext = n }
                last = line
            }
            if let last, let hit = find(usageKey, in: base, from: last.lowerBound, to: last.upperBound) {
                p.contextTokens = tokens(in: base, from: hit, to: last.upperBound)
                let requested = string(after: requestedModelKey, in: base, last)
                p.model = requested.isEmpty ? string(after: modelKey, in: base, last) : requested
            }

            // A compaction after that reply: the conversation is the summary now. A
            // boundary that does not say how big (older Claude Code) leaves no reading
            // rather than the size it had before.
            if b < boundaries.count {
                p.compacted = .some(boundaries[boundaries.count - 1].post)
                if case let .some(post?) = p.compacted, post > 0 {
                    p.contextTokens = post + (p.overhead > 0 ? p.overhead : min(p.firstContext, firstReplyCap))
                } else {
                    p.contextTokens = 0
                }
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

    /// The digits after `key` in `line`, or nil when the key is not there.
    private static func number(after key: [UInt8], in base: UnsafePointer<UInt8>,
                               _ line: Range<Int>) -> Int? {
        guard let k = find(key, in: base, from: line.lowerBound, to: line.upperBound) else { return nil }
        var i = k + key.count, n = 0
        while i < line.upperBound, base[i] >= 0x30, base[i] <= 0x39 {
            n = n * 10 + Int(base[i] - 0x30)
            i += 1
        }
        return n
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
        #if canImport(Darwin)
        return needle.withUnsafeBytes { n -> Int? in
            guard let found = memmem(base + from, to - from, n.baseAddress, n.count) else { return nil }
            return UnsafeRawPointer(found) - UnsafeRawPointer(base)
        }
        #else
        // No memmem on Windows: a plain scan for the first byte, then a compare.
        guard let first = needle.first else { return from }
        var i = from
        while i <= to - needle.count {
            if base[i] == first, (1..<needle.count).allSatisfy({ base[i + $0] == needle[$0] }) { return i }
            i += 1
        }
        return nil
        #endif
    }
}
