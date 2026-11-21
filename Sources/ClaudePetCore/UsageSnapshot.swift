import Foundation

/// How much of the Claude subscription's allowance is used, and when it resets.
public struct UsageSnapshot: Sendable, Equatable {
    public let planName: String
    /// Percent of the five-hour window used, 0-100.
    public let fiveHourPercent: Int
    /// Percent of the weekly window used, 0-100.
    public let sevenDayPercent: Int
    public let fiveHourResetAt: Date
    public let sevenDayResetAt: Date
    /// When this reading was taken, which is NOT when it was read.
    public let capturedAt: Date
    /// Where it came from. Carried on the reading itself so two sources can
    /// never be silently blended into one set of numbers that belongs to
    /// neither.
    public let source: String

    public init(
        planName: String,
        fiveHourPercent: Int,
        sevenDayPercent: Int,
        fiveHourResetAt: Date,
        sevenDayResetAt: Date,
        capturedAt: Date,
        source: String = ""
    ) {
        self.planName = planName
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.fiveHourResetAt = fiveHourResetAt
        self.sevenDayResetAt = sevenDayResetAt
        self.capturedAt = capturedAt
        self.source = source
    }

    /// Percentages go stale; reset times do not.
    ///
    /// The cache is refreshed by the statusline, so it only updates while the
    /// user has Claude Code open. After a quiet evening the percentages describe
    /// a window that has since rolled over, and announcing them would be worse
    /// than saying nothing. The reset timestamps are absolute instants, so they
    /// stay true regardless of when they were fetched.
    public static let percentagesGoStaleAfter: TimeInterval = 30 * 60

    public func percentagesUsable(now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= Self.percentagesGoStaleAfter
    }

    /// Has the window this reading describes already rolled over?
    ///
    /// When it has, the percentage is not merely old — it belongs to a window
    /// that no longer exists. The number it would be replaced by is NOT zero:
    /// the user may have spent plenty of the new window since. So this reports
    /// that the reading is out of date, and the display says so rather than
    /// guessing in either direction.
    public func fiveHourWindowRolledOver(now: Date) -> Bool {
        now >= fiveHourResetAt
    }

    public func sevenDayWindowRolledOver(now: Date) -> Bool {
        now >= sevenDayResetAt
    }
}

/// Several sessions take turns writing one quota file, each with the numbers from its OWN last
/// API call: claude-hud saves whatever the statusline it is rendering was given, and every open
/// session re-renders its statusline every few seconds. A session that has not called the API for
/// a while keeps writing what was true back then, and the file flips between the readings.
///
/// The reading that is true is the one that appeared LAST. Every API call can produce a new
/// reading; a session that is not calling the API only ever repeats one that was already there.
/// So each distinct reading — both windows' figures and reset times together, as one session
/// wrote them — is remembered with the time it was first seen, and the most recently born wins.
/// Judging the windows together matters: the weekly figure can sit at 2% for hours, but the
/// five-hour figure of a working session moves much sooner, and the reading it moves in carries
/// the true weekly figure with it.
///
/// This replaced "keep the highest figure per window", which assumed use only grows within a
/// window. A reset breaks that: after one, the weekly window kept its reset time (the same window,
/// by that rule) while its use went from 100% to 2%, and an idle session writing the old 100% won
/// `max(2, 100)` for as long as it stayed open (2026-11-21).
public struct UsageRecency: Sendable {
    /// A reading not seen for this long has left the file — its session closed or caught up. Seen
    /// again later it is new.
    public static let goneAfter: TimeInterval = 10 * 60
    /// Right after watching starts — or resumes: after a restart or a gap in watching — every reading
    /// the pet does not already know is first seen within a few seconds, in whatever order the
    /// sessions happened to write.
    /// Births in this span say nothing about age, so they count as one; a tie goes to the higher
    /// figures, per window (the old rule), which is right except straight after a reset — and the
    /// first new reading any working session writes settles it.
    public static let settleFor: TimeInterval = 60

    struct Reading: Hashable {
        let five: Int
        let fiveReset: Date
        let week: Int
        let weekReset: Date
    }

    private var seen: [Reading: (first: Date, last: Date)] = [:]
    /// When the current settling span began: the first observation, and again on resuming.
    private var settlingSince: Date?
    private var lastObserved: Date?
    /// Restored from a save and not yet observed: the first observation resumes.
    private var restored = false
    private var newest: UsageSnapshot?

    public init() {}

    // MARK: Kept across restarts

    /// What is saved: every reading still remembered, with when it was first and last seen.
    /// Without it each restart of the pet — every install — met all the readings in the file at
    /// once, could not tell them apart, and showed the higher figures (after a reset, the old 100%)
    /// until a working session's figures next moved.
    struct Saved: Codable {
        struct Entry: Codable {
            let five: Int, fiveReset: Date, week: Int, weekReset: Date, first: Date, last: Date
        }
        let readings: [Entry]
    }

