import ClaudePetCore
import Foundation

/// Scheduled jobs: schedules, launchd plists, run records, Claude output, the job folder.
enum JobTests {
    static func run(_ t: Harness) {
        print("\n-- scheduled jobs")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

        // ---- the job file
        let sparse = try? JSONDecoder().decode(Job.self, from: Data(#"{"id":"j1","name":"x","prompt":"hi"}"#.utf8))
        t.check("a job with only an id, name and prompt loads with defaults",
                sparse?.kind == .claude && sparse?.schedule.kind == .weekdays && sparse?.timeoutMinutes == 20
                    && sparse?.sessionMode == .fresh && sparse?.keepSessions == 20 && sparse?.notify == .failure)
        t.check("a job without an id does not load",
                (try? JSONDecoder().decode(Job.self, from: Data(#"{"name":"x"}"#.utf8))) == nil)
        t.check("a sensible job has no problem", sparse?.problem() == nil)
        t.check("a nameless job is refused", Job(id: "j1", prompt: "p").problem() != nil)
        t.check("a Claude job needs a prompt", Job(id: "j1", name: "n").problem() != nil)
        t.check("a shell job needs a command", Job(id: "j1", name: "n", kind: .shell, prompt: "p").problem() != nil)
        t.check("an id that could escape a path is refused", Job(id: "../x", name: "n", prompt: "p").problem() != nil)
        t.check("a model name with shell characters is refused",
                Job(id: "j1", name: "n", prompt: "p", model: "opus; rm").problem() != nil)
        t.check("new ids are valid", Jobs.isValidID(Jobs.newID()))

        // ---- schedules
        let weekdays = Schedule(kind: .weekdays, hour: 9, minute: 0)
        let wdIntervals = (try? weekdays.spec()?.launchdIntervals()) ?? []
        t.check("weekdays at 9:00 is five launchd times, Monday to Friday",
                wdIntervals.count == 5 && wdIntervals.map { $0["Weekday"]! } == [1, 2, 3, 4, 5]
                    && wdIntervals.allSatisfy { $0["Hour"] == 9 && $0["Minute"] == 0 })
        let weekly = Schedule(kind: .weekly, hour: 3, minute: 30, days: [7, 1])
        t.check("weekly Sunday counts as cron's 0", (try? weekly.spec())??.weekdays == [0, 1])

        let c = try? CronSpec.parse("*/15 9-17 * * 1-5")
        t.check("cron steps and ranges", c?.minutes == [0, 15, 30, 45] && c?.hours == Array(9...17) && c?.weekdays == [1, 2, 3, 4, 5])
        t.check("…and become one launchd time per combination", (try? c?.launchdIntervals())??.count == 4 * 9 * 5)
        t.check("every minute is one launchd entry that names nothing",
                (try? CronSpec.parse("* * * * *").launchdIntervals()) == [[:]])
        t.check("names for months and days", (try? CronSpec.parse("0 9 * JAN MON")).map { $0.months == [1] && $0.weekdays == [1] } == true)
        t.check("weekday 7 is Sunday", (try? CronSpec.parse("0 9 * * 7"))?.weekdays == [0])
        t.check("all seven weekdays is any day", (try? CronSpec.parse("0 9 * * 0-6"))?.weekdays == nil)
        let both = try? CronSpec.parse("0 0 1 * 1")
        t.check("day of month AND weekday: either one, as cron does",
                (try? both?.launchdIntervals()) == [["Minute": 0, "Hour": 0, "Day": 1], ["Minute": 0, "Hour": 0, "Weekday": 1]])
        for bad in ["* * * *", "61 * * * *", "*/0 * * * *", "5-1 * * * *", "0 9 * * FUN"] {
            t.check("cron \"\(bad)\" is refused with a reason",
                    Schedule(kind: .cron, cron: bad).problem().map { !$0.isEmpty } == true)
        }
        t.check("a cron that would need too many launchd entries is refused",
                Schedule(kind: .cron, cron: "0-58 0-22 * * *").problem() != nil)
        t.check("…while one that only narrows the months is fine", Schedule(kind: .cron, cron: "* * * 1-6 *").problem() == nil)
        t.check("an interval of zero is refused", Schedule(kind: .every, everyMinutes: 0).problem() != nil)
        t.check("weekly with no day is refused", Schedule(kind: .weekly, days: []).problem() != nil)

        // Saturday 2026-11-21 10:00 UTC.
        let sat = at("2026-11-21T10:00:00Z")
        t.check("weekdays at 9 after Saturday morning: Monday, Tuesday, Wednesday",
                weekdays.nextRuns(after: sat, count: 3, anchor: nil, calendar: utc)
                    == [at("2026-11-23T09:00:00Z"), at("2026-11-24T09:00:00Z"), at("2026-11-25T09:00:00Z")])
        t.check("daily at 10:00 exactly now is tomorrow, not now",
                Schedule(kind: .daily, hour: 10, minute: 0).nextRuns(after: sat, count: 1, anchor: nil, calendar: utc)
                    == [at("2026-11-22T10:00:00Z")])
        t.check("first of the month or a Monday",
                both?.nextRuns(after: sat, count: 3, calendar: utc)
                    == [at("2026-11-23T00:00:00Z"), at("2026-11-30T00:00:00Z"), at("2026-12-01T00:00:00Z")])
        let every = Schedule(kind: .every, everyMinutes: 30)
        t.check("every 30 minutes counts from when it was switched on",
                every.nextRuns(after: sat, count: 2, anchor: at("2026-11-21T09:50:00Z"))
                    == [at("2026-11-21T10:20:00Z"), at("2026-11-21T10:50:00Z")])
        t.check("…skipping the times already past",
                every.nextRuns(after: sat, count: 1, anchor: at("2026-11-21T08:05:00Z")) == [at("2026-11-21T10:05:00Z")])

        // ---- the LaunchAgent
        let job = Job(id: "jtest", name: "n", prompt: "p", schedule: weekdays)
        if let data = try? LaunchAgent.plist(for: job, program: "/x/pet-emit", jobsDirectory: URL(fileURLWithPath: "/j")),
           let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            t.check("the agent is labelled for the job", p["Label"] as? String == "local.claudepet.job.jtest")
            t.check("it runs the runner for this job", p["ProgramArguments"] as? [String] == ["/x/pet-emit", "--run-job", "jtest"])
            t.check("it runs on the calendar", (p["StartCalendarInterval"] as? [[String: Int]])?.count == 5)
            t.check("it doesn't run on load", p["RunAtLoad"] as? Bool == false)
            t.check("launchd's own output goes to the job folder", p["StandardErrorPath"] as? String == "/j/jtest/launchd.log")
        } else {
            t.check("the agent plist builds", false)
        }
        let everyJob = Job(id: "jtest", name: "n", prompt: "p", schedule: every)
        let ep = (try? LaunchAgent.plist(for: everyJob, program: "/x")).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        t.check("every N minutes is launchd's interval, in seconds", ep?["StartInterval"] as? Int == 1800)

        // ---- run records
        let records = """
        {"run":"r1","event":"start","at":"2026-11-21T09:00:00Z","pid":11,"trigger":"schedule","sessionId":"s1"}
        {"run":"r1","event":"end","at":"2026-11-21T09:00:47Z","status":"ok","costUSD":0.08,"turns":6,"sessionId":"s1","summary":"all good","denials":1}
        {"run":"r2","event":"skip","at":"2026-11-21T09:30:00Z","summary":"busy"}
        {"run":"r3","event":"start","at":"2026-11-21T10:00:00Z","pid":12}
        {"run":"r4","event":"start","at":"2026-11-21T10:30:00Z","pid":13,"trigger":"manual"}
        not json
        """
        let runs = JobRun.parse(Data(records.utf8), alive: { $0 == 13 })
        t.check("runs read newest first", runs.map(\.id) == ["r4", "r3", "r2", "r1"])
        t.check("a start whose process is alive is running", runs.first?.status == .running && runs.first?.trigger == "manual")
        t.check("a start whose process is gone was lost", runs[1].status == .lost && runs[1].failed)
        t.check("a skip is its own record", runs[2].status == .skipped && runs[2].summary == "busy")
        t.check("an ended run carries what the end said",
                runs[3].status == .ok && runs[3].costUSD == 0.08 && runs[3].turns == 6 && runs[3].denials == 1
                    && runs[3].durationSeconds == 47 && !runs[3].failed)

        let withSessions = ["a", "b", "b", "c", "d"].enumerated().map { i, s in
            JobRun(id: "r\(i)", started: sat, ended: sat, status: .ok, trigger: "schedule", pid: nil, exitCode: 0,
                   costUSD: nil, turns: nil, sessionId: s, denials: 0, contextTokens: nil, summary: "", tail: "")
        }
        t.check("keeping 2 sessions prunes the older ones, each once",
                JobRun.sessionsToPrune(withSessions, keep: 2) == ["c", "d"])

        // ---- Claude's stream
        let stream = """
        {"type":"system","subtype":"init","session_id":"sess-1"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}},"session_id":"sess-1"}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Done: one file."}],"usage":{"input_tokens":3,"cache_read_input_tokens":1300,"cache_creation_input_tokens":0}}}
        {"type":"result","subtype":"success","is_error":false,"result":"Done: one file.","total_cost_usd":0.01,"num_turns":2,"permission_denials":[{"tool_name":"Write"}]}
        """
        let r = ClaudeStreamResult.parse(Data(stream.utf8))
        t.check("the stream gives the session", r.sessionId == "sess-1")
        t.check("…the reply, cost, turns and refusals",
                r.finished && !r.isError && r.reply == "Done: one file." && r.costUSD == 0.01 && r.turns == 2 && r.denials == 1)
        t.check("…and the context of the last call", r.contextTokens == 1303)
        let steps = ClaudeStreamResult.steps(Data(stream.utf8))
        t.check("steps pair a tool call with its result",
                steps.count == 2 && steps[0]["tool"] == "Bash" && steps[0]["result"] == "a.txt" && steps[1]["kind"] == "text")
        t.check("a stream that never finished is not a success", !ClaudeStreamResult.parse(Data(stream.split(separator: "\n").dropLast().joined(separator: "\n").utf8)).finished)

        // ---- the job folder
        let dir = FileManager.default.temporaryDirectory.appending(path: "pet-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JobStore(base: dir)
        try? store.save(Job(id: "jb", name: "B", prompt: "p"))
        try? store.save(Job(id: "ja", name: "A", prompt: "p"))
        t.check("saved jobs list by name", store.list().map(\.id) == ["ja", "jb"])
        t.check("a folder that isn't a job is ignored", {
            try? FileManager.default.createDirectory(at: dir.appending(path: "Not A Job"), withIntermediateDirectories: true)
            return store.list().count == 2
        }())
        for i in 0..<5 {
            store.append("ja", ["run": "r\(i)", "event": "start", "at": "2026-11-21T09:0\(i):00Z", "pid": 1])
            store.append("ja", ["run": "r\(i)", "event": "end", "at": "2026-11-21T09:0\(i):30Z", "status": "ok"])
            FileManager.default.createFile(atPath: store.logsURL("ja").appending(path: "r\(i).log").path, contents: Data())
        }
        t.check("appended runs read back", store.runs("ja").count == 5)
        store.trim("ja", keep: 2)
        t.check("trimming keeps the newest runs", store.runs("ja").map(\.id) == ["r4", "r3"])
        t.check("…and only their logs",
                Set((try? FileManager.default.contentsOfDirectory(atPath: store.logsURL("ja").path)) ?? []) == ["r3.log", "r4.log"])
        store.setState("ja") { $0["sessionId"] = "s9" }
        t.check("state is kept between runs", store.state("ja")["sessionId"] as? String == "s9")
        try? store.delete("ja")
        t.check("deleting a job removes its folder", store.load("ja") == nil && store.list().map(\.id) == ["jb"])
    }
}
