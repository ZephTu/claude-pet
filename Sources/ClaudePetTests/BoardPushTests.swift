import ClaudePetCore
import Foundation

/// Telling the board when its files change, instead of its polling every 4 seconds (BoardPush).
enum BoardPushTests {
    static func run(_ t: Harness) {
        print("\n-- board pushes")

        let home = "/Users/me"
        t.check("a card, an ask, focus and the inbox count",
                BoardPush.relevant("/hq/tasks/T-1-x/TASK.md") && BoardPush.relevant("/hq/tasks/T-1-x/asks.jsonl")
                && BoardPush.relevant("/hq/focus.json") && BoardPush.relevant("/hq/inbox.json"))
        t.check("a session's state, a subagent and what was read count",
                BoardPush.relevant(home + "/.claude/pet/sessions/abc.json")
                && BoardPush.relevant(home + "/.claude/pet/events/abc~def.json")
                && BoardPush.relevant(home + "/.claude/pet/read.json")
                && BoardPush.relevant(home + "/.claude/hq/state/sessions.json"))
        t.check("git's files and temporary files don't",
                !BoardPush.relevant("/hq/.git/index") && !BoardPush.relevant("/hq/.git/objects/ab/cd")
                && !BoardPush.relevant("/hq/tasks/T-1-x/.hq-k2j3") && !BoardPush.relevant("/hq/.DS_Store")
                && !BoardPush.relevant("/hq/tasks/T-1-x/.TASK.md.swp") && !BoardPush.relevant("/hq/tasks/T-1-x/TASK.md~"))
        t.check("the pet's files the board doesn't read don't",
                !BoardPush.relevant(home + "/.claude/pet/activity/abc.jsonl")
                && !BoardPush.relevant(home + "/.claude/pet/hud-usage.json")
                && !BoardPush.relevant(home + "/.claude/pet/usage-seen.json")
                && !BoardPush.relevant(home + "/.claude/pet/jumps.jsonl"))
        t.check("the pet's folder itself doesn't (its files say what changed)",
                !BoardPush.relevant(home + "/.claude/pet") && !BoardPush.relevant(home + "/.claude/pet/activity"))
        t.check("pushes are no closer than the old poll", PushGate().gap == 4)
        t.check("a card named like a pet file still counts",
                BoardPush.relevant("/hq/tasks/T-1-x/hud-usage.json") && BoardPush.relevant("/hq/activity/x.md"))

        let head = String(decoding: BoardPush.streamHead(), as: UTF8.self)
        t.check("the stream's head: an event stream, no length, never kept",
                head.hasPrefix("HTTP/1.1 200 OK\r\n") && head.contains("Content-Type: text/event-stream")
                && !head.contains("Content-Length") && head.contains("Cache-Control: no-store") && head.hasSuffix("\r\n\r\n"))
        t.check("an event is one changed block; a ping is a comment",
                String(decoding: BoardPush.event(7), as: UTF8.self) == "event: changed\ndata: 7\n\n"
                && String(decoding: BoardPush.ping, as: UTF8.self).hasPrefix(":"))

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var g = PushGate(quiet: 0.3, gap: 2)
        let first = g.note(t0)
        t.check("the first change pushes once it has gone quiet", first == t0.addingTimeInterval(0.3))
        t.check("more of the same burst add nothing", g.note(t0.addingTimeInterval(0.1)) == nil && g.note(t0.addingTimeInterval(0.2)) == nil)
        g.fired(t0.addingTimeInterval(0.3))
        t.check("a change right after a push waits out the gap",
                g.note(t0.addingTimeInterval(0.5)) == t0.addingTimeInterval(2.3))
        g.fired(t0.addingTimeInterval(2.3))
        t.check("a change long after is pushed after the quiet time only",
                g.note(t0.addingTimeInterval(10)) == t0.addingTimeInterval(10.3))
    }
}
