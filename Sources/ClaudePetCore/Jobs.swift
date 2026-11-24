import Foundation

/// Scheduled jobs: a shell command or a Claude prompt that runs on a timetable.
///
/// The pieces, and where each lives:
/// - a job is a folder under `~/.claude/pet/jobs/<id>/` holding `job.json` (what to run and
///   when), `runs.jsonl` (one line when a run starts, one when it ends), `state.json` (what the
///   runner carries between runs) and `logs/` (each run's output);
/// - macOS runs it: one LaunchAgent per enabled job, `local.claudepet.job.<id>`, whose program is
///   `pet-emit --run-job <id>` — so a job runs whether or not the pet is open, and a run missed
///   while the Mac slept happens once on wake;
/// - the runner (PetEmit/JobRunner.swift) does one run and records it;
/// - the app (ClaudePet/JobsController.swift) edits jobs for the board, installs the agents and
///   tells you when a run fails.
///
/// Everything here is pure or touches only those files, so it is shared by the runner and the
/// app and tested without either.
public enum Jobs {
    /// `PET_HOME` overrides the pet's folder, as it does for the hooks.
    public static var petHome: URL {
        ProcessInfo.processInfo.environment["PET_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet")
    }

    public static var directory: URL { petHome.appending(path: "jobs") }

