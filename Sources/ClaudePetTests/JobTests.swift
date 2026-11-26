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
                    && sparse?.sessionMode == .fresh && sparse?.keepSessions == 20 && sparse?.notify == .failure
                    && sparse?.skipWeekPct == 90 && sparse?.skipFiveHourPct == 90 && sparse?.compactAbovePct == 50)
        t.check("a quota percentage over 100 is refused", Job(id: "j1", name: "n", prompt: "p", skipWeekPct: 120).problem() != nil)
        t.check("a compaction percentage over 100 is refused", Job(id: "j1", name: "n", prompt: "p", compactAbovePct: 101).problem() != nil)
        let half = Job(id: "j1", name: "n", prompt: "p", compactAbovePct: 50)
        t.check("a resumed session compacts at its percentage of a small window",
                half.shouldCompact(contextTokens: 100_000, window: 200_000) && !half.shouldCompact(contextTokens: 90_000, window: 200_000))
        t.check("a 1M window compacts at the ceiling, not at half a million",
                half.shouldCompact(contextTokens: 188_000, window: 1_000_000) && !half.shouldCompact(contextTokens: 120_000, window: 1_000_000))
        t.check("a compaction percentage of 0 never compacts",
                !Job(id: "j1", name: "n", prompt: "p", compactAbovePct: 0).shouldCompact(contextTokens: 900_000, window: 1_000_000))
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
        t.check("a job without an agent or allowed tools runs as plain Claude Code",
                sparse?.agent == "" && sparse?.allowedTools == [])
        let sec = try? JSONDecoder().decode(Job.self, from: Data(#"{"id":"secretary","name":"x","prompt":"hi","agent":"secretary","allowedTools":["Read","Bash(~/.claude/hq/bin/hq:*)"]}"#.utf8))
        t.check("a job's agent and allowed tools load",
                sec?.agent == "secretary" && sec?.allowedTools == ["Read", "Bash(~/.claude/hq/bin/hq:*)"] && sec?.problem() == nil)
        let round = sec.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
        t.check("a job's agent and allowed tools survive a save", round?.agent == "secretary" && round?.allowedTools == sec?.allowedTools)
        t.check("an agent name with shell characters is refused",
                Job(id: "j1", name: "n", prompt: "p", agent: "sec; rm").problem() != nil)

        // ---- a duty's recurring work
        let rc = Recurring.command(hq: "/Users/a b/.claude/hq/bin/hq", project: "ci-oncall", template: "Bob's 值班交接")
        t.check("a recurring rule's command quotes every part",
                rc == #"'/Users/a b/.claude/hq/bin/hq' new --project='ci-oncall' --template='Bob'\''s 值班交接'"#)
        let back = Recurring.parse(rc)
        t.check("a recurring rule reads back from its command", back?.project == "ci-oncall" && back?.template == "Bob's 值班交接")
        t.check("other shell jobs are not recurring rules",
                Recurring.parse("'/x/hq' feed all") == nil && Recurring.parse("'/x/hq' new --project='p' --template='t'; rm -rf ~") == nil
                    && Recurring.parse(#"'/x/hq' new --project="$P" --template='t'"#) == nil)

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
        {"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.51,"resetsAt":1795201800},"seven_day":{"utilization":0.93,"resetsAt":1795320000}}}}
        {"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.534,"resetsAt":1795201800},"seven_day":{"utilization":0.94,"resetsAt":1795320000}}}}
        {"type":"result","subtype":"success","is_error":false,"result":"Done: one file.","total_cost_usd":0.01,"num_turns":2,"permission_denials":[{"tool_name":"Write"}],"modelUsage":{"m1":{"contextWindow":200000},"m2":{"contextWindow":1000000}}}
        """
        let r = ClaudeStreamResult.parse(Data(stream.utf8))
        t.check("the stream gives the session", r.sessionId == "sess-1")
        t.check("…the reply, cost, turns and refusals",
                r.finished && !r.isError && r.reply == "Done: one file." && r.costUSD == 0.01 && r.turns == 2 && r.denials == 1)
        t.check("…and the context of the last call", r.contextTokens == 1303)
        t.check("…and the model's context window", r.contextWindow == 1_000_000)
        t.check("the first rate-limit report is the quota before the run",
                r.quotaFirst == Quota(fiveHour: 51, fiveHourResetAt: Date(timeIntervalSince1970: 1795201800),
                                      week: 93, weekResetAt: Date(timeIntervalSince1970: 1795320000)))
        t.check("…the last, after it (rounded to whole percent)", r.quotaLast?.week == 94 && r.quotaLast?.fiveHour == 53)
        t.check("a report without windows is no reading", Quota(rateLimitInfo: ["status": "allowed"]) == nil)

        // ---- quota guard
        let soon = sat.addingTimeInterval(3600), gone = sat.addingTimeInterval(-60)
        let high = Quota.highest([Quota(fiveHour: 40, fiveHourResetAt: soon, week: 80, weekResetAt: soon),
                                  Quota(fiveHour: 70, fiveHourResetAt: soon, week: 99, weekResetAt: gone),
                                  Quota(week: 85, weekResetAt: soon)], now: sat)
        t.check("the highest reading counts, ignoring windows that have reset", high.fiveHour == 70 && high.week == 85)
        t.check("over the weekly limit skips, saying why",
                high.reasonToSkip(weekPct: 85, fiveHourPct: 90) == "skipped: weekly quota at 85% (limit 85%)")
        t.check("over the 5-hour limit skips", high.reasonToSkip(weekPct: 90, fiveHourPct: 60)?.contains("5-hour") == true)
        t.check("under both limits runs", high.reasonToSkip(weekPct: 90, fiveHourPct: 90) == nil)
        t.check("0 means don't check", high.reasonToSkip(weekPct: 0, fiveHourPct: 0) == nil)
        t.check("nothing known: run", Quota().reasonToSkip(weekPct: 1, fiveHourPct: 1) == nil)
        t.check("a quota reading survives the run record",
                JobRun.parse(Data(("{\"run\":\"q\",\"event\":\"start\",\"at\":\"2026-11-21T09:00:00Z\"}\n"
                    + "{\"run\":\"q\",\"event\":\"end\",\"at\":\"2026-11-21T09:01:00Z\",\"status\":\"ok\",\"contextWindow\":1000,"
                    + "\"quotaAfter\":\(String(decoding: try! JSONSerialization.data(withJSONObject: r.quotaLast!.json()), as: UTF8.self))}").utf8),
                             alive: { _ in false }).first.map { $0.quotaAfter == r.quotaLast && $0.contextWindow == 1000 } == true)
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
