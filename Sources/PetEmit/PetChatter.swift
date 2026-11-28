import ClaudePetCore
import Foundation
#if os(Windows)
import WinSDK
#endif

/// The cat speaking up for a shell that is not the Mac app (the Windows spike): the Mac's
/// maybeSpeak, noticeReturn and noticeTransients, run on the watcher's tick over the same core
/// (Chatter, QuotaAlarm, ContextAlarm, AwayReport). What the Mac reads off its own window - the
/// list open, a hover card up, the nap - the shell tells `--watch` on stdin (`Shell`). The Mac
/// app does not use it.
struct PetChatter {
    /// What the shell is showing, as it last said on stdin.
    struct Shell: Equatable {
        /// The session list is open (the Mac's isListOpen).
        var listOpen = false
        /// A hover card or the quota readout is up (the Mac's dwellShowing).
        var cardUp = false
        /// Taking a nap (the Mac's paused).
        var napping = false
    }

    /// One line for `window.say`.
    struct Speech: Equatable {
        let text: String
        let emphasis: String
        let variant: Chatter.Bubble
        let hold: TimeInterval
    }

    struct Out: Equatable {
        var say: Speech?
        /// "trouble" or "done", for `window.flash`.
        var flash: String?
    }

    /// How long a line stays up (the Mac's speechHold).
    static let speechHold: TimeInterval = 6
    /// How long the away-and-back line stays up.
    static let awayHold: TimeInterval = 15

    private(set) var lastSpoken: [Chatter.Kind: Date] = [:]
    private(set) var lastAnything: Date?
    private var contextAlarm = ContextAlarm()
    private var napping = false
    private var quotaSaid: Set<String>
    private let quotaSaidURL: URL?
    /// When nobody has touched the machine since, or nil while somebody is at it.
    private var awayStart: Date?
    /// The five-hour quota reading at that moment, to say how much went.
    private var quotaAtLeave: Int?

    /// - Parameter quotaSaidURL: where the quota thresholds already said are kept (the Mac's
    ///   `quotaThresholdsSaid` default), so a restart does not repeat a warning; nil keeps them
    ///   in memory only.
    init(quotaSaidURL: URL? = HookEmit.baseDirectory.appending(path: "quota-said.json")) {
        self.quotaSaidURL = quotaSaidURL
        let saved = quotaSaidURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        quotaSaid = Set(saved)
    }

    /// One tick. Call it before `previous` moves on to `settled`.
    /// - Parameters:
    ///   - state: the state as it is (what the rows show).
    ///   - settled: what finish detection reads (StateAggregator.settled); `previous` is the last
    ///     tick's.
    ///   - notices: the finish notices this tick's line carries.
    ///   - events: the Finished group's events, for counting what finished while away.
    ///   - idle: seconds since the last keyboard or mouse input, nil when unknown.
    mutating func tick(state: GlobalState, settled: GlobalState, previous: GlobalState?,
                       usage: UsageSnapshot?, context: [String: ContextBudget.Reading],
                       names: [String: String], notices: [Chatter.DoneNotice],
                       events: [CompletionEvent], shell: Shell, idle: TimeInterval?,
                       now: Date) -> Out {
        // What crossed while napping is not news afterwards: start the alarm over, as the
        // Mac's pause toggle does.
        if shell.napping != napping {
            napping = shell.napping
            contextAlarm = ContextAlarm()
        }
        guard !shell.napping else { return Out() }
        var out = Out()
        out.flash = Self.transient(settled, previous: previous)
        contextAlarm.observe(context)
        // announceFinishes: the notices are said unless the list is open (the page skips them).
        if !notices.isEmpty, !shell.listOpen {
            lastSpoken[.sessionDone] = now
            lastAnything = now
        }
        if let line = noticeReturn(state, usage: usage, names: names, events: events,
                                   idle: idle, now: now) {
            // The line has one bubble, and the page would keep the away line over anything
            // maybeSpeak could add now (a notice outranks a warning there). So maybeSpeak waits
            // a tick rather than saying what would not show and recording it as said.
            out.say = line
            return out
        }
        out.say = maybeSpeak(settled, previous: previous, usage: usage, context: context,
                             names: names, shell: shell, now: now)
        return out
    }

    /// The Mac's noticeTransients: a brief reaction to trouble (a new troubleAt) or a finish.
    /// Trouble outranks a finish in the same tick.
    static func transient(_ state: GlobalState, previous: GlobalState?) -> String? {
        guard let previous else { return nil }
        let was = Dictionary(previous.sessions.map { ($0.sessionId, $0.troubleAt) },
                             uniquingKeysWith: { a, _ in a })
        let brokeJustNow = state.sessions.contains { session in
            guard let now = session.troubleAt else { return false }
            // A session appearing with trouble already recorded is not news.
            guard let before = was[session.sessionId] else { return false }
            return before != now
        }
        if brokeJustNow { return "trouble" }
        if !Chatter.justFinished(previous: previous, current: state).isEmpty { return "done" }
        return nil
    }

