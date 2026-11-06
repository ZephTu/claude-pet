import Foundation

/// How many turns a session has had, counted from its transcript.
///
/// The hook keeps a counter of its own (`turn` in the session file), but that
/// file is deleted at SessionEnd, so a resumed session started again from 1
/// while its conversation went on from 40. The transcript is the one record
/// that survives: Claude Code appends to the same file across resumes and
/// compactions.
///
/// A turn is a prompt a person typed. Claude Code marks those lines with
/// `"origin":{"kind":"human"}` — tool results, injected context, task
/// notifications and compaction summaries do not carry it. A message typed
/// while a turn is still running joins that turn and repeats its promptId, so
/// it is not counted again.
///
/// Transcripts run to a hundred megabytes, so this reads by bytes, never
/// parses JSON, and picks up where the last call stopped.
public enum TurnCount {
    public struct Progress: Sendable, Equatable {
        /// Bytes already read: always the start of a line.
        public var offset = 0
        public var turns = 0
        public var lastPrompt = ""

        public init() {}
    }

    static let marker = Array(#""origin":{"kind":"human"}"#.utf8)
    static let promptKey = Array(#""promptId":""#.utf8)

    /// `progress` moved on through `data`, the whole transcript as it is now.
    /// A line still being written is left for next time.
    public static func advance(_ progress: Progress, through data: Data) -> Progress {
        // Shorter than what was read: not the file that was read.
        var p = data.count < progress.offset ? Progress() : progress
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let end = raw.count
            var at = p.offset
            while at < end {
                guard let hit = find(marker, in: base, from: at, to: end) else { break }
                guard let lineEnd = find([0x0A], in: base, from: hit, to: end) else { break }
                var lineStart = hit
                while lineStart > at, base[lineStart - 1] != 0x0A { lineStart -= 1 }
                let prompt = promptId(base, from: lineStart, to: lineEnd)
                if prompt.isEmpty || prompt != p.lastPrompt { p.turns += 1 }
                p.lastPrompt = prompt
                at = lineEnd + 1
            }
            // Everything up to the last whole line has been seen.
            var done = end
            while done > at, base[done - 1] != 0x0A { done -= 1 }
            p.offset = max(at, done)
        }
        return p
    }

    /// Where Claude Code keeps a session's transcript when the hook did not
    /// say: the working directory with every non-alphanumeric turned into "-".
    public static func defaultTranscript(cwd: String, sessionId: String, home: String) -> String {
        let folder = String(cwd.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        return home + "/.claude/projects/" + folder + "/" + sessionId + ".jsonl"
    }

    private static func promptId(_ base: UnsafePointer<UInt8>, from: Int, to: Int) -> String {
        guard let key = find(promptKey, in: base, from: from, to: to) else { return "" }
        let start = key + promptKey.count
        var stop = start
        while stop < to, base[stop] != 0x22 { stop += 1 }
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
