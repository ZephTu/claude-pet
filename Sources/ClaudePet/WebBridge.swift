import Foundation
import WebKit
import ClaudePetCore

/// Pushes GlobalState into the page. Skips redundant pushes so a busy session
/// firing hooks every second does not restart the CSS animation every second.
///
/// Nothing is sent, and nothing is recorded, until the page says it is ready.
/// That gate is load-bearing: the first render happens inside
/// applicationDidFinishLaunching, long before loadFileURL finishes, so
/// `window.setMood` does not exist yet. Recording that push as "the last state
/// sent" made the dedup guard suppress every later push of the same state —
/// the pet stayed on the page's default `idle` until the global mood happened
/// to change on its own.
@MainActor
final class WebBridge {
    /// The user pressed × on a session row.
    var onMute: ((String) -> Void)?
    /// The session list just became visible.
    var onPanelOpened: (() -> Void)?
    /// The user acknowledged these finished turns.
    var onMarkRead: (([String]) -> Void)?
    /// The user cleared the whole finished list.
    var onMarkAllRead: (() -> Void)?
    /// The user wants to be reminded about this session later; the point is
    /// where to put the menu.
    var onSnooze: ((String, CGPoint) -> Void)?
    /// Right-click landed on a session row rather than on the pet.
    var onRowMenu: ((String, CGPoint) -> Void)?

    private weak var webView: WKWebView?
    private var isReady = false
    private var last: GlobalState?
    private var lastSessionsPayload: String?
    private var lastHoverPoint: CGPoint?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// Call from the navigation delegate's didFinish, before re-rendering.
    /// Clearing the dedup memory here also covers a reload: the page is back at
    /// its defaults, so whatever we sent before must be sent again.
    func markReady() {
        isReady = true
        last = nil
        lastSessionsPayload = nil
        lastSkin = nil
        lastLook = nil
    }

    func push(_ state: GlobalState, motion: ActivitySummary.Motion? = nil) {
        guard isReady else { return }
        guard state != last || motion != lastMotion else { return }
        last = state
        lastMotion = motion

        let project = state.waitingProject.map { "\"\(escape($0))\"" } ?? "null"
        let on = "\"\(escape(state.waitingOn))\""
        let move = motion.map { "\"\($0.rawValue)\"" } ?? "\"\""
        evaluate("window.setMood(\"\(state.mood.rawValue)\", \(project), \(on), \(move));")
    }

    private var lastMotion: ActivitySummary.Motion?

