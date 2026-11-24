import Foundation

/// The board's reading area: a Markdown or plain-text file named in a conversation, on a card or in
/// another document, read so the board can show it itself instead of handing it to another app.
/// Only text documents, and only so much of one: anything else still opens with its own app.
public enum DocReader {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]
    public static let maxBytes = 4 << 20

    public enum Failure: Error, Equatable {
        case relativeWithoutDir      // a relative path and no folder to read it from
        case notFound(String)
        case notDocument(String)     // a folder, or not one of `extensions`
        case tooBig(String)
        case unreadable(String)
    }

    public enum Outcome: Equatable {
        case text(path: String, text: String, mtime: Double, size: Int)
        /// The file is as it was when last read (`since`): the board keeps what it shows.
        case unchanged(path: String, mtime: Double)
    }

    /// A path as written — `~/x.md`, `notes.md:12`, or relative to `cwd` — made absolute and
    /// standardized. Nil for a relative path with no folder to resolve it in.
    public static func resolve(_ raw: String, cwd: String, home: String = NSHomeDirectory()) -> String? {
        func expand(_ p: String) -> String { p == "~" || p.hasPrefix("~/") ? home + p.dropFirst() : p }
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { path.removeSubrange(r) }
        path = expand(path)
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("/") {
            let dir = expand(cwd.trimmingCharacters(in: .whitespacesAndNewlines))
            guard dir.hasPrefix("/") else { return nil }
            path = (dir as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether the reading area shows this path (by its name alone; `read` checks the file).
    public static func isDocument(_ path: String) -> Bool {
        var p = path
        if let r = p.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { p.removeSubrange(r) }
        return extensions.contains(URL(fileURLWithPath: p).pathExtension.lowercased())
    }

    /// Reads the document; `since` is the mtime the board already shows, if any.
    public static func read(_ raw: String, cwd: String, since: Double? = nil,
                            home: String = NSHomeDirectory()) -> Result<Outcome, Failure> {
        guard let path = resolve(raw, cwd: cwd, home: home) else { return .failure(.relativeWithoutDir) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .failure(.notFound(path)) }
        guard isDocument(path) else { return .failure(.notDocument(path)) }
        // The file a link points to (CLAUDE.md → AGENTS.md): its size, its mtime, its bytes. The
        // tab keeps the path as written, so links in it resolve from where it was opened.
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attrs = (try? fm.attributesOfItem(atPath: target)) ?? [:]
        // A regular file only: not a folder, and not a pipe or device that would block the read.
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return .failure(.notDocument(path)) }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard size <= maxBytes else { return .failure(.tooBig(path)) }
        if let since, since == mtime { return .success(.unchanged(path: path, mtime: mtime)) }
        guard let data = fm.contents(atPath: target), data.count <= maxBytes else { return .failure(.unreadable(path)) }
        // Not UTF-8 throughout (a stray Latin-1 byte): shown with replacement marks, not refused.
        return .success(.text(path: path, text: String(decoding: data, as: UTF8.self), mtime: mtime, size: data.count))
    }
}