    /// The Mac's noticeReturn: once input has been idle for AwayReport.awayAfter, the next input
    /// gets one line on what finished, what waits and how much quota went meanwhile.
    private mutating func noticeReturn(_ state: GlobalState, usage: UsageSnapshot?,
                                       names: [String: String], events: [CompletionEvent],
                                       idle: TimeInterval?, now: Date) -> Speech? {
        guard let idle else { return nil }
        guard let start = awayStart else {
            if idle >= AwayReport.awayAfter {
                awayStart = now.addingTimeInterval(-idle)
                quotaAtLeave = usage?.fiveHourPercent
            }
            return nil
        }
        guard idle < AwayReport.backWithin else { return nil }
        awayStart = nil
        let waiting = state.sessions
            .filter { $0.state == .waiting }
            .sorted { $0.since < $1.since }
            .map { AwayReport.Waiting(name: names[$0.sessionId] ?? $0.project,
                                      waited: now.timeIntervalSince($0.since)) }
        let finished = events.filter { $0.finishedAt >= start }.count
        let used = usage.flatMap { u in quotaAtLeave.map { u.fiveHourPercent - $0 } }
        guard let line = AwayReport.line(away: now.timeIntervalSince(start), finished: finished,
                                         waiting: waiting, quotaUsed: used) else { return nil }
        lastAnything = now
        return Speech(text: line, emphasis: "", variant: .notice, hold: Self.awayHold)
    }

    /// The Mac's maybeSpeak: Chatter.next with the quota and context alarms, recorded only
    /// when it is said.
    private mutating func maybeSpeak(_ state: GlobalState, previous: GlobalState?,
                                     usage: UsageSnapshot?, context: [String: ContextBudget.Reading],
                                     names: [String: String], shell: Shell, now: Date) -> Speech? {
        guard !shell.cardUp else { return nil }
        let rearmed = QuotaAlarm.rearmed(quotaSaid, usage: usage, now: now)
        if rearmed != quotaSaid {
            quotaSaid = rearmed
            saveQuotaSaid()
        }
        let decision = QuotaAlarm.evaluate(usage: usage, alreadySaid: quotaSaid, now: now)
        let note = contextAlarm.due.lazy.compactMap { sid -> Chatter.ContextNote? in
            guard let session = state.sessions.first(where: { $0.sessionId == sid }),
                  let reading = context[sid] else { return nil }
            return Chatter.ContextNote(sessionId: sid, name: names[sid] ?? session.project,
                                       tokens: reading.tokens)
        }.first
        guard let line = Chatter.next(
            state: state, previous: previous, usage: usage, now: now,
            lastSpoken: lastSpoken, lastAnything: lastAnything, names: names,
            quotaAlarm: decision.speak, contextNote: note
        ) else { return nil }
        let bubble = Chatter.bubble(for: line.kind)
        // The list is open and carries this news itself: nothing said, nothing recorded, so
        // the next tick decides again once it closes (Chatter.yieldsToList).
        if shell.listOpen, Chatter.yieldsToList(bubble) { return nil }
        if line.kind == .quotaHigh {
            quotaSaid.formUnion(decision.markSaid)
            quotaSaid = QuotaAlarm.pruned(quotaSaid, now: now)
            saveQuotaSaid()
        }
        if line.kind == .contextLong, let note { contextAlarm.said(note.sessionId) }
        lastSpoken[line.kind] = now
        lastAnything = now
        return Speech(text: line.text, emphasis: line.emphasis, variant: bubble, hold: Self.speechHold)
    }

    private func saveQuotaSaid() {
        guard let url = quotaSaidURL,
              let data = try? JSONEncoder().encode(quotaSaid.sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Seconds since the last keyboard or mouse input in this session; nil where unknown.
    static func idleSeconds() -> TimeInterval? {
        #if os(Windows)
        var info = LASTINPUTINFO()
        info.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
        guard GetLastInputInfo(&info) else { return nil }
        // Both are 32-bit tick counts: the difference is right across the 49-day wrap.
        return TimeInterval(GetTickCount() &- info.dwTime) / 1000
        #else
        return nil
        #endif
    }
}

/// What the shell writes to `--watch`'s stdin, one setting per line: `list 1`, `card 0`,
/// `nap 1`. Read on a thread of its own; a closed stdin (no shell, an older one) leaves the
/// defaults.
final class PetShellInput: @unchecked Sendable {
    private let lock = NSLock()
    private var shell = PetChatter.Shell()

    var current: PetChatter.Shell {
        lock.lock(); defer { lock.unlock() }
        return shell
    }

    func start() {
        let thread = Thread { [self] in
            while let line = readLine() { apply(line) }
        }
        thread.start()
    }

    func apply(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count == 2 else { return }
        let on = parts[1] == "1"
        lock.lock(); defer { lock.unlock() }
        switch parts[0] {
        case "list": shell.listOpen = on
        case "card": shell.cardUp = on
        case "nap": shell.napping = on
        default: break
        }
    }
}