    /// Left click on the pet expands or collapses the session panel. Swift owns
    /// this because the host view now consumes every mouse event before the page
    /// can see it — see PetHostView.
    func togglePanel() {
        guard isReady, let webView else { return }
        // Pinned: a click is not a request to close, and there is nothing to
        // open either. Asserting the state rather than returning outright covers
        // the one case where they disagree — pinning while the panel is shut.
        if panelPinned { return setPanelOpen(true) }
        webView.evaluateJavaScript("window.togglePanel();") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if result as? Bool == true { self?.onPanelOpened?() }
            }
        }
    }

    /// The user asked for the list to stay up — AppMain's "Keep List Open".
    /// While this is on, nothing closes the panel except turning it back off.
    var panelPinned = false

    /// Put the panel in a known state. Used where the caller knows which state
    /// it wants, as opposed to a click, which is a request to flip.
    ///
    /// Deliberately does NOT fire `onPanelOpened`: that means "the user just
    /// opened the list", which is what makes it the right moment to go and read
    /// terminal titles. Asserting the state of a pinned panel is not that, and a
    /// pinned panel has its own trigger for titles — see
    /// PanelModel.shouldRefreshTitles.
    func setPanelOpen(_ open: Bool) {
        guard isReady else { return }
        evaluate("window.setPanelOpen(\(open));")
    }

    /// "Done with the list now" — after a jump, say. A no-op while pinned, which
    /// is the whole difference between a pinned panel and an open one.
    func closePanel() {
        guard !panelPinned else { return }
        setPanelOpen(false)
    }

    /// Resolve a left click: a session row we can jump to wins, anything else
    /// toggles the panel.
    ///
    /// The row lookup has to happen in the page, because row positions depend on
    /// content height and on the panel's own scroll offset. That makes this
    /// asynchronous, which is why the toggle lives in the callback rather than
    /// running first and being undone.
    func handleClick(at point: CGPoint) {
        guard isReady, let webView else { return }
        let js = "window.hitRow(\(point.x), \(point.y));"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    NSLog("ClaudePet: hitRow failed: \(error.localizedDescription)")
                    self.togglePanel()
                    return
                }
                guard let row = result as? [String: Any] else {
                    self.togglePanel()
                    return
                }
                switch row["action"] as? String {
                case "mute":
                    if let id = row["sessionId"] as? String, !id.isEmpty {
                        // The list stays open: muting several in a row is the
                        // common case, and reopening the panel each time is worse
                        // than leaving it up.
                        self.onMute?(id)
                    }
                case "jump":
                    guard
                        let kind = row["kind"] as? String,
                        let handle = row["handle"] as? String,
                        !handle.isEmpty
                    else {
                        self.togglePanel()
                        return
                    }
                    TerminalJump.jump(kind: kind, handle: handle)
                    // The list has served its purpose once we are jumping away.
                    self.closePanel()
                case "read":
                    // Acknowledging a finished turn. The list stays open: the
                    // user is working through it, and closing it after each one
                    // would make clearing three rows take three openings.
                    self.onMarkRead?(row["eventIds"] as? [String] ?? [])
                case "readAll":
                    self.onMarkAllRead?()
                case "snooze":
                    self.onSnooze?(row["sessionId"] as? String ?? "", point)
                case "openFinished":
                    let ids = row["eventIds"] as? [String] ?? []
                    let handle = row["handle"] as? String ?? ""
                    switch PanelModel.finishedClick(handle: handle) {
                    case .openThenRead:
                        // Go there, and only then call it read: a jump that
                        // never happened must not clear the one record that it
                        // happened at all.
                        TerminalJump.jump(kind: row["kind"] as? String ?? "", handle: handle)
                        self.onMarkRead?(ids)
                        self.closePanel()
                    case .read:
                        // The terminal is gone, so there is no jump left to
                        // protect the record from. The click clears the row and
                        // says why it did not open anything. The list stays up,
                        // same as the ✓.
                        self.onMarkRead?(ids)
                        self.evaluate("window.explainClosedRow();")
                    }
                default:
                    self.togglePanel()
                }
            }
        }
    }

    /// Show a line for `hold` seconds. Fire-and-forget: the page owns the timer,
    /// because a dropped call must not leave a bubble stuck on screen.
    ///
    /// `variant` says which KIND of message window this is — see
    /// `Chatter.Bubble`. The page needs it to decide what a line is allowed to
    /// replace: a wellness nudge must not take the bubble away from a quota
    /// warning just because it arrived second.
    func say(_ text: String, hold: TimeInterval, emphasis: String = "",
             variant: Chatter.Bubble = .chat) {
        guard isReady else { return }
        evaluate("window.say(\(jsString(text)), \(Int(hold * 1000)), "
                 + "\(jsString(emphasis)), \(jsString(variant.rawValue)));")
    }

    /// Routes a right click: a session row gets its own menu, anything else
    /// falls through to the pet's global menu.
    func handleRightClick(at point: CGPoint, fallback: @escaping @MainActor () -> Void) {
        guard isReady, let webView else { return fallback() }
        webView.evaluateJavaScript("window.rowSessionId(\(point.x), \(point.y));") { result, _ in
            MainActor.assumeIsolated {
                let id = result as? String ?? ""
                if id.isEmpty { fallback() } else { self.onRowMenu?(id, point) }
            }
        }
    }

    /// Asks the page which session is under this point.
    func rowSessionId(at point: CGPoint, completion: @escaping @MainActor (String) -> Void) {
        guard isReady, let webView else { return completion("") }
        webView.evaluateJavaScript("window.rowSessionId(\(point.x), \(point.y));") { result, _ in
            MainActor.assumeIsolated { completion(result as? String ?? "") }
        }
    }

    /// Draws the quota meters. Numbers go over as structured values, not as a
    /// formatted string, so the page can lay out bars and nothing has to be
    /// escaped.
    func showQuota(rows: [Chatter.QuotaRow], fallback: String) {
        guard isReady else { return }
        let items = rows.map { ["label": $0.label, "percent": $0.percent, "resetsIn": $0.resetsIn] }
        guard
            let data = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.showQuota(\(json), \(jsString(fallback)));")
    }

    /// How many things want the user right now. Deduped so a 5-second tick does
    /// not touch the DOM when the number has not moved.
    private var lastBadge: String?
    func setBadge(_ text: String) {
        guard isReady, text != lastBadge else { return }
        lastBadge = text
        evaluate("window.setBadge(\(jsString(text)));")
    }

    /// A brief reaction that is not a state — see window.flash.
    ///
    /// The pose and the glyph travel with it because the robot's flash is a
    /// CSS rule and a painted skin has no rule to run: a finished turn is a bob
    /// of the idle picture, an interrupted tool is a warning glyph over
    /// whatever the cat is already doing.
    func flash(_ kind: String) {
        guard isReady else { return }
        let mark = CatSkin.mark(mood: "", flash: kind, blockedOn: "").rawValue
        // Empty means "keep the pose you have": an interrupted tool happens
        // while the session carries on working, and replacing the picture would
        // say it stopped.
        let pose = CatSkin.flashPose(kind)?.rawValue ?? ""
        evaluate("window.flash(\(jsString(kind)), "
            + "\(jsString(pose)), \(jsString(mark)));")
    }

    private var lastSkin: PetSkin?
    func setSkin(_ skin: PetSkin) {
        guard isReady, skin != lastSkin else { return }
        lastSkin = skin
        evaluate("window.setSkin(\(jsString(skin.rawValue)));")
    }

    /// The pose and glyph a painted skin should show. Pushed on every render;
    /// the page ignores it while the robot is up.
    private var lastLook: CatSkin.Look?
    func setCatLook(_ look: CatSkin.Look) {
        guard isReady, look != lastLook else { return }
        lastLook = look
        evaluate("window.setCatLook(\(jsString(look.pose.rawValue)), "
            + "\(jsString(look.mark.rawValue)));")
    }

    private var lastPhase: String?
    func setPhase(_ phase: String) {
        guard isReady, phase != lastPhase else { return }
        lastPhase = phase
        evaluate("window.setPhase(\(jsString(phase)));")
    }

    private var lastCalm: Bool?
    func setCalm(_ on: Bool) {
        guard isReady, on != lastCalm else { return }
        lastCalm = on
        evaluate("window.setCalm(\(on));")
    }

    private var lastMirrored: Bool?
    func setMirrored(_ on: Bool) {
        guard isReady, on != lastMirrored else { return }
        lastMirrored = on
        evaluate("window.setMirrored(\(on));")
    }

    /// Draws the hover readout for one row.
    func showDetail(_ d: SessionDetail.Detail) {
        guard isReady, !d.isEmpty else { return }
        var doc: [String: Any] = [
            "path": d.path, "worktree": d.worktree, "model": d.model,
            "turn": d.turn, "quiet": d.quiet, "last": d.last, "lastBad": d.lastBad,
        ]
        if let percent = d.contextPercent { doc["context"] = percent }
        guard
            let data = try? JSONSerialization.data(withJSONObject: doc),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.showDetail(\(json));")
    }

    func hush() {
        guard isReady else { return }
        evaluate("window.hush();")
    }

    /// Quota numbers and project names both end up inside a JS string literal.
    private func jsString(_ s: String) -> String {
        "\"\(escape(s))\""
    }

    /// Highlight the row under the pointer. Skips repeats so a stationary cursor
    /// under the 0.08s click-through poll costs nothing.
    func setHover(at point: CGPoint) {
        guard isReady, point != lastHoverPoint else { return }
        lastHoverPoint = point
        evaluate("window.setHoverAt(\(point.x), \(point.y));")
    }

    /// Project names come from directory names, so they can contain anything.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// handle → tab title, refreshed when the user opens the list.
    var titles: [String: String] = [:]

    func pushSessions(_ sessions: [SessionState], now: Date, hiddenCount: Int = 0,
                      completions: [CompletionEvent] = [],
                      titlesByHandle: [String: String] = [:],
                      droppedNotice: Int = 0,
                      snoozed: [String: Snooze.Mark] = [:],
                      prefs: [String: SessionLabels.Prefs] = [:],
                      branches: [String: String] = [:]) {
        guard isReady else { return }
        // Only rows that share a project with another need naming inline.
        let ambiguous = StateAggregator.ambiguousProjects(sessions)
        // Pinned rows rise within their group, never above a blocked session:
        // pinning says "I care about this one", not "hide the urgent one".
        let sessions = SessionLabels.ordered(sessions, prefs: prefs)
        let items = sessions.map { s -> [String: Any] in
            let title = s.terminal.flatMap { titlesByHandle[$0.handle] } ?? ""
            var item: [String: Any] = [
                "sessionId": s.sessionId,
                "project": SessionLabels.displayName(for: s, prefs: prefs, title: title),
                "state": s.state.rawValue,
                "tool": s.tool,
                // The second line of the row. Design doc section 2 puts the
                // notification in the expanded panel and keeps it out of the
                // bubble; SessionCopy decides whether it says anything the
                // first line has not already said — see SessionCopy.note.
                "detail": SessionCopy.note(state: s.state, detail: s.detail,
                                           waitingOn: s.waitingOn),
                "waitedSeconds": Int(max(0, now.timeIntervalSince(s.since))),
            ]
            // Busy on paper, but nothing in flight and nothing heard for a
            // while: the row stops claiming to be thinking, without claiming to
            // be done — see StateAggregator.isQuiet.
            if StateAggregator.isQuiet(s, now: now) { item["quiet"] = true }
            // Blocked on a permission rather than on an answer. The two are the
            // same colour of "waiting" and not the same request: one wants a
            // decision, the other wants typing, and the row says which.
            if s.state == .waiting, !s.waitingOn.isEmpty { item["asks"] = "permission" }
            // "It answered and is waiting on the next instruction" is a fact
            // about the session, not about whether its second line happens to
            // carry text. It used to be read off `detail`, which meant dropping
            // the boilerplate sentence ALSO downgraded the row to plain idle.
            if s.state == .idle, !s.detail.isEmpty { item["replied"] = true }
            // Ignored for long enough that the pet's own alarm has gone off.
            // Same threshold, so the panel and the figure never disagree about
            // which session is the urgent one.
            if s.state == .waiting,
               SessionCopy.isUrgent(waitedFor: now.timeIntervalSince(s.since)) {
                item["urgent"] = true
            }
            // A postponed row stays in the list and says how much longer, so
            // "remind me later" never turns into "forget about it".
            let left = Snooze.remaining(s, marks: snoozed, now: now)
            if !left.isEmpty { item["snoozedFor"] = left }

            // What it is doing RIGHT NOW, from the calls that have started and
            // not reported back — rather than from the name of the last tool
            // seen, which kept reading as "running" long after it returned.
            //
            // A session waiting on a background agent has no tool call in
            // flight — Stop cleared them — so without this its row would say
            // nothing at all while looking busy, which is the least helpful
            // combination available.
            if !s.backgroundAgents.isEmpty {
                item["activity"] = BackgroundWork.phrase(s.backgroundAgents)
            } else if s.running.count > 1 {
                item["activity"] = ActivitySummary.concurrent(s.running.count)
            } else if let only = s.running.first {
                item["activity"] = ActivitySummary.phrase(toolName: only.tool, target: only.target)
                if let began = only.since {
                    item["toolSeconds"] = Int(max(0, now.timeIntervalSince(began)))
                }
            }
            // Only sessions we can actually jump to carry these, and only those
            // rows render as clickable.
            if let t = s.terminal, TerminalTarget.canJump(kind: t.kind) {
                item["termKind"] = t.kind
                item["termHandle"] = t.handle
                // The project column is just the directory name, so three
                // sessions in one repo all read the same. The tab title is what
                // tells them apart.
                if let title = titles[t.handle], !TerminalTitles.isUseless(title) {
                    item["title"] = title
                    if PanelModel.shouldShowNameInline(
                        displayed: item["project"] as? String ?? "",
                        title: title,
                        ambiguous: ambiguous.contains(s.project)) {
                        item["nameInline"] = true
                    }
                }
            }
            return item
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let rows = PanelModel.completionRows(completions, live: sessions,
                                             titles: titlesByHandle)
        let finished = rows.map { row -> [String: Any] in
            var item: [String: Any] = [
                "sessionId": row.sessionId,
                "eventIds": row.eventIds,
                "label": row.label,
                "count": row.count,
                "closed": row.sessionClosed,
                "agoSeconds": Int(max(0, now.timeIntervalSince(row.latestAt))),
            ]
            if row.canJump, let t = row.terminal {
                item["termKind"] = t.kind
                item["termHandle"] = t.handle
            }
            return item
        }
        guard
            let finishedData = try? JSONSerialization.data(withJSONObject: finished),
            let finishedJSON = String(data: finishedData, encoding: .utf8)
        else { return }

        let payload = "\(json)|\(hiddenCount)|\(finishedJSON)|\(droppedNotice)"
        guard payload != lastSessionsPayload else { return }
        lastSessionsPayload = payload
        evaluate("window.setSessions(\(json), \(hiddenCount), \(finishedJSON), \(droppedNotice));")
    }

    /// A nil completionHandler swallows JS errors silently, which is exactly how
    /// the startup bug above stayed invisible. Log instead.
    private func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("ClaudePet: JS push failed: \(error.localizedDescription)")
            }
        }
    }
}