    /// Ids end up in paths and launchd labels, so only a plain shape is accepted.
    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
    }

    public static func newID() -> String {
        "j" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    /// Set in the environment of everything a job runs. The hook sees it and stays out of the
    /// way: a scheduled run is not a session waiting on you.
    public static let environmentKey = "CLAUDE_PET_JOB"
    /// In a job's state: its `sessionId` was handed out before the session's first run (the
    /// secretary's), so the runner starts a session under it rather than a new one.
    public static let preassignedKey = "sessionPreassigned"

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - The job

public struct Job: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case claude, shell }
    /// What a Claude run may do without anyone there to approve it.
    /// `standard`: only what your Claude Code settings already allow; everything else is refused.
    public enum Permission: String, Codable, Sendable { case standard, edits, all }
    /// `fresh`: a new session every run. `resume`: the same session every run, continued.
    public enum SessionMode: String, Codable, Sendable { case fresh, resume }
    public enum Notify: String, Codable, Sendable { case failure, always, never }

    public var id: String
    public var name: String
    public var kind: Kind
    public var prompt: String
    public var command: String
    public var cwd: String
    public var schedule: Schedule
    public var enabled: Bool
    /// Empty: Claude Code's default model.
    public var model: String
    public var permission: Permission
    public var timeoutMinutes: Int
    /// Quota guard for Claude runs: skip a run while the subscription's weekly or five-hour
    /// limit is already used past this percentage, leaving the rest for your own work.
    /// 0: don't check. (A dollar limit was tried first: nobody could say what number to put in.)
    public var skipWeekPct: Int
    public var skipFiveHourPct: Int
    public var sessionMode: SessionMode
    /// Fresh sessions: how many of the newest runs keep their session on disk. Older ones are
    /// deleted, so a job that runs every hour doesn't leave hundreds of sessions behind.
    public var keepSessions: Int
    /// Resumed session: compact it first once its context fills this percentage of the model's
    /// window. 0: never (Claude Code still compacts on its own when the window is full).
    public var compactAbovePct: Int
    public var notify: Notify
    /// Claude runs: the agent the session runs as (`--agent`), from the job's folder's
    /// `.claude/agents/` or the user's. Empty: plain Claude Code. Not on the board's form: set by
    /// what makes such a job (the secretary).
    public var agent: String
    /// Claude runs: tools allowed without a prompt on top of the user's settings
    /// (`--allowedTools`), e.g. `Bash(~/.claude/hq/bin/hq:*)`. Not on the form either.
    public var allowedTools: [String]

    public init(id: String = Jobs.newID(), name: String = "", kind: Kind = .claude, prompt: String = "",
                command: String = "", cwd: String = "~", schedule: Schedule = Schedule(),
                enabled: Bool = true, model: String = "", permission: Permission = .standard,
                timeoutMinutes: Int = 20, skipWeekPct: Int = 90, skipFiveHourPct: Int = 90,
                sessionMode: SessionMode = .fresh, keepSessions: Int = 20, compactAbovePct: Int = 50,
                notify: Notify = .failure, agent: String = "", allowedTools: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.prompt = prompt; self.command = command
        self.cwd = cwd; self.schedule = schedule; self.enabled = enabled; self.model = model
        self.permission = permission; self.timeoutMinutes = timeoutMinutes
        self.skipWeekPct = skipWeekPct; self.skipFiveHourPct = skipFiveHourPct
        self.sessionMode = sessionMode; self.keepSessions = keepSessions; self.compactAbovePct = compactAbovePct
        self.notify = notify; self.agent = agent; self.allowedTools = allowedTools
    }

    enum Keys: String, CodingKey {
        case id, name, kind, prompt, command, cwd, schedule, enabled, model, permission, timeoutMinutes,
             skipWeekPct, skipFiveHourPct, sessionMode, keepSessions, compactAbovePct, notify, agent, allowedTools
    }

    /// Every field but the id may be missing: a job written by an older version, or by hand,
    /// still loads, with the defaults the form would have shown.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = Job(id: try c.decode(String.self, forKey: .id))
        func v<T: Decodable>(_ k: Keys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        self.init(id: d.id, name: v(.name, d.name), kind: v(.kind, d.kind), prompt: v(.prompt, d.prompt),
                  command: v(.command, d.command), cwd: v(.cwd, d.cwd), schedule: v(.schedule, d.schedule),
                  enabled: v(.enabled, d.enabled), model: v(.model, d.model), permission: v(.permission, d.permission),
                  timeoutMinutes: v(.timeoutMinutes, d.timeoutMinutes),
                  skipWeekPct: v(.skipWeekPct, d.skipWeekPct), skipFiveHourPct: v(.skipFiveHourPct, d.skipFiveHourPct),
                  sessionMode: v(.sessionMode, d.sessionMode), keepSessions: v(.keepSessions, d.keepSessions),
                  compactAbovePct: v(.compactAbovePct, d.compactAbovePct), notify: v(.notify, d.notify),
                  agent: v(.agent, d.agent), allowedTools: v(.allowedTools, d.allowedTools))
    }

    /// What is wrong with it, in a sentence the form can show; nil when it can be saved.
    public func problem() -> String? {
        if !Jobs.isValidID(id) { return L("bad job id", "任务 id 无效") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("Give the job a name.", "给任务起个名字。") }
        switch kind {
        case .claude where prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return L("Write the prompt to send.", "写下要发送的 prompt。")
        case .shell where command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return L("Write the command to run.", "写下要运行的命令。")
        default: break
        }
        if !(1...24 * 60).contains(timeoutMinutes) { return L("The time limit must be between 1 minute and 24 hours.", "时间上限要在 1 分钟到 24 小时之间。") }
        if !(0...100).contains(skipWeekPct) || !(0...100).contains(skipFiveHourPct) { return L("A quota percentage is between 0 and 100.", "额度百分比要在 0 到 100 之间。") }
        if !(1...500).contains(keepSessions) { return L("Keep between 1 and 500 sessions.", "保留的 session 数要在 1 到 500 之间。") }
        if !(0...100).contains(compactAbovePct) { return L("The compaction threshold is a percentage between 0 and 100.", "compact 阈值是 0 到 100 之间的百分比。") }
        if model.range(of: #"^[A-Za-z0-9._\[\]-]*$"#, options: .regularExpression) == nil { return L("That model name has odd characters.", "模型名里有奇怪的字符。") }
        if agent.range(of: #"^[A-Za-z0-9._-]*$"#, options: .regularExpression) == nil { return L("That agent name has odd characters.", "agent 名里有奇怪的字符。") }
        return schedule.problem()
    }

    /// The working directory with `~` expanded.
    public var directory: String { (cwd.isEmpty ? "~" : cwd as NSString).expandingTildeInPath }
}

// MARK: - A duty's recurring work

/// A duty's recurring work ("定期来活") is a shell job that runs `hq new --project=P --template=T`
/// on its schedule: the board's duty page makes these jobs and finds them again by their command.
public enum Recurring {
    public static func command(hq: String, project: String, template: String) -> String {
        "\(quote(hq)) new --project=\(quote(project)) --template=\(quote(template))"
    }

    /// The project and template of a command `command(hq:project:template:)` made; nil for any other.
    public static func parse(_ command: String) -> (project: String, template: String)? {
        guard let w = words(command), w.count == 4, w[0].hasSuffix("/hq"), w[1] == "new",
              w[2].hasPrefix("--project="), w[3].hasPrefix("--template=") else { return nil }
        let project = String(w[2].dropFirst("--project=".count)), template = String(w[3].dropFirst("--template=".count))
        return project.isEmpty || template.isEmpty ? nil : (project, template)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// The words of a command line of plain and single-quoted parts, as `sh` reads them; nil when
    /// it has anything else (double quotes, `$`, `;` …), which `command` never writes.
    static func words(_ s: String) -> [String]? {
        var out: [String] = [], cur = "", started = false, quoted = false, escaped = false
        for ch in s {
            if quoted {
                if ch == "'" { quoted = false } else { cur.append(ch) }
            } else if escaped {
                cur.append(ch); escaped = false
            } else if ch == "'" {
                quoted = true; started = true
            } else if ch == "\\" {
                escaped = true; started = true
            } else if ch == " " {
                if started { out.append(cur); cur = ""; started = false }
            } else if "\"$`;&|<>()*?![]{}~#\n\t".contains(ch) {
                return nil
            } else {
                cur.append(ch); started = true
            }
        }
        if quoted || escaped { return nil }
        if started { out.append(cur) }
        return out
    }
}

// MARK: - When it runs

public struct Schedule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case every, daily, weekdays, weekly, cron }
    public var kind: Kind
    public var everyMinutes: Int
    public var hour: Int
    public var minute: Int
    /// Weekly: 1 = Monday … 7 = Sunday.
    public var days: [Int]
    public var cron: String

    public init(kind: Kind = .weekdays, everyMinutes: Int = 60, hour: Int = 9, minute: Int = 0,
                days: [Int] = [1], cron: String = "0 9 * * 1-5") {
        self.kind = kind; self.everyMinutes = everyMinutes; self.hour = hour; self.minute = minute
        self.days = days; self.cron = cron
    }

    enum Keys: String, CodingKey { case kind, everyMinutes, hour, minute, days, cron }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = Schedule()
        func v<T: Decodable>(_ k: Keys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        self.init(kind: v(.kind, d.kind), everyMinutes: v(.everyMinutes, d.everyMinutes), hour: v(.hour, d.hour),
                  minute: v(.minute, d.minute), days: v(.days, d.days), cron: v(.cron, d.cron))
    }

    /// The fixed-time schedules as a cron spec; nil for "every N minutes", which launchd runs as
    /// an interval instead.
    public func spec() throws -> CronSpec? {
        switch kind {
        case .every: return nil
        case .daily: return CronSpec(minutes: [minute], hours: [hour])
        case .weekdays: return CronSpec(minutes: [minute], hours: [hour], weekdays: [1, 2, 3, 4, 5])
        case .weekly:
            let wd = Set(days.map { $0 % 7 }).sorted()     // 7 (Sunday) → 0, as cron counts
            return CronSpec(minutes: [minute], hours: [hour], weekdays: wd)
        case .cron: return try CronSpec.parse(cron)
        }
    }

    public func problem() -> String? {
        switch kind {
        case .every:
            return (1...7 * 24 * 60).contains(everyMinutes) ? nil : L("Pick an interval between 1 minute and 7 days.", "间隔要在 1 分钟到 7 天之间。")
        case .daily, .weekdays, .weekly:
            guard (0...23).contains(hour), (0...59).contains(minute) else { return L("That isn't a time of day.", "这不是一个有效的时刻。") }
            if kind == .weekly, days.isEmpty || !days.allSatisfy({ (1...7).contains($0) }) { return L("Pick at least one day.", "至少选一天。") }
            return nil
        case .cron:
            do {
                let s = try CronSpec.parse(cron)
                _ = try s.launchdIntervals()
                return nil
            } catch let e as CronSpec.ParseError { return e.message } catch { return "\(error)" }
        }
    }

    /// The next `count` times it runs after `after`. "Every N minutes" counts from `anchor` —
    /// when the job was last run or switched on — since that is what launchd counts from.
    public func nextRuns(after: Date, count: Int, anchor: Date?, calendar: Calendar = .current) -> [Date] {
        if kind == .every {
            let step = Double(max(1, everyMinutes) * 60)
            var t = (anchor ?? after).addingTimeInterval(step)
            if t <= after { t = t.addingTimeInterval((after.timeIntervalSince(t) / step).rounded(.down) * step + step) }
            return (0..<count).map { t.addingTimeInterval(Double($0) * step) }
        }
        guard let spec = try? spec() else { return [] }
        return spec.nextRuns(after: after, count: count, calendar: calendar)
    }
}