    /// The order learned so far, for `init(saved:now:)` after a restart. Nil before anything was seen.
    public func saved() -> Data? {
        guard settlingSince != nil || restored else { return nil }
        let entries = seen.map { Saved.Entry(five: $0.key.five, fiveReset: $0.key.fiveReset, week: $0.key.week,
                                             weekReset: $0.key.weekReset, first: $0.value.first, last: $0.value.last) }
        // The default date encoding (seconds since 2001, as Date stores them) reads back to the
        // same Date bit for bit; seconds since 1970 can lose the last bit, and a reading whose
        // reset time came back a hair different would no longer match the live one — a "new" birth.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Saved(readings: entries))
    }

    /// Picks up where a previous run left off. Nil for anything unreadable, or dated in the future
    /// (a clock set back, a hand-edited file) — then the pet starts from scratch, as before.
    ///
    /// The readings keep their order; the first observation then resumes (see `observe`): every
    /// remembered reading is carried across the time the pet was off, and readings it does not
    /// know — written while it was off — settle among themselves like any first sighting. Their
    /// order of arrival right after a restart says nothing, and letting the last-arriving one win
    /// (as the save first did) picked one at random.
    public init?(saved data: Data, now: Date = Date()) {
        guard let s = try? JSONDecoder().decode(Saved.self, from: data),
              !s.readings.contains(where: { $0.first > now.addingTimeInterval(60) || $0.last > now.addingTimeInterval(60) })
        else { return nil }
        for e in s.readings {
            seen[Reading(five: e.five, fiveReset: e.fiveReset, week: e.week, weekReset: e.weekReset)] =
                (first: e.first, last: e.last)
        }
        restored = true
    }

    /// Notes one reading of the file. True when it is one not seen before — the moment the order
    /// changes, and so the moment worth saving.
    @discardableResult
    public mutating func observe(_ s: UsageSnapshot, now: Date) -> Bool {
        // Resuming — the first look after a restart, or after a gap in watching (the lid closed,
        // the Mac asleep) — says nothing about which readings left the file: nobody was looking.
        // Forgetting them made the order start over, and the tie after it brought a reset's old
        // 100% back; judging them by when they were last seen before the gap (a save is written
        // only when a reading is new, so its times are older still) dropped an idle session's
        // reading and then took it for a new one. So every remembered reading is carried across,
        // and a fresh settling span starts for the ones not seen before.
        let gap = lastObserved.map { now.timeIntervalSince($0) > Self.goneAfter } ?? false
        if restored || gap {
            seen = seen.mapValues { (first: $0.first, last: now) }
            settlingSince = now
            restored = false
        }
        if settlingSince == nil { settlingSince = now }
        lastObserved = now
        seen = seen.filter { now.timeIntervalSince($0.value.last) <= Self.goneAfter }
        // A window that is missing or already over has no figure worth telling apart; its stand-in
        // reset time (the capture instant) differs on every write, and as part of the key it made
        // every write a "new" reading — last writer wins. One fixed value for all of them.
        func window(_ percent: Int, _ reset: Date) -> (Int, Date) {
            reset > s.capturedAt ? (percent, reset) : (0, .distantPast)
        }
        let (five, fiveReset) = window(s.fiveHourPercent, s.fiveHourResetAt)
        let (week, weekReset) = window(s.sevenDayPercent, s.sevenDayResetAt)
        let r = Reading(five: five, fiveReset: fiveReset, week: week, weekReset: weekReset)
        let born = seen[r] == nil
        seen[r] = (first: seen[r]?.first ?? now, last: now)
        if newest.map({ s.capturedAt >= $0.capturedAt }) ?? true { newest = s }
        return born
    }

    /// The reading to show. Nil before any observation.
    ///
    /// A reading from an older window (a reset time more than two minutes before the latest seen
    /// for that window) is out, whatever its age. Of the rest, the one born last. Readings first
    /// seen during the current settling span count as born when it ends, so they tie, and a tie
    /// takes the higher figure per window; readings known from before it keep their own times.
    public func current() -> UsageSnapshot? {
        guard let newest, let since = settlingSince, !seen.isEmpty else { return newest }
        let latestFive = seen.keys.map(\.fiveReset).max()!
        let latestWeek = seen.keys.map(\.weekReset).max()!
        let live = seen.filter {
            latestFive.timeIntervalSince($0.key.fiveReset) < 120 && latestWeek.timeIntervalSince($0.key.weekReset) < 120
        }
        let settled = since.addingTimeInterval(Self.settleFor)
        let pool = live.isEmpty ? seen : live
        func born(_ first: Date) -> Date { first < since ? first : max(first, settled) }
        let youngest = pool.values.map { born($0.first) }.max()!
        let tied = pool.filter { born($0.value.first) == youngest }.keys
        let five = tied.max { $0.five < $1.five }!
        let week = tied.max { $0.week < $1.week }!
        return UsageSnapshot(planName: newest.planName, fiveHourPercent: five.five, sevenDayPercent: week.week,
                             fiveHourResetAt: five.fiveReset, sevenDayResetAt: week.weekReset,
                             capturedAt: newest.capturedAt, source: newest.source)
    }
}

