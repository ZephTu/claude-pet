import ClaudePetCore
import Foundation

/// The board's reading area: which paths it reads, and how it reads them.
enum DocReaderTests {
    static func run(_ t: Harness) {
        print("\n-- doc reader (Markdown and text files shown on the board)")

        let home = "/Users/me"
        t.check("a ~ path is under home", DocReader.resolve("~/notes/a.md", cwd: "", home: home) == "/Users/me/notes/a.md")
        t.check("a relative path is under cwd", DocReader.resolve("docs/a.md", cwd: "/repo", home: home) == "/repo/docs/a.md")
        t.check("a cwd written with ~ is expanded", DocReader.resolve("a.md", cwd: "~/repo", home: home) == "/Users/me/repo/a.md")
        t.check("../ is folded", DocReader.resolve("../b/a.md", cwd: "/repo/x", home: home) == "/repo/b/a.md")
        t.check(":line[:col] is dropped", DocReader.resolve("/r/a.md:12:3", cwd: "", home: home) == "/r/a.md")
        t.check("relative with no cwd is nil", DocReader.resolve("a.md", cwd: "", home: home) == nil)
        t.check("md, markdown and txt are documents",
                DocReader.isDocument("/a/B.MD") && DocReader.isDocument("x.markdown") && DocReader.isDocument("n.txt:4"))
        t.check("code and images are not", !DocReader.isDocument("a.swift") && !DocReader.isDocument("a.png") && !DocReader.isDocument("README"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docreader-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("a.md")
        try? Data("# Hi\n中文\n".utf8).write(to: md)
        let sh = dir.appendingPathComponent("run.sh")
        try? Data("echo".utf8).write(to: sh)

        var mtime = 0.0
        if case .success(.text(let p, let text, let m, let size)) = DocReader.read("a.md", cwd: dir.path) {
            mtime = m
            t.check("reads the text", text == "# Hi\n中文\n" && size == text.utf8.count && p.hasSuffix("/a.md"))
        } else {
            t.check("reads the text", false)
        }
        if case .success(.unchanged) = DocReader.read(md.path, cwd: "", since: mtime) {
            t.check("an unchanged file says so", true)
        } else {
            t.check("an unchanged file says so", false)
        }
        if case .success(.text) = DocReader.read(md.path, cwd: "", since: mtime - 10) {
            t.check("a changed mtime reads it again", true)
        } else {
            t.check("a changed mtime reads it again", false)
        }
        if case .failure(.notDocument) = DocReader.read(sh.path, cwd: "") { t.check("a script is not read", true) } else { t.check("a script is not read", false) }
        if case .failure(.notDocument) = DocReader.read(dir.path, cwd: "") { t.check("a folder is not read", true) } else { t.check("a folder is not read", false) }
        if case .failure(.notFound) = DocReader.read("nope.md", cwd: dir.path) { t.check("a missing file is not found", true) } else { t.check("a missing file is not found", false) }

        let big = dir.appendingPathComponent("big.txt")
        try? Data(count: DocReader.maxBytes + 1).write(to: big)
        if case .failure(.tooBig) = DocReader.read(big.path, cwd: "") { t.check("a huge file is refused", true) } else { t.check("a huge file is refused", false) }
    }
}