/// A five-field cron expression: minute hour day-of-month month day-of-week.
public struct CronSpec: Equatable, Sendable {
    public struct ParseError: Error, Equatable { public let message: String }

    public var minutes: [Int]
    public var hours: [Int]
    /// nil: any. Day of month 1–31, month 1–12, weekday 0 (Sunday) – 6.
    public var days: [Int]?
    public var months: [Int]?
    public var weekdays: [Int]?

    public init(minutes: [Int], hours: [Int], days: [Int]? = nil, months: [Int]? = nil, weekdays: [Int]? = nil) {
        self.minutes = minutes; self.hours = hours; self.days = days; self.months = months; self.weekdays = weekdays
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public static func parse(_ text: String) throws -> CronSpec {
        let f = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard f.count == 5 else {
            throw ParseError(message: L("A cron expression has five fields: minute hour day month weekday.",
                                        "cron 表达式有五个字段：分 时 日 月 星期。"))
        }
        let minutes = try field(f[0], 0...59, L("minute", "分钟"))
        let hours = try field(f[1], 0...23, L("hour", "小时"))
        let days = try field(f[2], 1...31, L("day", "日"))
        let months = try field(f[3], 1...12, L("month", "月"), names: monthNames, nameBase: 1)
        var weekdays = try field(f[4], 0...7, L("weekday", "星期"), names: dayNames, nameBase: 0)
        weekdays = weekdays.map { Array(Set($0.map { $0 % 7 })).sorted() }
        if weekdays?.count == 7 { weekdays = nil }
        return CronSpec(minutes: minutes ?? Array(0...59), hours: hours ?? Array(0...23),
                        days: days, months: months, weekdays: weekdays)
    }

    /// nil when the field allows every value.
    static func field(_ s: String, _ range: ClosedRange<Int>, _ what: String,
                      names: [String] = [], nameBase: Int = 0) throws -> [Int]? {
        func num(_ x: Substring) throws -> Int {
            if let n = Int(x) { return n }
            if let i = names.firstIndex(of: x.lowercased()) { return i + nameBase }
            throw ParseError(message: L("\"\(x)\" isn't a valid \(what).", "“\(x)”不是有效的\(what)。"))
        }
        var out = Set<Int>()
        var everything = false
        for item in s.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2, !parts[0].isEmpty else { throw ParseError(message: L("\"\(item)\" isn't a valid \(what).", "“\(item)”不是有效的\(what)。")) }
            var step = 1
            if parts.count == 2 {
                guard let n = Int(parts[1]), n > 0 else { throw ParseError(message: L("\"\(item)\" has a bad step.", "“\(item)”的步长不对。")) }
                step = n
            }
            var lo = range.lowerBound, hi = range.upperBound
            if parts[0] == "*" {
                if step == 1 { everything = true }
            } else if let dash = parts[0].firstIndex(of: "-") {
                lo = try num(parts[0][..<dash]); hi = try num(parts[0][parts[0].index(after: dash)...])
            } else {
                lo = try num(parts[0]); hi = parts.count == 2 ? range.upperBound : lo
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else {
                throw ParseError(message: L("\"\(item)\" is outside \(range.lowerBound)–\(range.upperBound) for the \(what).",
                                            "“\(item)”超出了\(what)的范围 \(range.lowerBound)–\(range.upperBound)。"))
            }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return everything ? nil : out.sorted()
    }

    func dayMatches(_ day: Int, weekday: Int, month: Int) -> Bool {
        if let months, !months.contains(month) { return false }
        switch (days, weekdays) {
        case (nil, nil): return true
        case let (d?, nil): return d.contains(day)
        case let (nil, w?): return w.contains(weekday)
        // Cron's rule: with both restricted, either one is enough.
        case let (d?, w?): return d.contains(day) || w.contains(weekday)
        }
    }

    public func nextRuns(after: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: after)
        for _ in 0..<(366 * 5) where out.count < count {
            let c = calendar.dateComponents([.day, .weekday, .month], from: day)
            if dayMatches(c.day!, weekday: c.weekday! - 1, month: c.month!) {
                for h in hours {
                    for m in minutes {
                        guard out.count < count,
                              let t = calendar.date(bySettingHour: h, minute: m, second: 0, of: day),
                              t > after, calendar.isDate(t, inSameDayAs: day) else { continue }
                        if out.last.map({ t > $0 }) ?? true { out.append(t) }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// launchd's `StartCalendarInterval`: a list of dictionaries, each a time that matches when
    /// every key it names matches; a key left out matches anything.
    public func launchdIntervals() throws -> [[String: Int]] {
        func product(_ base: [[String: Int]], _ key: String, _ values: [Int]?) -> [[String: Int]] {
            guard let values else { return base }
            return base.flatMap { b in values.map { v in b.merging([key: v]) { $1 } } }
        }
        var base: [[String: Int]] = [[:]]
        base = product(base, "Minute", minutes.count == 60 ? nil : minutes)
        base = product(base, "Hour", hours.count == 24 ? nil : hours)
        base = product(base, "Month", months)
        var out: [[String: Int]]
        switch (days, weekdays) {
        case let (d?, w?): out = product(base, "Day", d) + product(base, "Weekday", w)
        default: out = product(product(base, "Day", days), "Weekday", weekdays)
        }
        guard out.count <= 1000 else {
            throw ParseError(message: L("That expression matches too many separate times for macOS to schedule (\(out.count)); use \"every N minutes\" instead.",
                                        "这个表达式对应的时间点太多（\(out.count) 个），macOS 排不过来；改用“每 N 分钟”吧。"))
        }
        return out
    }
}

// MARK: - launchd

public enum LaunchAgent {
    public static let labelPrefix = "local.claudepet.job."

    public static func label(for id: String) -> String { labelPrefix + id }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
    }

    public static func plistURL(for id: String) -> URL { directory.appending(path: label(for: id) + ".plist") }

    /// The agent that runs `program --run-job <id>` on the job's schedule. launchd's own output
    /// for it (only ever the runner's complaints) goes to the job's folder.
    public static func plist(for job: Job, program: String, jobsDirectory: URL = Jobs.directory) throws -> Data {
        var p: [String: Any] = [
            "Label": label(for: job.id),
            "ProgramArguments": [program, "--run-job", job.id],
            "RunAtLoad": false,
            "StandardOutPath": jobsDirectory.appending(path: job.id).appending(path: "launchd.log").path,
            "StandardErrorPath": jobsDirectory.appending(path: job.id).appending(path: "launchd.log").path,
        ]
        // A pet folder moved for testing goes with the job, so the runner finds it.
        if let home = ProcessInfo.processInfo.environment["PET_HOME"] {
            p["EnvironmentVariables"] = ["PET_HOME": home]
        }
        if let spec = try job.schedule.spec() {
            p["StartCalendarInterval"] = try spec.launchdIntervals()
        } else {
            p["StartInterval"] = max(1, job.schedule.everyMinutes) * 60
        }
        return try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
    }
}

// MARK: - Runs

public struct JobRun: Equatable, Sendable {
    public enum Status: String, Sendable {
        case running, ok, fail, timeout, stopped, skipped
        /// Started and never finished, and its process is gone: the Mac shut down mid-run, or
        /// the runner was killed.
        case lost
    }
    public var id: String
    public var started: Date
    public var ended: Date?
    public var status: Status
    public var trigger: String
    public var pid: Int32?
    public var exitCode: Int?
    public var costUSD: Double?
    public var turns: Int?
    public var sessionId: String?
    public var denials: Int
    public var contextTokens: Int?
    /// The reply's first line, or for a shell command its last output line.
    public var summary: String
    /// The output's last lines, for a failure.
    public var tail: String
    /// The subscription quota (percent used) when the run started and when it ended, from Claude's
    /// own rate-limit reports — what the run cost, in the terms a subscriber thinks in.
    public var quotaBefore: Quota?
    public var quotaAfter: Quota?
    /// The model's context window, to read `contextTokens` as a percentage.
    public var contextWindow: Int?

    public init(id: String, started: Date, ended: Date?, status: Status, trigger: String, pid: Int32?,
                exitCode: Int?, costUSD: Double?, turns: Int?, sessionId: String?, denials: Int,
                contextTokens: Int?, summary: String, tail: String,
                quotaBefore: Quota? = nil, quotaAfter: Quota? = nil, contextWindow: Int? = nil) {
        self.id = id; self.started = started; self.ended = ended; self.status = status; self.trigger = trigger
        self.pid = pid; self.exitCode = exitCode; self.costUSD = costUSD; self.turns = turns
        self.sessionId = sessionId; self.denials = denials; self.contextTokens = contextTokens
        self.summary = summary; self.tail = tail
        self.quotaBefore = quotaBefore; self.quotaAfter = quotaAfter; self.contextWindow = contextWindow
    }

    public var durationSeconds: Double? { ended.map { $0.timeIntervalSince(started) } }
    public var failed: Bool { [.fail, .timeout, .lost].contains(status) }

    public func json() -> [String: Any] {
        var o: [String: Any] = ["id": id, "started": Jobs.iso(started), "status": status.rawValue,
                                "trigger": trigger, "denials": denials, "summary": summary, "tail": tail]
        if let ended { o["ended"] = Jobs.iso(ended) }
        if let exitCode { o["exitCode"] = exitCode }
        if let costUSD { o["costUSD"] = costUSD }
        if let turns { o["turns"] = turns }
        if let sessionId { o["sessionId"] = sessionId }
        if let contextTokens { o["contextTokens"] = contextTokens }
        if let contextWindow { o["contextWindow"] = contextWindow }
        if let quotaBefore { o["quotaBefore"] = quotaBefore.json() }
        if let quotaAfter { o["quotaAfter"] = quotaAfter.json() }
        return o
    }

    /// `runs.jsonl` → runs, newest first. A start with no end is running while its process is
    /// alive, and lost once it isn't.
    public static func parse(_ data: Data, alive: (Int32) -> Bool) -> [JobRun] {
        var byID: [String: JobRun] = [:]
        var order: [String] = []
        for line in data.split(separator: 0x0a) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = o["run"] as? String, let at = Jobs.date(o["at"]) else { continue }
            switch o["event"] as? String {
            case "start", "skip":
                let skip = o["event"] as? String == "skip"
                if byID[id] == nil { order.append(id) }
                byID[id] = JobRun(id: id, started: at, ended: skip ? at : nil, status: skip ? .skipped : .running,
                                  trigger: o["trigger"] as? String ?? "schedule",
                                  pid: (o["pid"] as? Int).map { Int32($0) }, exitCode: nil, costUSD: nil, turns: nil,
                                  sessionId: o["sessionId"] as? String, denials: 0, contextTokens: nil,
                                  summary: o["summary"] as? String ?? "", tail: "")
            case "end":
                guard var r = byID[id] else { continue }
                r.ended = at
                r.status = Status(rawValue: o["status"] as? String ?? "") ?? .fail
                r.exitCode = o["exitCode"] as? Int
                r.costUSD = o["costUSD"] as? Double
                r.turns = o["turns"] as? Int
                r.sessionId = (o["sessionId"] as? String) ?? r.sessionId
                r.denials = o["denials"] as? Int ?? 0
                r.contextTokens = o["contextTokens"] as? Int
                r.contextWindow = o["contextWindow"] as? Int
                r.quotaBefore = Quota(json: o["quotaBefore"])
                r.quotaAfter = Quota(json: o["quotaAfter"])
                r.summary = o["summary"] as? String ?? ""
                r.tail = o["tail"] as? String ?? ""
                byID[id] = r
            default: continue
            }
        }
        return order.reversed().compactMap { id in
            guard var r = byID[id] else { return nil }
            if r.status == .running, !(r.pid.map(alive) ?? false) { r.status = .lost }
            return r
        }
    }

    /// Fresh-session jobs keep only the newest `keep` runs' sessions; these are the others.
    public static func sessionsToPrune(_ runs: [JobRun], keep: Int) -> [String] {
        var seen = Set<String>()
        var kept = 0
        var out: [String] = []
        for r in runs {     // newest first
            guard let s = r.sessionId, !s.isEmpty, !seen.contains(s) else { continue }
            seen.insert(s)
            if kept < keep { kept += 1 } else { out.append(s) }
        }
        return out
    }
}

/// What a `claude -p --output-format stream-json --verbose` run printed, boiled down.
public struct ClaudeStreamResult: Equatable, Sendable {
    public var sessionId: String?
    public var finished = false
    public var isError = false
    public var reply = ""
    public var costUSD: Double?
    public var turns: Int?
    public var denials = 0
    /// The context the last model call saw: what a resumed session carries into the next run.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// The first and the last rate-limit report of the run.
    public var quotaFirst: Quota?
    public var quotaLast: Quota?
    public var errorText = ""

    public init() {}

    public static func parse(_ data: Data) -> ClaudeStreamResult {
        var r = ClaudeStreamResult()
        for line in data.split(separator: 0x0a) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if r.sessionId == nil, let s = o["session_id"] as? String { r.sessionId = s }
            switch o["type"] as? String {
            case "rate_limit_event":
                if let q = Quota(rateLimitInfo: o["rate_limit_info"]) {
                    if r.quotaFirst == nil { r.quotaFirst = q }
                    r.quotaLast = q
                }
            case "assistant":
                if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                        .reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                    if n > 0 { r.contextTokens = n }
                }
            case "result":
                r.finished = true
                r.isError = o["is_error"] as? Bool ?? false
                r.reply = o["result"] as? String ?? ""
                r.costUSD = o["total_cost_usd"] as? Double
                r.turns = o["num_turns"] as? Int
                r.denials = (o["permission_denials"] as? [Any])?.count ?? 0
                r.contextWindow = (o["modelUsage"] as? [String: [String: Any]])?.values
                    .compactMap { $0["contextWindow"] as? Int }.max()
                if r.isError {
                    r.errorText = (o["errors"] as? [String])?.joined(separator: "; ")
                        ?? (o["subtype"] as? String ?? "error")
                }
            default: break
            }
        }
        return r
    }

    /// The steps of the run as the board's "what it did" list: each tool call with its result,
    /// refusals, and the text in between.
    public static func steps(_ data: Data, limit: Int = 300) -> [[String: String]] {
        var out: [[String: String]] = []
        var names: [String: Int] = [:]      // tool_use id → index in out
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        for line in data.split(separator: 0x0a) where out.count < limit {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else {
                continue
            }
            for c in content {
                switch (o["type"] as? String, c["type"] as? String) {
                case ("assistant", "text"):
                    let text = (c["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(["kind": "text", "text": clip(text, 4000)]) }
                case ("assistant", "tool_use"):
                    let input = c["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    if let id = c["id"] as? String { names[id] = out.count }
                    out.append(["kind": "tool", "tool": c["name"] as? String ?? "?", "input": clip(input, 600), "result": ""])
                case ("user", "tool_result"):
                    guard let id = c["tool_use_id"] as? String, let i = names[id] else { continue }
                    var text = c["content"] as? String ?? ""
                    if let parts = c["content"] as? [[String: Any]] {
                        text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                    out[i]["result"] = clip(text.trimmingCharacters(in: .whitespacesAndNewlines), 600)
                    if c["is_error"] as? Bool == true { out[i]["error"] = "1" }
                default: continue
                }
            }
        }
        return out
    }
}

// MARK: - Files

/// One folder per job. Writes are atomic (whole-file replace) or appends of one line, so the
/// runner and the app can work on the same job at once.
public struct JobStore: Sendable {
    public let base: URL

    public init(base: URL = Jobs.directory) { self.base = base }

    public func folder(_ id: String) -> URL { base.appending(path: id) }
    public func jobURL(_ id: String) -> URL { folder(id).appending(path: "job.json") }
    public func runsURL(_ id: String) -> URL { folder(id).appending(path: "runs.jsonl") }
    public func stateURL(_ id: String) -> URL { folder(id).appending(path: "state.json") }
    public func logsURL(_ id: String) -> URL { folder(id).appending(path: "logs") }
    /// Present while a stop has been asked for; the runner then records the run as stopped.
    public func stopURL(_ id: String) -> URL { folder(id).appending(path: "stop") }
    /// The last quota reading any job's run saw (see Quota.current).
    public var quotaURL: URL { base.appending(path: "quota.json") }

    public func load(_ id: String) -> Job? {
        guard Jobs.isValidID(id), let data = try? Data(contentsOf: jobURL(id)) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    public func list() -> [Job] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter(Jobs.isValidID).compactMap(load).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    public func save(_ job: Job) throws {
        try FileManager.default.createDirectory(at: logsURL(job.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(job).write(to: jobURL(job.id), options: .atomic)
    }

    public func delete(_ id: String) throws {
        guard Jobs.isValidID(id) else { return }
        try FileManager.default.removeItem(at: folder(id))
    }

    public func append(_ id: String, _ record: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        line.append(0x0a)
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        let fd = open(runsURL(id).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    public func runs(_ id: String, alive: (Int32) -> Bool = JobStore.isAlive) -> [JobRun] {
        guard let data = try? Data(contentsOf: runsURL(id)) else { return [] }
        return JobRun.parse(data, alive: alive)
    }

    /// Keeps `runs.jsonl` to the newest `keep` runs and deletes the logs of the rest.
    public func trim(_ id: String, keep: Int = 100) {
        let all = runs(id)
        guard all.count > keep else { return }
        let keepIDs = Set(all.prefix(keep).map(\.id))
        guard let data = try? Data(contentsOf: runsURL(id)) else { return }
        var out = Data()
        for line in data.split(separator: 0x0a) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let run = o["run"] as? String, keepIDs.contains(run) else { continue }
            out.append(contentsOf: line); out.append(0x0a)
        }
        try? out.write(to: runsURL(id), options: .atomic)
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: logsURL(id).path)) ?? []
        for name in logs where !keepIDs.contains(where: { name.hasPrefix($0 + ".") }) {
            try? FileManager.default.removeItem(at: logsURL(id).appending(path: name))
        }
    }

    public func state(_ id: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: stateURL(id)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o
    }

    public func setState(_ id: String, _ change: (inout [String: Any]) -> Void) {
        var s = state(id)
        change(&s)
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? data.write(to: stateURL(id), options: .atomic)
    }

    public static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// A new run's id: sortable, and unique enough for one job.
    public static func newRunID(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + UUID().uuidString.lowercased().prefix(4)
    }
}

// MARK: - Subscription quota

/// How much of the subscription's five-hour and weekly limits is used, in percent, and when each
/// window resets. Read from Claude's rate-limit reports in a run's output, or from the readings the
/// pet already keeps (UsageSnapshot).
public struct Quota: Equatable, Sendable {
    public var fiveHour: Int?
    public var fiveHourResetAt: Date?
    public var week: Int?
    public var weekResetAt: Date?

    public init(fiveHour: Int? = nil, fiveHourResetAt: Date? = nil, week: Int? = nil, weekResetAt: Date? = nil) {
        self.fiveHour = fiveHour; self.fiveHourResetAt = fiveHourResetAt; self.week = week; self.weekResetAt = weekResetAt
    }

    /// A stream-json `rate_limit_event`'s `rate_limit_info`.
    public init?(rateLimitInfo raw: Any?) {
        guard let info = raw as? [String: Any], let w = info["unifiedWindows"] as? [String: [String: Any]] else { return nil }
        func pct(_ k: String) -> Int? { (w[k]?["utilization"] as? Double).map { Int(($0 * 100).rounded()) } }
        func reset(_ k: String) -> Date? { (w[k]?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) } }
        self.init(fiveHour: pct("five_hour"), fiveHourResetAt: reset("five_hour"), week: pct("seven_day"), weekResetAt: reset("seven_day"))
        if fiveHour == nil && week == nil { return nil }
    }

    public init?(json raw: Any?) {
        guard let o = raw as? [String: Any] else { return nil }
        self.init(fiveHour: o["fiveHour"] as? Int, fiveHourResetAt: Jobs.date(o["fiveHourResetAt"]),
                  week: o["week"] as? Int, weekResetAt: Jobs.date(o["weekResetAt"]))
    }

    public init(_ u: UsageSnapshot) {
        self.init(fiveHour: u.fiveHourPercent, fiveHourResetAt: u.fiveHourResetAt, week: u.sevenDayPercent, weekResetAt: u.sevenDayResetAt)
    }

    public func json() -> [String: Any] {
        var o: [String: Any] = [:]
        if let fiveHour { o["fiveHour"] = fiveHour }
        if let fiveHourResetAt { o["fiveHourResetAt"] = Jobs.iso(fiveHourResetAt) }
        if let week { o["week"] = week }
        if let weekResetAt { o["weekResetAt"] = Jobs.iso(weekResetAt) }
        return o
    }

    /// The most that is known to be used now. A reading only ever understates its window until
    /// the window resets, so an old one still counts — as long as its window hasn't reset.
    public static func highest(_ readings: [Quota], now: Date) -> Quota {
        var out = Quota()
        for q in readings {
            if let p = q.fiveHour, let r = q.fiveHourResetAt, r > now, p >= (out.fiveHour ?? -1) {
                out.fiveHour = p; out.fiveHourResetAt = r
            }
            if let p = q.week, let r = q.weekResetAt, r > now, p >= (out.week ?? -1) {
                out.week = p; out.weekResetAt = r
            }
        }
        return out
    }

    /// Why a job with these limits should not run now; nil when it may.
    public func reasonToSkip(weekPct: Int, fiveHourPct: Int) -> String? {
        if weekPct > 0, let w = week, w >= weekPct { return "skipped: weekly quota at \(w)% (limit \(weekPct)%)" }
        if fiveHourPct > 0, let f = fiveHour, f >= fiveHourPct { return "skipped: 5-hour quota at \(f)% (limit \(fiveHourPct)%)" }
        return nil
    }

    /// Everything known about the quota right now: the pet's readings (claude-hud's cache, the
    /// statusline's) and the last rate-limit report a job run saw.
    public static func current(claudeHome: URL, petHome: URL, store: JobStore, now: Date = Date()) -> Quota {
        var readings: [Quota] = []
        if let hud = (try? Data(contentsOf: UsageReader.cacheURL(claudeHome: claudeHome))).flatMap(UsageReader.parse) {
            readings.append(Quota(hud))
        }
        if let saved = (try? Data(contentsOf: UsageReader.snapshotURL(petHome: petHome))).flatMap(UsageReader.parseSnapshot) {
            readings.append(Quota(saved))
        }
        if let line = (try? Data(contentsOf: StatuslineUsage.cacheURL(petHome: petHome))).flatMap(StatuslineUsage.decode) {
            readings.append(Quota(line))
        }
        if let data = try? Data(contentsOf: store.quotaURL),
           let q = Quota(json: try? JSONSerialization.jsonObject(with: data)) {
            readings.append(q)
        }
        return highest(readings, now: now)
    }
}