/// Choosing between readings when more than one source is available.
public enum UsageSources {
    /// Ranked by how directly each one knows: Claude Code's own statusline is
    /// fed the numbers, claude-hud caches what it was given.
    public static func rank(_ source: String) -> Int {
        switch source {
        case "statusline": return 2
        case "claude-hud": return 1
        default: return 0
        }
    }

    /// The reading to trust.
    ///
    /// Freshness beats rank, because a stale reading from a better source is
    /// still stale — it describes a window that may have rolled over. Rank only
    /// decides between readings that are both usable.
    public static func pick(_ candidates: [UsageSnapshot], now: Date) -> UsageSnapshot? {
        let usable = candidates.filter { $0.percentagesUsable(now: now) }
        if let best = usable.max(by: { rank($0.source) < rank($1.source) }) { return best }
        // Nothing usable: hand back the newest anyway so the panel can say how
        // old it is, rather than claiming there is no source at all.
        return candidates.max(by: { $0.capturedAt < $1.capturedAt })
    }
}

/// Reads the usage cache that the claude-hud statusline plugin maintains.
///
/// Deliberately a READER of someone else's cache rather than a client of the
/// usage API. Calling the API would mean reading the user's OAuth token out of
/// ~/.claude/.credentials.json, spending their rate limit, and handling 429
/// backoff — all so a desktop toy could show a number that is already sitting
/// in a file, refreshed every five minutes by something they already run.
///
/// If the plugin is not installed the file does not exist, and everything that
/// depends on usage simply goes quiet.
public enum UsageReader {
    /// `~/.claude/plugins/claude-hud/.usage-cache.json`
    public static func cacheURL(claudeHome: URL) -> URL {
        claudeHome.appending(path: "plugins/claude-hud/.usage-cache.json")
    }

    /// Parses the cache. Returns nil for anything unexpected: this is another
    /// project's private file, so its shape can change without warning and a
    /// surprise must degrade to silence, never to a crash or a wrong number.
    public static func parse(_ data: Data) -> UsageSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `data` is the live reading; `lastGoodData` is what the plugin keeps
        // when a refresh fails. Preferring the former and falling back keeps a
        // transient API failure from blanking the display.
        let payload = (root["data"] as? [String: Any]) ?? (root["lastGoodData"] as? [String: Any])
        guard
            let payload,
            let fiveHour = payload["fiveHour"] as? Int,
            let sevenDay = payload["sevenDay"] as? Int,
            let fiveReset = payload["fiveHourResetAt"] as? String,
            let sevenReset = payload["sevenDayResetAt"] as? String,
            let fiveResetAt = iso8601(fiveReset),
            let sevenResetAt = iso8601(sevenReset)
        else { return nil }

        // Milliseconds since the epoch, per the plugin's own format.
        let capturedAt: Date
        if let ms = root["timestamp"] as? Double {
            capturedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            capturedAt = .distantPast
        }

        return UsageSnapshot(
            planName: payload["planName"] as? String ?? "",
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetAt: fiveResetAt,
            sevenDayResetAt: sevenResetAt,
            capturedAt: capturedAt,
            source: "claude-hud"
        )
    }

    /// The cache writes fractional seconds ("…:00.039Z"), which the plain
    /// ISO8601 formatter rejects, so both spellings are tried.
    /// Where claude-hud saves the statusline's rate limits for other tools, when the user sets
    /// `display.externalUsageWritePath` to it. Newer claude-hud no longer keeps `.usage-cache.json`
    /// (it reads the limits from the statusline input instead), so this is how its numbers reach
    /// the pet. Not `usage.json`: that name belongs to `pet-emit --statusline`.
    public static func snapshotURL(petHome: URL) -> URL {
        petHome.appending(path: "hud-usage.json")
    }

    /// Parses that snapshot: `updated_at`, and `five_hour` / `seven_day` each with
    /// `used_percentage` and `resets_at`. Nil for anything else, as with the cache.
    public static func parseSnapshot(_ data: Data) -> UsageSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let captured = (root["updated_at"] as? String).flatMap(iso8601),
            let five = root["five_hour"] as? [String: Any],
            let week = root["seven_day"] as? [String: Any],
            let fivePct = (five["used_percentage"] as? NSNumber)?.doubleValue,
            let weekPct = (week["used_percentage"] as? NSNumber)?.doubleValue,
            let fiveReset = (five["resets_at"] as? String).flatMap(iso8601),
            let weekReset = (week["resets_at"] as? String).flatMap(iso8601)
        else { return nil }
        return UsageSnapshot(planName: "", fiveHourPercent: Int(fivePct.rounded()), sevenDayPercent: Int(weekPct.rounded()),
                             fiveHourResetAt: fiveReset, sevenDayResetAt: weekReset,
                             capturedAt: captured, source: "claude-hud")
    }

    private static func iso8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
