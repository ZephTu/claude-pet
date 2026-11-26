import ClaudePetCore
import Foundation

/// The board's record of each card as it was last opened (SeenCards).
enum SeenCardsTests {
    static func run(_ t: Harness) {
        print("\n-- seen cards")

        let a: [String: Any] = ["s": "active", "a": ["T-1.1"]]
        let b: [String: Any] = ["s": "blocked", "a": [String]()]
        let one = SeenCards.merge([:], ["T-1": a])
        t.check("a record is kept under its task", (one["T-1"] as? [String: Any])?["s"] as? String == "active")
        let two = SeenCards.merge(one, ["T-1": b, "T-2": a])
        t.check("a record replaces the task's, others are added",
                (two["T-1"] as? [String: Any])?["s"] as? String == "blocked" && two.count == 2)
        t.check("null removes a record", SeenCards.merge(two, ["T-1": NSNull()]).keys.sorted() == ["T-2"])
        t.check("a record that isn't an object is left out",
                SeenCards.merge(one, ["T-1": "x", "T-3": 5]).count == 1
                && (SeenCards.merge(one, ["T-1": "x"])["T-1"] as? [String: Any])?["s"] as? String == "active")
        t.check("an empty or long id is left out",
                SeenCards.merge([:], ["": a, String(repeating: "x", count: 41): a]).isEmpty)
        t.check("a record past the size limit is left out",
                SeenCards.merge([:], ["T-1": ["n": String(repeating: "x", count: 5000)]]).isEmpty)
        var full: [String: Any] = [:]
        for i in 0..<SeenCards.maxCards { full["T-\(i)"] = a }
        let more = SeenCards.merge(full, ["T-new": a, "T-0": b])
        t.check("past the most cards no new one is added, but one kept can still change",
                more.count == SeenCards.maxCards && more["T-new"] == nil
                && (more["T-0"] as? [String: Any])?["s"] as? String == "blocked")
    }
}
