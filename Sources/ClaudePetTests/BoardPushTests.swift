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
        t.check("a card named like a pet file still counts",
                BoardPush.relevant("/hq/tasks/T-1-x/hud-usage.json") && BoardPush.relevant("/hq/activity/x.md"))

        let head = String(decoding: BoardPush.streamHead(), as: UTF8.self)
        t.check("the stream's head: an event stream, no length, never kept",
                head.hasPrefix("HTTP/1.1 200 OK\r\n") && head.contains("Content-Type: text/event-stream")
                && !head.contains("Content-Length") && head.contains("Cache-Control: no-store") && head.hasSuffix("\r\n\r\n"))
        t.check("an event is one changed block; a ping is a comment",
                String(decoding: BoardPush.event(7), as: UTF8.self) == "event: changed\ndata: 7\n\n"
                && String(decoding: BoardPush.ping, as: UTF8.self).hasPrefix(":"))

        t.check("lock files and hq's locks don't",
                !BoardPush.relevant(home + "/.claude/hq/state/sessions.json.lock")
                && !BoardPush.relevant(home + "/.claude/hq/state/locks/T-1"))
        t.check("lost events count, wherever they are reported",
                BoardPush.relevant(home + "/.claude/pet", flags: BoardPush.mustScanSubDirs)
                && BoardPush.relevant("/hq/.git", flags: BoardPush.userDropped | BoardPush.mustScanSubDirs)
                && BoardPush.relevant("/", flags: BoardPush.kernelDropped))

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let at = { (s: TimeInterval) in t0.addingTimeInterval(s) }
        let same = { (a: Date, b: Date) in abs(a.timeIntervalSince(b)) < 1e-6 }
        var g = PushGate(quiet: 0.3, maxWait: 1.5, gap: 4)
        t.check("the first change pushes once it has gone quiet", same(g.note(t0), at(0.3)))
        t.check("each further write of the burst moves the push on",
                same(g.note(at(0.2)), at(0.5)) && same(g.note(at(0.4)), at(0.7)))
        t.check("a burst that never goes quiet is pushed maxWait after its first write",
                same(g.note(at(1.0)), at(1.3)) && same(g.note(at(1.4)), at(1.5)))
        g.fired(at(1.5))
        t.check("a change right after a push waits out the gap", same(g.note(at(2)), at(5.5)))
        g.fired(at(5.5))
        t.check("a change long after is pushed after the quiet time only", same(g.note(at(20)), at(20.3)))
        t.check("pushes are no closer than the old poll", PushGate().gap == 4)
    }
}
