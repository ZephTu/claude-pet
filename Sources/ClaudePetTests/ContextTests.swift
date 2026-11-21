import ClaudePetCore
import Foundation

/// Context measured against the auto-compact window, and the one reminder when a session gets long.
enum ContextTests {
    static func run(_ t: Harness) {
        print("\n-- context budget")
        typealias B = ContextBudget

        // ---- settings.json
        let settings = B.parse(Data(#"""
        {"model":"opus","modelSettings":{"claude-opus-5-5":{"effortLevel":"high","autoCompactWindow":300000},
         "claude-sonnet-5-5":{"effortLevel":"low"}}}
        """#.utf8))
        t.check("/autocompact's per-model window is read", settings.windows == ["claude-opus-5-5": 300_000])
        t.check("a model with no window set keeps the model's whole window",
                B.budget(model: "claude-sonnet-5-5", settings: settings) == 1_000_000)
        t.check("the set window is the budget", B.budget(model: "claude-opus-5-5", settings: settings) == 300_000)
        t.check("[1m] and a date suffix name the same model",
                B.modelKey("claude-opus-5-5[1m]") == "claude-opus-5-5"
                    && B.modelKey("Claude-Sonnet-4-5-20250929") == "claude-sonnet-4-5")
        t.check("a window wider than the model's is capped to it",
                B.budget(model: "claude-sonnet-4-5", settings: B.Settings(windows: ["claude-sonnet-4-5": 500_000])) == 200_000)
        let env = B.parse(Data(#"""
        {"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"400000","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"},
         "modelSettings":{"claude-opus-5-5":{"autoCompactWindow":300000}}}
        """#.utf8))
        t.check("the env window wins over /autocompact, and the percentage narrows it",
                B.budget(model: "claude-opus-5-5", settings: env) == 200_000)
        t.check("a percentage outside 1-100 is ignored",
                B.parse(Data(#"{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"150"}}"#.utf8)).percentOverride == nil)
        t.check("an unreadable file is no settings", B.parse(Data("nope".utf8)) == B.Settings())
        t.check("no model read yet is the million", B.budget(model: "", settings: settings) == 1_000_000)

        // ---- readings
        let r = B.Reading(tokens: 210_000, budget: 300_000)
        t.check("the share is of the window, not the million", r.percent == 70)
        t.check("over the window reads past 100%", B.Reading(tokens: 500_000, budget: 300_000).percent == 167)
        t.check("the reminder point is two thirds of the window", r.remindAt == 200_000)
        t.check("tokens read short", B.short(48_400) == "48k" && B.short(300_000) == "300k"
                    && B.short(1_000_000) == "1M" && B.short(1_240_000) == "1.2M")

        // ---- the alarm fires on crossing, once
        func reading(_ k: Int) -> B.Reading { B.Reading(tokens: k * 1000, budget: 300_000) }
        var alarm = ContextAlarm()
        alarm.observe(["a": reading(250), "b": reading(150)])
        t.check("a session first seen already long is not news", alarm.due.isEmpty)
        alarm.observe(["a": reading(260), "b": reading(205)])
        t.check("crossing two thirds makes it due", alarm.due == ["b"])
        alarm.observe(["a": reading(270), "b": reading(220)])
        t.check("staying above does not make it due twice", alarm.due == ["b"])
        alarm.said("b")
        alarm.observe(["a": reading(280), "b": reading(230)])
        t.check("once said, it is not said again", alarm.due.isEmpty)
        alarm.observe(["a": reading(280), "b": reading(190)])
        alarm.observe(["a": reading(280), "b": reading(210)])
        t.check("a dip that is not a compaction does not re-arm it", alarm.due.isEmpty)
        alarm.observe(["a": reading(280), "b": reading(40)])
        alarm.observe(["a": reading(280), "b": reading(210)])
        t.check("compacting re-arms it", alarm.due == ["b"])
        alarm.observe(["a": reading(280), "b": reading(190)])
        t.check("dropping back under before it was said takes it off", alarm.due.isEmpty)
        alarm.observe(["a": reading(280), "b": reading(210)])
        t.check("and it may cross again, since it was never said", alarm.due == ["b"])
        alarm.observe(["a": reading(280)])
        t.check("a session gone from the screen is forgotten", alarm.due.isEmpty && alarm.last["b"] == nil)
        alarm.observe(["a": reading(280), "c": reading(100)])
        alarm.observe(["a": reading(280), "c": B.Reading(tokens: 100_000, budget: 140_000)])
        t.check("lowering the window under a session is not a crossing", alarm.due.isEmpty)
        alarm.observe(["c": B.Reading(percentOnly: 90)])
        t.check("a bare percentage is never reminded about", alarm.due.isEmpty && alarm.last["c"] == nil)
        t.check("a bare percentage shows as it came", B.Reading(percentOnly: 42).percent == 42
                    && !B.Reading(percentOnly: 42).hasTokens)
        t.check("an exact key wins over one that strips down to it, whatever the order",
                B.budget(model: "claude-opus-5-5", settings: B.parse(Data(#"{"modelSettings":{"claude-opus-5-5[1m]":{"autoCompactWindow":500000},"claude-opus-5-5":{"autoCompactWindow":200000}}}"#.utf8))) == 200_000
                    && B.budget(model: "claude-opus-5-5[1m]", settings: B.parse(Data(#"{"modelSettings":{"claude-opus-5-5":{"autoCompactWindow":200000},"claude-opus-5-5[1m]":{"autoCompactWindow":500000}}}"#.utf8))) == 500_000)
        t.check("999.6k reads as 1M, not 1000k", B.short(999_600) == "1M")

        // ---- what the pet says
        let t0 = Date(timeIntervalSince1970: 1_789_467_600)
        let quiet = GlobalState(mood: .idle, sessions: [], waitingProject: nil)
        let note = Chatter.ContextNote(sessionId: "b", name: "claude-pet", tokens: 210_000)
        let line = Chatter.next(state: quiet, previous: quiet, usage: nil, now: t0,
                                lastSpoken: [:], lastAnything: nil, contextNote: note)
        t.check("a long session gets one line, naming it and what to do",
                line?.kind == .contextLong && line?.emphasis == "claude-pet"
                    && line?.text.contains("210k") == true && line?.text.contains("/compact") == true)
        t.check("it is a warning, which the open list does not hide",
                Chatter.bubble(for: .contextLong) == .warn && !Chatter.yieldsToList(.warn))
        t.check("it waits out the global cooldown like everything else",
                Chatter.next(state: quiet, previous: quiet, usage: nil, now: t0, lastSpoken: [:],
                             lastAnything: t0.addingTimeInterval(-60), contextNote: note) == nil)
        t.check("and its own",
                Chatter.next(state: quiet, previous: quiet, usage: nil, now: t0,
                             lastSpoken: [.contextLong: t0.addingTimeInterval(-120)],
                             lastAnything: nil, contextNote: note) == nil)
        let waiting = GlobalState(mood: .waiting, sessions: [], waitingProject: "p")
        t.check("nothing is said while a session waits on the user",
                Chatter.next(state: waiting, previous: quiet, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil, contextNote: note) == nil)
    }
}
