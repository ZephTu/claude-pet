import ClaudePetCore
import Foundation

/// What the HQ board keeps beside hq for a shell that is not the Mac app (the Windows spike), and
/// its reading area. The Mac app keeps these in its defaults (BoardPrefs, BoardSeen,
/// BoardPhrases in BoardServer.swift); here they are one file beside the rest of the pet's data:
///   board.json   {"prefs": {key: "1"…}, "seen": {taskId: record}, "phrases": [text]}
/// `pet-emit --board` reads one request as JSON on stdin — {"op": …} and its fields, as the
/// board page sends them — and prints {"result": …} or {"error": "…"}. The Mac app does not use it.
enum PetBoard {
    static var file: URL { HookEmit.baseDirectory.appending(path: "board.json") }
    /// The page's own storage keys (BoardPrefs.keys on the Mac).
    static let prefKeys = ["hq-skip-perms", "hq-launch", "hq-finish-stop"]

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return doc
    }

    private static func save(_ change: (inout [String: Any]) -> Void) {
        PetMarks.update(file) {
            var doc = load()
            change(&doc)
            return try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        }
    }

    static func handle(_ body: [String: Any]) -> (Any?, String?) {
        func str(_ key: String) -> String { body[key] as? String ?? "" }
        switch body["op"] as? String ?? "" {
        case "store":
            // The page's `pet` read takes these three (BoardWindow's "pet": prefs, phrases, seenCards).
            let doc = load()
            return (["prefs": doc["prefs"] as? [String: String] ?? [:],
                     "phrases": QuickPhrases.clean(doc["phrases"] as? [Any] ?? []),
                     "seenCards": doc["seen"] as? [String: Any] ?? [:]], nil)
        case "board-prefs":
            let prefs = body["prefs"] as? [String: Any] ?? [:]
            save { doc in
                var all = doc["prefs"] as? [String: String] ?? [:]
                for k in prefKeys { if let v = prefs[k] as? String { all[k] = String(v.prefix(40)) } }
                doc["prefs"] = all
            }
            return (["ok": true], nil)
        case "card-seen":
            let cards = body["cards"] as? [String: Any] ?? [:]
            save { doc in doc["seen"] = SeenCards.merge(doc["seen"] as? [String: Any] ?? [:], cards) }
            return (["ok": true], nil)
        case "phrases":
            var out: [String]?
            save { doc in
                out = QuickPhrases.apply(QuickPhrases.clean(doc["phrases"] as? [Any] ?? []), action: str("action"),
                                         text: str("text"), at: (body["at"] as? NSNumber)?.intValue)
                if let out { doc["phrases"] = out }
            }
            guard let out else { return (nil, "unknown phrase change") }
            return (["phrases": out], nil)
        case "phrase-suggest":
            let have = QuickPhrases.clean(load()["phrases"] as? [Any] ?? [])
            let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/history.jsonl")
            let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            let found = QuickPhrases.suggest(historyLines: text.split(separator: "\n").map(String.init), have: have)
            return (["suggestions": found.map { ["text": $0.text, "count": $0.count] }], nil)
        case "read-doc":
            // BoardWindow.readDoc.
            switch DocReader.read(str("path"), cwd: str("cwd"), since: (body["since"] as? NSNumber)?.doubleValue) {
            case .success(.text(let path, let text, let mtime, let size)):
                return (["path": path, "text": text, "mtime": mtime, "size": size], nil)
            case .success(.unchanged(let path, let mtime)):
                return (["path": path, "mtime": mtime, "unchanged": true], nil)
            case .failure(.relativeWithoutDir):
                return (nil, L("relative path and no working directory", "是相对路径，但没有工作目录"))
            case .failure(.notFound(let p)): return (nil, L("not found: \(p)", "找不到：\(p)"))
            case .failure(.notDocument(let p)): return (nil, L("not a Markdown or text file: \(p)", "不是 Markdown 或文本文件：\(p)"))
            case .failure(.tooBig(let p)): return (nil, L("too big to show here (over 4 MB): \(p)", "太大了，这里不显示（超过 4 MB）：\(p)"))
            case .failure(.unreadable(let p)): return (nil, L("can't read \(p)", "读不了 \(p)"))
            }
        default:
            return (nil, L("unknown operation", "未知操作"))
        }
    }

    /// `pet-emit --board`: one request on stdin, one answer on stdout.
    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let body = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let (result, error) = handle(body)
        var out: [String: Any] = [:]
        if let error { out["error"] = error } else { out["result"] = result ?? NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data(#"{"error":"bad answer"}"#.utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }
}
