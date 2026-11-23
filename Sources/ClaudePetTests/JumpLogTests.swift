import ClaudePetCore
import Foundation

/// The jump log: which state a jump caught its session in, and the line it writes.
enum JumpLogTests {
    static func run(_ t: Harness) {
        print("\n-- jump log (what a session was doing when you jumped to it)")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func s(_ state: SessionActivity, detail: String = "", waitingOn: String = "", phase: String = "",
               agents: [String] = [], trouble: Date? = nil) -> SessionState {
            SessionState(sessionId: "s1", project: "p", cwd: "/p", state: state, tool: "", detail: detail,
                         since: t0, updatedAt: t0, waitingOn: waitingOn, phase: phase, troubleAt: trouble,
                         backgroundAgents: agents)
        }
        t.check("a permission prompt is permission",
                JumpLog.state(of: s(.waiting, waitingOn: "rm -rf build"), quiet: false) == .permission)
        t.check("waiting with no permission is a question",
                JumpLog.state(of: s(.waiting), quiet: false) == .question)
        t.check("busy is working", JumpLog.state(of: s(.busy), quiet: false) == .working)
        t.check("busy waiting on an agent is agent",
                JumpLog.state(of: s(.busy, phase: "awaiting-agent"), quiet: false) == .agent
                && JumpLog.state(of: s(.busy, agents: ["Explore"]), quiet: false) == .agent)
        t.check("busy gone quiet is interrupted", JumpLog.state(of: s(.busy), quiet: true) == .interrupted)
        t.check("an interrupted call the row still shows as working is working",
                JumpLog.state(of: s(.busy, trouble: t0.addingTimeInterval(5)), quiet: false) == .working)
        t.check("idle after a reply is replied", JumpLog.state(of: s(.idle, detail: "Done."), quiet: false) == .replied)
        t.check("idle with nothing said is idle", JumpLog.state(of: s(.idle), quiet: false) == .idle)
        t.check("no live session is gone", JumpLog.state(of: nil, quiet: false) == .gone)

        let full = JumpLog.line(JumpLog.Event(at: t0, session: "s1", source: "board-card", state: .permission,
                                              view: "today", task: "T-075", project: "claude-pet", context: 42,
                                              waited: 90, peekedAgo: 12, terminal: "orca"))
        let obj = (try? JSONSerialization.jsonObject(with: Data(full.utf8))) as? [String: Any] ?? [:]
        t.check("a line is one JSON object ending in a newline",
                full.hasSuffix("\n") && full.filter { $0 == "\n" }.count == 1 && obj["session"] as? String == "s1")
        t.check("a line carries state, source, task, context and peek",
                obj["state"] as? String == "permission" && obj["source"] as? String == "board-card"
                && obj["task"] as? String == "T-075" && obj["context"] as? Int == 42
                && obj["peekedAgo"] as? Int == 12 && obj["view"] as? String == "today")
        t.check("its time is ISO 8601 UTC", (obj["at"] as? String)?.hasSuffix("Z") == true)
        let bare = JumpLog.line(JumpLog.Event(at: t0, session: "s1", source: "hotkey", state: .gone))
        t.check("absent values are left out, not null",
                !bare.contains("null") && !bare.contains("task") && !bare.contains("peekedAgo"))

        let dir = FileManager.default.temporaryDirectory.appending(path: "jumplog-\(UUID().uuidString)")
        let file = dir.appending(path: "jumps.jsonl")
        JumpLog.append(JumpLog.Event(at: t0, session: "a", source: "pet-list", state: .idle), to: file)
        JumpLog.append(JumpLog.Event(at: t0, session: "b", source: "pet-list", state: .idle), to: file)
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        t.check("append creates the file and adds a line per jump", lines.count == 2)
        if let h = try? FileHandle(forWritingTo: file) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("{\"cut".utf8)); try? h.close()
        }
        JumpLog.append(JumpLog.Event(at: t0, session: "c", source: "pet-list", state: .idle), to: file)
        let after = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        t.check("a line cut short does not swallow the next one",
                after.count == 4 && after.last?.hasPrefix("{\"at\"") == true)
        try? FileManager.default.removeItem(at: dir)
    }
}
