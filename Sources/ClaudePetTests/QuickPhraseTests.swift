import ClaudePetCore
import Foundation

/// Quick phrases: cleaning the board's list, and suggestions from the prompt history.
enum QuickPhraseTests {
    static func run(_ t: Harness) {
        print("\n-- quick phrases")

        t.check("a list is trimmed, without empties or repeats",
                QuickPhrases.clean(["  好 ", "", "好。", "继续", 3, "Continue", "continue!"]) == ["好", "继续", "Continue"])
        t.check("a list is clipped to the most phrases",
                QuickPhrases.clean((0..<100).map { "p\($0)" }).count == QuickPhrases.maxCount)
        t.check("a phrase is clipped to its longest",
                QuickPhrases.clean([String(repeating: "x", count: 1000)]).first?.count == QuickPhrases.maxLength)
        t.check("closing punctuation and case don't make another phrase",
                QuickPhrases.key("进度怎么样了？") == QuickPhrases.key("进度怎么样了") && QuickPhrases.key("OK!") == "ok")

        func line(_ display: String, paste: String? = nil) -> String {
            var d: [String: Any] = ["display": display, "pastedContents": [String: Any]()]
            if let p = paste { d["pastedContents"] = ["1": ["id": 1, "type": "text", "content": p]] }
            return String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self)
        }
        let lines = [
            line("好"), line("好"), line("好。"), line("继续"), line("继续"),
            line("进度怎么样了"), line("进度怎么样了？"), line("进度怎么样了"),
            line("/compact"), line("/compact"), line("A"), line("A"), line("only once"),
            line("first line\nsecond"), line("first line\nsecond"),
            line("[HQ board] T-1.1 \"Ship it?\": Answer: 部署吧"),
            line("[Pasted text #1 +3 lines]", paste: "[HQ board] Answers:\n- T-1.2 \"x\": Answer: 部署吧\n- T-1.3 \"y\": Yes — go ahead as you suggested\n- T-1.4 \"z\": Yes — go ahead as you suggested"),
            line("Reply with exactly one word: READY. Do not read, search or change any files at all."),
            line("Reply with exactly one word: READY. Do not read, search or change any files at all."),
            "not json",
        ]
        let s = QuickPhrases.suggest(historyLines: lines)
        t.check("suggestions: most sent first, the latest first among equals, written as most often", s.map(\.text) == ["进度怎么样了", "好", "部署吧", "继续"])
        t.check("suggestions count every way of writing it", s.first?.count == 3)
        t.check("board answers count only what was written, from a paste too", s.contains(QuickPhrases.Suggestion(text: "部署吧", count: 2)))
        t.check("commands, single letters, one-offs, many lines and long text are not suggested",
                !s.map(\.text).contains { ["/compact", "A", "only once"].contains($0) || $0.contains("READY") || $0.contains("first") })
        t.check("phrases already kept are not suggested again",
                !QuickPhrases.suggest(historyLines: lines, have: ["好！"]).map(\.text).contains("好"))
    }
}
