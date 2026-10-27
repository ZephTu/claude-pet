import AppKit
import ClaudePetCore

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        // Layout check for the connection panel, used during development
        // because screen capture needs a permission this app should not ask for.
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--render-health"), i + 1 < arguments.count {
            app.setActivationPolicy(.prohibited)
            let sample: [HealthCheck] = [
                HealthReport.claudeCode(version: "2.1.274 (Claude Code)",
                                        path: NSHomeDirectory() + "/.npm-global/bin/claude"),
                HealthReport.hooks(installed: 8, expected: 8, binaryExists: true),
                HealthReport.recentEvents(lastAt: Date().addingTimeInterval(-120),
                                          liveSessions: 4, now: Date()),
                HealthReport.sessions(running: 6, known: 4),
                HealthReport.terminals(kinds: ["orca"], lastFailure: ""),
                HealthReport.usage(source: "claude-hud", capturedAt: Date().addingTimeInterval(-3000),
                                   now: Date(), stale: true),
                HealthReport.stateFiles(writable: true, count: 4, corrupt: 1),
            ]
            exit(MainActor.assumeIsolated {
                HealthWindow.renderPreview(checks: sample, to: arguments[i + 1]) ? 0 : 1
            })
        }
        // Renders the real page to a PNG, because the one thing no test here can
        // check is whether the drawing and the hit rectangles agree.
        if let i = arguments.firstIndex(of: "--probe-skin"), i + 2 < arguments.count {
            app.setActivationPolicy(.prohibited)
            let script = i + 3 < arguments.count ? arguments[i + 3] : ""
            MainActor.assumeIsolated {
                SkinProbe.run(path: arguments[i + 1], imagePath: arguments[i + 2],
                              script: script) { exit($0) }
            }
            app.run()
        }
        // The same thing over time, for the README's animation. The page drives
        // its own state; this only presses the shutter.
        if let i = arguments.firstIndex(of: "--probe-film"), i + 4 < arguments.count {
            app.setActivationPolicy(.prohibited)
            let frames = Int(arguments[i + 3]) ?? 0
            let fps = Double(arguments[i + 4]) ?? 9
            let script = i + 5 < arguments.count ? arguments[i + 5] : ""
            MainActor.assumeIsolated {
                SkinProbe.film(path: arguments[i + 1], directory: arguments[i + 2],
                               frames: frames, fps: fps, script: script) { exit($0) }
            }
            app.run()
        }
        // .accessory keeps it out of the Dock and out of Cmd-Tab.
        app.setActivationPolicy(.accessory)
        let delegate = PetAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// NSApplicationDelegate is MainActor-isolated under Swift 6; the annotation
// states the isolation this class already had rather than adding any.
@MainActor
final class PetAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel?
    private var watcher: SessionWatcher?
    private var bridge: WebBridge?
    private var ticker: Timer?
    private var latest: [SessionState] = []
    private var paused = false
    private var menu: PetMenu?
    private var completions: CompletionStore?
    private var hotKey: HotKey?
    private let git = GitCache()
    private var labelPrefs: [String: SessionLabels.Prefs] = [:]
    /// The session list stays up instead of being opened per glance.
    private var keepListOpen = false
    /// Which sessions were live the last time terminal titles were actually
    /// fetched, and when. Only a pinned panel uses these — an unpinned one is
    /// still served by the fetch that runs when the user opens it.
    private var titlesRefreshedIds: Set<String> = []
    private var lastTitleRefresh: Date?
    private var windowVisible = true

    private var petHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/pet")
    }
    private var sessionsDirectory: URL { petHome.appending(path: "sessions") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = PetPanel()
        let bridge = WebBridge(webView: panel.webView)

        // Nothing may be pushed before the page can receive it, and the first
        // real render must happen here — not earlier. See WebBridge.markReady.
        panel.onReady = { [weak self, weak panel] in
            bridge.markReady()
            // The page has just loaded at its defaults, so whichever side it
            // should be on has to be pushed again.
            bridge.setMirrored(panel?.isMirrored ?? false)
            self?.applyMotionSetting()
            // The page reloaded at its defaults, which means shut. A pinned list
            // has to be put back up, and this is the first moment it can be.
            if self?.keepListOpen == true { bridge.setPanelOpen(true) }
            self?.render()
            self?.mentionProblem()
            // `--demo` cycles through every state, for looking at the artwork.
            // A launch flag rather than a menu item: nobody needs it day to day.
            if CommandLine.arguments.contains("--demo"), self?.demo == nil { self?.toggleDemo() }
        }
        panel.onMirrorChanged = { on in bridge.setMirrored(on) }
        // WebGL can be unavailable, and a texture can fail to decode. The page
        // falls back to still pictures on its own; this only records why.
        panel.onSkinFailed = { why in
            NSLog("ClaudePet: the cat could not animate, showing stills: \(why)")
        }
        // Follows the system's own Reduce Motion setting rather than keeping a
        // second switch for the same wish.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMotionSetting() }
        }
        // A pet nobody can see has no reason to repaint. Covered by another
        // window, on another Space, or on a sleeping display all land here.
        panel.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            windowVisible = visible
            applyMotionSetting()
            // Slowed right down rather than stopped: the panel has to be current
            // the moment it comes back, and a stopped clock would show whatever
            // was true when it got covered up.
            ticker?.invalidate()
            startTicker(interval: visible ? Self.tickInterval : Self.hiddenTickInterval)
        }
        keepListOpen = UserDefaults.standard.bool(forKey: Self.keepListOpenKey)
        bridge.panelPinned = keepListOpen
        panel.onClick = { point in bridge.handleClick(at: point) }
        panel.onHover = { [weak self] point, panelOpen in
            if panelOpen { bridge.setHover(at: point) }
            self?.updateDwell(at: point, panelOpen: panelOpen)
        }
        bridge.onMute = { [weak self] id in self?.mute(sessionID: id) }
        bridge.onOpenNotice = { [weak self] id in self?.openNotice(sessionID: id) }
        bridge.onDecide = { [weak self] id, ask, behavior in
            self?.answer(sessionID: id, askId: ask, behavior: behavior)
        }
        // Titles cost a subprocess, so they are fetched when the user opens the
        // list — never on a timer for a panel nobody has looked at.
        bridge.onPanelOpened = { [weak self] in self?.refreshTitles() }
        loadHidden()
        loadSnoozed()
        loadQuotaSaid()
        loadLabels()
        git.onUpdate = { [weak self] in self?.render() }
        bridge.onRowMenu = { [weak self] id, point in self?.showRowMenu(sessionID: id, at: point) }
        // Off unless the user asked for it: claiming a system-wide chord
        // uninvited is taking something that was not offered.
        let hotKey = HotKey { [weak self] in self?.jumpToNextWaiting() }
        self.hotKey = hotKey
        if UserDefaults.standard.bool(forKey: Self.hotKeyKey) { hotKey.register() }
        bridge.onSnooze = { [weak self] id, point in self?.askSnooze(sessionID: id, at: point) }
        let completions = CompletionStore(petHome: petHome)
        completions.reload(now: Date(), force: true)
        self.completions = completions
        bridge.onMarkRead = { [weak self] ids in self?.markRead(ids) }
        bridge.onMarkAllRead = { [weak self] in self?.markAllRead() }
        panel.showOnDesktop()
        panel.updateLayoutSide()
        // A saved spot can be on a display that is no longer attached, or one
        // that has since shrunk.
        panel.rescueIfOffScreen()

        let menu = PetMenu(
            onPauseToggle: { [weak self] in
                guard let self else { return }
                paused.toggle()
                render()
            },
            onLoginToggle: { [weak self] in self?.toggleLaunchAtLogin() },
            onUnmuteAll: { [weak self] in self?.unmuteAll() },
            onShortcutToggle: { [weak self] in self?.toggleHotKey() },
            onShowHealth: { [weak self] in self?.showHealth() },
            onKeepListOpenToggle: { [weak self] in self?.toggleKeepListOpen() },
            onQuit: { NSApp.terminate(nil) }
        )
        panel.onRightClick = { [weak self, weak panel] point in
            guard let self, let view = panel?.contentView else { return }
            // A row's own menu when the pointer is on one; the pet's menu
            // otherwise. Asking the page is asynchronous, hence the closure.
            bridge.handleRightClick(at: point) { [weak self] in
                guard let self else { return }
                menu.show(at: point, in: view,
                          paused: self.paused,
                          launchesAtLogin: self.launchesAtLogin,
                          mutedCount: self.hiddenMarks.count,
                          shortcutOn: self.hotKey?.isRegistered ?? false,
                          keepListOpenOn: self.keepListOpen,
                          problem: HealthCollector.quickProblem(petHome: self.petHome))
            }
        }
        self.menu = menu

        let watcher = SessionWatcher(directory: sessionsDirectory) { [weak self] states in
            self?.latest = states
            self?.pruneHidden()
            self?.render()
        }
        watcher.start()

        // Time passes even when no file changes: a session that has been waiting
        // 59s must still escalate to urgent at 61s, and a dead session must stop
        // counting. Nothing writes a file at that moment, so re-aggregate on a timer.
        startTicker(interval: Self.tickInterval)

        self.panel = panel
        self.bridge = bridge
        self.watcher = watcher
    }

    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate()
        watcher?.stop()
        panel?.stopClickThroughMonitoring()
    }

    private func render() {
        // The demo drives the display itself; a real render would fight it.
        guard demo == nil else { return }
        let now = Date()
        let state = paused
            ? GlobalState(mood: .idle, sessions: [], waitingProject: nil)
            : StateAggregator.aggregate(latest, now: now, hidden: hiddenMarks,
                                        snoozed: snoozeMarks, approved: isSettled)
        // The hit region is a pair of fixed rectangles now (PetLayout.bodyBox /
        // antennaBox), so the window no longer needs telling about mood.
        // Expiry is judged against `now` rather than by a timer, so sleeping
        // through a delay is a no-op instead of a burst of catch-up reminders.
        let survivingMarks = Snooze.pruned(snoozeMarks, keeping: state.sessions, now: now)
        if survivingMarks.count != snoozeMarks.count {
            snoozeMarks = survivingMarks
            saveSnoozed()
        }
        loadInsights()
        completions?.reload(now: now)
        let unread = paused ? [] : (completions?.unread ?? [])
        let motion = currentMotion(state, now: now)
        bridge?.push(state, motion: motion)
        // A phase belongs to a session, but the pet shows one figure, so any
        // session compacting puts the whole pet in that phase. It is a brief
        // state and showing it late is worse than showing it broadly.
        //
        // "Awaiting an agent" does not get that treatment: it can last a quarter
        // of an hour, and a session that is genuinely typing must not be drawn
        // as one that is sitting and watching. So it shows only when no session
        // has a tool call in flight — when waiting really is all that is
        // happening.
        bridge?.setPhase(StateAggregator.phase(state.sessions))
        refreshTitlesIfPinned(for: state.sessions, now: now)
        noticeTransients(state, previous: lastState)
        bridge?.pushSessions(state.sessions, now: now, hiddenCount: state.hiddenCount,
                             completions: unread, titlesByHandle: bridge?.titles ?? [:],
                             droppedNotice: completions?.takeDropNotice() ?? 0,
                             snoozed: snoozeMarks, prefs: labelPrefs,
                             branches: branches(for: state.sessions))
        // One number for "how many things want me": sessions blocked on the user,
        // plus finished turns they have not looked at.
        // A postponed item does not count toward the badge: the user said "not
        // now", and a number that keeps standing there is still nagging.
        let badge = PanelModel.badge(
            needsYou: PanelModel.needsYou(state.sessions)
                .filter { !Snooze.isSnoozed($0, marks: snoozeMarks, now: now) }.count,
            unreadFinishes: PanelModel.completionRows(unread, live: state.sessions).count)
        bridge?.setBadge(badge)
        // What the cat shows is decided here and pushed — see CatSkin.
        bridge?.setCatLook(CatSkin.look(mood: state.mood.rawValue,
                                        phase: StateAggregator.phase(state.sessions),
                                        flash: "",
                                        wanted: !badge.isEmpty,
                                        blockedOn: state.waitingOn, motion: motion,
                                        struggling: state.sessions.contains(where: Struggle.isStruggling)))
        announceFinishes(state, now: now)
        noticeReturn(state, now: now)
        maybeSpeak(state: state, now: now)
        lastState = state
    }

    // MARK: - Away and back

    /// When nobody has touched the machine since, or nil while somebody is
    /// at it. Set once input has been idle for `AwayReport.awayAfter`.
    private var awayStart: Date?
    /// The five-hour quota reading at that moment, to say how much went.
    private var quotaAtLeave: Int?

    /// Says what happened while the person was away, once, as they come back.
    private func noticeReturn(_ state: GlobalState, now: Date) {
        guard !paused else { return }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if awayStart == nil {
            if idle >= AwayReport.awayAfter {
                awayStart = now.addingTimeInterval(-idle)
                quotaAtLeave = currentUsage()?.fiveHourPercent
            }
            return
        }
        guard let start = awayStart, idle < AwayReport.backWithin else { return }
        awayStart = nil
        let names = sessionNames(state)
        let waiting = state.sessions
            .filter { $0.state == .waiting }
            .sorted { $0.since < $1.since }
            .map { AwayReport.Waiting(name: names[$0.sessionId] ?? $0.project,
                                      waited: now.timeIntervalSince($0.since)) }
        let finished = (completions?.events ?? []).filter { $0.finishedAt >= start }.count
        let used = currentUsage().flatMap { now in quotaAtLeave.map { now.fiveHourPercent - $0 } }
        guard let line = AwayReport.line(away: now.timeIntervalSince(start), finished: finished,
                                         waiting: waiting, quotaUsed: used) else { return }
        bridge?.say(line, hold: 15, variant: .notice)
        lastAnything = now
    }

    // MARK: - Talking

    /// How long a line stays up before it takes itself away.
    private static let speechHold: TimeInterval = 6

    /// One notice per session that just finished, each up for its own
    /// `Chatter.noticeHold` — see window.notify for the stack they sit in.
    ///
    /// Not while paused (the pet is asleep), and not while the list is open:
    /// the Finished group is showing exactly these, and a notice would only
    /// sit across the list's corner.
    private func announceFinishes(_ state: GlobalState, now: Date) {
        guard !paused, panel?.isListOpen != true else { return }
        let notices = Chatter.doneNotices(previous: lastState, current: state,
                                          names: sessionNames(state),
                                          summaries: latestSummaries(now: now))
        for notice in notices {
            let terminal = state.sessions.first { $0.sessionId == notice.sessionId }?.terminal
            bridge?.notify(notice.text, hold: Chatter.noticeHold, emphasis: notice.emphasis,
                           sessionId: notice.sessionId,
                           jumpable: terminal.map { TerminalTarget.canJump(kind: $0.kind) } ?? false)
        }
        if !notices.isEmpty {
            lastSpoken[.sessionDone] = now
            lastAnything = now
        }
    }
    /// How long the pointer must rest on the pet before it volunteers the quota.
    private static let dwellDelay: TimeInterval = 1

    private var lastState: GlobalState?
    private var lastSpoken: [Chatter.Kind: Date] = [:]
    private var lastAnything: Date?
    private var usageCache: (snapshot: UsageSnapshot?, readAt: Date)?
    private var dwellTimer: Timer?
    private var dwellShowing = false
    private var dwellTarget: DwellTarget?
    /// A row name needs a shorter fuse than the quota readout: the pointer is
    /// already moving down a list, and a full second feels broken.
    private static let rowDwellDelay: TimeInterval = 0.45

    private var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// The cache is another plugin's file, refreshed every five minutes, so
    /// re-reading it on every 5s render would be pure waste.
    private func currentUsage() -> UsageSnapshot? {
        let now = Date()
        if let cached = usageCache, now.timeIntervalSince(cached.readAt) < 60 {
            return cached.snapshot
        }
        // Two possible sources, read independently and never blended. The one
        // that wins is decided by UsageSources, which puts freshness first: a
        // reading from a better source that has gone stale still describes a
        // window that may have rolled over.
        var candidates: [UsageSnapshot] = []
        if let hud = (try? Data(contentsOf: UsageReader.cacheURL(claudeHome: claudeHome)))
            .flatMap(UsageReader.parse) {
            candidates.append(hud)
        }
        if let line = (try? Data(contentsOf: StatuslineUsage.cacheURL(petHome: petHome)))
            .flatMap(StatuslineUsage.decode) {
            candidates.append(line)
        }
        let snapshot = UsageSources.pick(candidates, now: now)
        usageCache = (snapshot, now)
        return snapshot
    }

    private static let quotaSaidKey = "quotaThresholdsSaid"
    private var quotaSaid: Set<String> = []

    private func loadQuotaSaid() {
        quotaSaid = Set(UserDefaults.standard.stringArray(forKey: Self.quotaSaidKey) ?? [])
    }

    private func saveQuotaSaid() {
        UserDefaults.standard.set(Array(quotaSaid), forKey: Self.quotaSaidKey)
    }

    private func maybeSpeak(state: GlobalState, now: Date) {
        // Paused means the pet is asleep, and a sleeping cat with a speech
        // bubble is just wrong. It also never sees real transitions while
        // paused, since render() substitutes a fixed idle state.
        guard !paused, !dwellShowing else { return }
        let usage = currentUsage()
        let decision = QuotaAlarm.evaluate(usage: usage, alreadySaid: quotaSaid, now: now)
        guard let line = Chatter.next(
            state: state, previous: lastState, usage: usage, now: now,
            lastSpoken: lastSpoken, lastAnything: lastAnything, names: sessionNames(state),
            quotaAlarm: decision.speak
        ) else { return }
        // The list is open and carrying this news itself: step aside rather than
        // draw a bubble across its top-right corner. Deliberately BEFORE every
        // piece of bookkeeping below — nothing was said, so nothing is marked
        // said, and closing the list lets the next tick decide again from the
        // state of the world then. See Chatter.yieldsToList.
        if panel?.isListOpen == true,
           Chatter.yieldsToList(Chatter.bubble(for: line.kind)) {
            return
        }
        // Recorded only when it is actually SAID. That is what makes a warning
        // suppressed by an alarm come back afterwards instead of being lost:
        // nothing was said, so nothing was marked, so it is still pending next
        // time round.
        if line.kind == .quotaHigh {
            quotaSaid.formUnion(decision.markSaid)
            quotaSaid = QuotaAlarm.pruned(quotaSaid, now: now)
            saveQuotaSaid()
        }
        bridge?.say(line.text, hold: Self.speechHold, emphasis: line.emphasis,
                    variant: Chatter.bubble(for: line.kind))
        lastSpoken[line.kind] = now
        lastAnything = now
    }

    /// sessionId → the first line of what Claude said at the end of its most
    /// recent finished turn. Read or not: the bubble announces the finish that
    /// just happened, which is the newest one whatever the user has seen.
    ///
    /// Only the last minute's: if this turn's record has not been read yet, the
    /// session's previous line would otherwise be announced as this turn's,
    /// and a bare "done" is better than a confident wrong one.
    private func latestSummaries(now: Date) -> [String: String] {
        var out: [String: (Date, String)] = [:]
        for event in completions?.events ?? []
        where !event.summary.isEmpty && now.timeIntervalSince(event.finishedAt) < 60 {
            if let seen = out[event.sessionId], seen.0 >= event.finishedAt { continue }
            out[event.sessionId] = (event.finishedAt, event.summary)
        }
        return out.mapValues(\.1)
    }

    // MARK: - Answering permission prompts

    /// askId → when the user answered it from the pet. Remembered so the row
    /// and the figure stop asking at once, instead of waiting for the next
    /// hook — which, for an approved ten-minute command, is ten minutes away.
    private var answered: [String: Date] = [:]

    /// A waiting session the pet should no longer show as waiting: answered
    /// from here, or approved in the terminal — see StateAggregator.wasApproved.
    private func isSettled(_ session: SessionState) -> Bool {
        (!session.askId.isEmpty && answered[session.askId] != nil)
            || StateAggregator.wasApproved(session)
    }

    /// Hands the answer to the pet-emit holding that prompt's hook open. It
    /// checks the askId, so an answer to a prompt that has since gone away
    /// approves nothing.
    private func answer(sessionID: String, askId: String, behavior: PermissionDecision.Behavior) {
        let now = Date()
        let file = PermissionDecision.fileURL(petHome: petHome, sessionId: sessionID)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? PermissionDecision.encode(PermissionDecision.Answer(askId: askId, behavior: behavior))
            .write(to: file, options: .atomic)) != nil else {
            bridge?.say("could not answer — use the terminal", hold: 5, variant: .warn)
            return
        }
        answered = answered.filter { now.timeIntervalSince($0.value) < 15 * 60 }
        answered[askId] = now
        render()
    }

    // MARK: - Labels

    private static let labelsKey = "sessionLabels"

    private func loadLabels() {
        labelPrefs = SessionLabels.decode(UserDefaults.standard.data(forKey: Self.labelsKey) ?? Data())
    }

    private func saveLabels() {
        let data = SessionLabels.encode(labelPrefs)
        guard !data.isEmpty else { return }
        UserDefaults.standard.set(data, forKey: Self.labelsKey)
    }

    /// cwd → branch, for the directories currently on screen.
    private func branches(for sessions: [SessionState]) -> [String: String] {
        var out: [String: String] = [:]
        for session in sessions where out[session.cwd] == nil {
            let branch = git.branch(for: session.cwd)
            if GitLabel.isWorthShowing(branch) { out[session.cwd] = branch }
        }
        return out
    }

    /// Right-clicking a row: the things that belong to THAT session rather than
    /// to the pet as a whole.
    private func showRowMenu(sessionID: String, at point: CGPoint) {
        guard
            !sessionID.isEmpty,
            let view = panel?.contentView,
            let session = latest.first(where: { $0.sessionId == sessionID })
        else { return }

        let menu = NSMenu()
        let current = labelPrefs[sessionID] ?? SessionLabels.Prefs()

        let rename = NSMenuItem(title: current.alias.isEmpty ? "Name This Session…" : "Rename…",
                                action: #selector(renamePicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = sessionID
        menu.addItem(rename)

        let pin = NSMenuItem(title: current.pinned ? "Unpin" : "Pin to Top",
                             action: #selector(pinPicked(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = sessionID
        menu.addItem(pin)

        menu.addItem(.separator())
        let mute = NSMenuItem(title: "Mute Until I Speak To It",
                              action: #selector(mutePicked(_:)), keyEquivalent: "")
        mute.target = self
        mute.representedObject = sessionID
        menu.addItem(mute)

        // The title line names what the menu is acting on: three rows from one
        // repo look identical, and acting on the wrong one is silent.
        let title = SessionLabels.displayName(for: session, prefs: labelPrefs,
                                              title: titleFor(session))
        menu.addItem(.separator())
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func titleFor(_ session: SessionState) -> String {
        guard let handle = session.terminal?.handle else { return "" }
        return bridge?.titles[handle] ?? ""
    }

    @objc private func renamePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let session = latest.first(where: { $0.sessionId == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Name this session"
        alert.informativeText = "Shown instead of the folder name and the tab title. "
            + "Leave it empty to go back to those."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = labelPrefs[id]?.alias ?? ""
        field.placeholderString = session.project
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // The ONE place the pet takes the keyboard, and only because the user
        // asked to type: a text field that cannot receive keystrokes is not a
        // text field. Everything the pet shows without being asked — the
        // connection report, the activity list, the bubble — leaves focus alone.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setPrefs(id) { $0.alias = SessionLabels.sanitiseAlias(field.stringValue) }
    }

    @objc private func pinPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setPrefs(id) { $0.pinned.toggle() }
    }

    @objc private func mutePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mute(sessionID: id)
    }

    private func setPrefs(_ id: String, _ change: (inout SessionLabels.Prefs) -> Void) {
        var prefs = labelPrefs[id] ?? SessionLabels.Prefs()
        change(&prefs)
        if prefs.isEmpty { labelPrefs.removeValue(forKey: id) } else { labelPrefs[id] = prefs }
        saveLabels()
        render()
    }

    /// Moments worth a brief reaction, as opposed to states worth a mood.
    ///
    /// Both are deliberately quiet. A turn ending means Claude stopped talking,
    /// not that the work was right; a failed tool call usually is not a failed
    /// task. Anything louder would be claiming something neither event says.
    private func noticeTransients(_ state: GlobalState, previous: GlobalState?) {
        guard !paused, let previous else { return }
        // Trouble outranks a finish: if both happened in one refresh, the thing
        // that went wrong is the one worth showing.
        let was = Dictionary(previous.sessions.map { ($0.sessionId, $0.troubleAt) },
                             uniquingKeysWith: { a, _ in a })
        let brokeJustNow = state.sessions.contains { session in
            guard let now = session.troubleAt else { return false }
            // A session appearing WITH trouble already recorded is not news —
            // that happens on the first render after launch.
            guard let before = was[session.sessionId] else { return false }
            return before != now
        }
        if brokeJustNow {
            bridge?.flash("trouble")
        } else if !Chatter.justFinished(previous: previous, current: state).isEmpty {
            bridge?.flash("done")
        }
    }

    // MARK: - Motion and visibility

    private var motionShownAt: Date?
    private var shownMotion: ActivitySummary.Motion?
    /// Tool calls come and go in well under a second. Without a floor the
    /// figure would switch poses several times a second, which reads as a
    /// glitch rather than as information.
    private static let motionFloor: TimeInterval = 1.5

    /// Which pose the figure should hold, given what is running.
    ///
    /// Nil outside `busy`: waiting and urgent have poses of their own, and idle
    /// is asleep.
    private func currentMotion(_ state: GlobalState, now: Date) -> ActivitySummary.Motion? {
        guard state.mood == .busy else {
            shownMotion = nil
            motionShownAt = nil
            return nil
        }
        // The longest-running call decides: with several in flight, the one
        // that has been going longest is the one the session is really on.
        let running = state.sessions.flatMap(\.running)
        // Nothing in flight means the session is thinking, not waiting on
        // something — the default pose (hands on the keys) is right for that.
        // Falling through to `.awaiting` here made every gap between tool calls
        // look like the pet had stopped working.
        guard let oldest = running.min(by: { ($0.since ?? now) < ($1.since ?? now) }) else {
            shownMotion = nil
            motionShownAt = nil
            return nil
        }
        let wanted = ActivitySummary.motion(forTool: oldest.tool)

        guard let shown = shownMotion, let since = motionShownAt else {
            shownMotion = wanted
            motionShownAt = now
            return wanted
        }
        if wanted != shown, now.timeIntervalSince(since) >= Self.motionFloor {
            shownMotion = wanted
            motionShownAt = now
            return wanted
        }
        return shown
    }

    /// How often the display is refreshed while it is on screen. The ages shown
    /// in the panel are coarse ("5m"), so a finer tick would redraw the same
    /// text.
    private static let tickInterval: TimeInterval = 5
    /// And while nothing can see it. Not stopped outright: the panel has to be
    /// current the moment it comes back, and a stopped clock would show the
    /// state from whenever it was covered up.
    private static let hiddenTickInterval: TimeInterval = 30
    private static let keepListOpenKey = "keepListOpen.v1"

    private func startTicker(interval: TimeInterval) {
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    /// Animation runs only when someone could be watching it AND has not asked
    /// the system for less motion.
    private func applyMotionSetting() {
        bridge?.setCalm(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !windowVisible)
    }

    /// Keep the session list up instead of opening it per glance.
    ///
    /// Pinning is a lock, not a default: while it is on, neither a click on the
    /// pet nor a jump to a terminal closes the list. Turning it back off is the
    /// only thing that does.
    private func toggleKeepListOpen() {
        keepListOpen.toggle()
        UserDefaults.standard.set(keepListOpen, forKey: Self.keepListOpenKey)
        bridge?.panelPinned = keepListOpen
        bridge?.setPanelOpen(keepListOpen)
    }

    // MARK: - Health and demo

    private var lastJumpFailure = ""
    private var healthWindow: HealthWindow?
    /// sessionId → what the statusline last told us. Empty when no statusline
    /// is wired up, which simply means the hover says less.
    private var insights: [String: SessionInsight] = [:]

    /// Read-only, and nothing here fixes anything.
    ///
    /// The install script already knows how to edit settings.json safely; a
    /// diagnostic that also repairs is a diagnostic that can turn a question
    /// into an outage.
    private func showHealth() {
        defer { mentionedProblem = nil }
        let checks = HealthCollector.run(petHome: petHome, sessions: latest,
                                         usage: currentUsage(),
                                         lastJumpFailure: lastJumpFailure)
        healthWindow?.close()
        let window = HealthWindow(checks: checks) {
            // The pasteable form, with the home directory collapsed.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HealthReport.summary(checks), forType: .string)
        }
        healthWindow = window
        window.show(near: panel?.frame ?? .zero)
    }

    /// The problem last mentioned at launch, so it is said once, not per launch
    /// of the menu.
    private var mentionedProblem: String?

    /// One line when the install is broken, because the menu item that reports
    /// it only appears on right-click and a pet that silently sees nothing
    /// looks exactly like a pet with nothing to show.
    private func mentionProblem() {
        guard let problem = HealthCollector.quickProblem(petHome: petHome),
              mentionedProblem != problem.name else { return }
        mentionedProblem = problem.name
        bridge?.say("\(problem.name): \(problem.detail) — right-click me for details",
                    hold: 12, emphasis: problem.name, variant: .warn)
    }

    private var demo: Timer?
    private var demoStep = 0

    /// Cycles the pet through its states without touching any real data.
    ///
    /// Writes nothing: no session files, no completion records, no read marks.
    /// A demo that leaves evidence behind is one the user has to clean up after.
    private func toggleDemo() {
        if let demo {
            demo.invalidate()
            self.demo = nil
            bridge?.setBadge("")
            bridge?.setPhase("")
            bridge?.hush()
            // Nothing the demo showed was written anywhere, so leaving it is
            // just a re-render of whatever is actually true.
            lastState = nil
            render()
            return
        }
        demoStep = 0
        advanceDemo()
        demo = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceDemo() }
        }
    }

    /// One step of the demo.
    ///
    /// Covers every distinct thing the pet can show, not just the four moods —
    /// the whole point of a demo is that the states nobody sees often are the
    /// ones worth showing on purpose.
    private struct DemoStep {
        let caption: String
        let mood: GlobalMood
        /// Which tool is notionally running, "" for none.
        let tool: String
        let project: String
        let waitingOn: String
        let phase: String
        /// A transient reaction to fire on arriving here.
        let flash: String
    }

    private static let demoSteps: [DemoStep] = [
        DemoStep(caption: "editing a file", mood: .busy, tool: "Edit",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: "reading around the code", mood: .busy, tool: "Read",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: "waiting on a command", mood: .busy, tool: "Bash",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: "a tool call was interrupted", mood: .busy, tool: "Bash",
                 project: "api-server", waitingOn: "", phase: "", flash: "trouble"),
        DemoStep(caption: "compacting its context", mood: .busy, tool: "",
                 project: "api-server", waitingOn: "", phase: "compacting", flash: ""),
        DemoStep(caption: "waiting on a background agent", mood: .busy, tool: "",
                 project: "api-server", waitingOn: "", phase: "awaiting-agent", flash: ""),
        DemoStep(caption: "asking to run something", mood: .waiting, tool: "",
                 project: "api-server", waitingOn: "rm -rf build/", phase: "", flash: ""),
        DemoStep(caption: "asking you a question", mood: .waiting, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: "ignored for a minute", mood: .urgent, tool: "",
                 project: "api-server", waitingOn: "rm -rf build/", phase: "", flash: ""),
        DemoStep(caption: "a turn just finished", mood: .idle, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: "done"),
        DemoStep(caption: "nothing to do", mood: .idle, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
    ]

    private func advanceDemo() {
        let now = Date()
        let step = Self.demoSteps[demoStep % Self.demoSteps.count]
        demoStep += 1

        let activity: SessionActivity
        switch step.mood {
        case .busy: activity = .busy
        case .idle: activity = .idle
        case .waiting, .urgent: activity = .waiting
        }
        let running = step.tool.isEmpty
            ? [] : [RunningTool(id: "d", tool: step.tool, target: "npm test", since: now)]
        let fake = SessionState(
            sessionId: "demo", project: step.project, cwd: "", state: activity,
            tool: step.tool, detail: "", since: now.addingTimeInterval(-90), updatedAt: now,
            running: running, phase: step.phase)

        bridge?.push(GlobalState(mood: step.mood, sessions: [fake],
                                 waitingProject: step.mood == .busy || step.mood == .idle
                                     ? nil : step.project,
                                 waitingOn: step.waitingOn),
                     motion: step.tool.isEmpty ? nil : ActivitySummary.motion(forTool: step.tool))
        bridge?.setPhase(step.phase)
        bridge?.pushSessions([fake], now: now)
        let badge = step.mood == .idle ? "" : "1"
        bridge?.setBadge(badge)
        // The demo is how anyone actually looks at the artwork, so it has to
        // drive the cat too. Without this the cat sat in one pose through all twelve
        // captions while the captions claimed otherwise.
        bridge?.setCatLook(CatSkin.look(mood: step.mood.rawValue, phase: step.phase,
                                        flash: "", wanted: !badge.isEmpty,
                                        blockedOn: step.waitingOn,
                                        motion: step.tool.isEmpty ? nil : ActivitySummary.motion(forTool: step.tool)))
        if !step.flash.isEmpty { bridge?.flash(step.flash) }
        // The caption says both what is being shown AND that it is not real.
        // A demo that looks like live state is a demo that gets acted on.
        bridge?.say("demo · \(step.caption)", hold: 0, emphasis: "demo")
    }

    // MARK: - Shortcut

    private static let hotKeyKey = "globalShortcutEnabled"

    private func toggleHotKey() {
        guard let hotKey else { return }
        if hotKey.isRegistered {
            hotKey.unregister()
            UserDefaults.standard.set(false, forKey: Self.hotKeyKey)
            return
        }
        // Only remember it as on if it actually took: another app may already
        // own the chord, and a menu tick that lies is worse than no feature.
        let ok = hotKey.register()
        UserDefaults.standard.set(ok, forKey: Self.hotKeyKey)
        if !ok {
            bridge?.say("\(HotKey.displayName) is taken by another app", hold: 5)
        }
    }

    /// Go to whatever has been waiting longest. Every outcome says what
    /// happened — a shortcut that does nothing visible is one the user stops
    /// trusting after the first silent press.
    private func jumpToNextWaiting() {
        let now = Date()
        let state = StateAggregator.aggregate(latest, now: now, hidden: hiddenMarks,
                                              snoozed: snoozeMarks, approved: isSettled)
        guard let target = PanelModel.jumpTarget(state.sessions, snoozed: snoozeMarks, now: now)
        else {
            bridge?.say("nothing is waiting on you", hold: 3)
            return
        }
        guard let terminal = target.terminal, TerminalTarget.canJump(kind: terminal.kind) else {
            bridge?.say("\(target.project) is waiting, but its terminal cannot be addressed",
                        hold: 5, emphasis: target.project)
            return
        }
        TerminalJump.jump(kind: terminal.kind, handle: terminal.handle)
    }

    /// Offers 5 / 15 / 30 minutes at the pointer.
    ///
    /// A menu rather than a fixed delay: "remind me later" without saying when
    /// is how an item quietly becomes an item nobody ever sees again.
    private func askSnooze(sessionID: String, at point: CGPoint) {
        guard !sessionID.isEmpty, let view = panel?.contentView else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Remind me in…", action: nil, keyEquivalent: "").isEnabled = false
        for minutes in Snooze.options {
            let item = NSMenuItem(title: "\(minutes) minutes",
                                  action: #selector(snoozePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [sessionID, minutes] as [Any]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func snoozePicked(_ sender: NSMenuItem) {
        guard
            let pair = sender.representedObject as? [Any],
            let id = pair.first as? String,
            let minutes = pair.last as? Int
        else { return }
        snooze(sessionID: id, minutes: minutes)
    }

    /// Re-reads what the statusline has captured, if anything.
    ///
    /// Cheap and infrequent: one small file per session, and only when the
    /// directory has changed.
    private var insightStamp: Date?
    private func loadInsights() {
        let folder = SessionInsights.directory(petHome: petHome)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
        guard stamp != insightStamp else { return }
        insightStamp = stamp
        var loaded: [String: SessionInsight] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let insight = SessionInsights.decode(data) {
                loaded[insight.sessionId] = insight
            }
        }
        insights = loaded
    }

    /// The lines to show while the pointer rests on a row.
    ///
    /// Replaced showing the session's name, which stopped being worth a hover
    /// once the first column started showing it.
    private func hoverDetail(for sessionID: String) -> SessionDetail.Detail? {
        guard let session = latest.first(where: { $0.sessionId == sessionID }) else { return nil }
        let file = petHome.appending(path: "activity")
            .appending(path: sessionID).appendingPathExtension("jsonl")
        let recent = ActivityLog.recent(
            ActivityLog.decode((try? String(contentsOf: file, encoding: .utf8)) ?? ""),
            now: Date(), limit: 1).first
        return SessionDetail.detail(session: session, insight: insights[sessionID],
                                    lastActivity: recent, now: Date())
    }

    /// Acknowledging finishes. Re-rendering immediately is what makes the badge
    /// and the list agree without waiting for the next tick.
    /// A click on a finish notice: the same as clicking that session's row in
    /// Finished. Go there and call its finishes read; with nowhere to go, open
    /// the list, which is where the row is.
    private func openNotice(sessionID: String) {
        bridge?.dismissNotice(sessionID)
        guard let terminal = latest.first(where: { $0.sessionId == sessionID })?.terminal,
              TerminalTarget.canJump(kind: terminal.kind) else {
            bridge?.setPanelOpen(true)
            return
        }
        TerminalJump.jump(kind: terminal.kind, handle: terminal.handle)
        markRead((completions?.unread ?? []).filter { $0.sessionId == sessionID }.map(\.eventId))
    }

    private func markRead(_ ids: [String]) {
        completions?.markRead(ids)
        render()
    }

    private func markAllRead() {
        completions?.markAllRead()
        render()
    }

    /// sessionId → the terminal tab title, for the sessions we have one for.
    /// Falls back to the project name inside Chatter when a session has none.
    private func sessionNames(_ state: GlobalState) -> [String: String] {
        guard let titles = bridge?.titles, !titles.isEmpty else { return [:] }
        var names: [String: String] = [:]
        for session in state.sessions {
            guard let handle = session.terminal?.handle,
                  let title = titles[handle],
                  !TerminalTitles.isUseless(title)
            else { continue }
            names[session.sessionId] = title
        }
        return names
    }

    /// Resting the pointer shows something without being asked twice: the quota
    /// when hovering the pet itself, the session's name when hovering a row.
    /// Neither is rate-limited — the user pointed at it.
    private func updateDwell(at point: CGPoint, panelOpen: Bool) {
        // No panel rect needed: with the list open, anything that is not the pet
        // is a candidate row, and the page answers "" for points that are not on
        // one.
        let onPet = PetLayout.isOnPet(point,
                                      mirrored: panel?.isMirrored ?? false)
        let target: DwellTarget? = {
            if panelOpen, !onPet { return .row(point) }
            if !panelOpen, onPet { return .pet }
            return nil
        }()

        guard let target else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            if dwellShowing {
                dwellShowing = false
                bridge?.hush()
            }
            return
        }

        // Moving between rows has to restart the timer, or the first row's name
        // would stay up while the pointer sits on a different one.
        if case .row(let p) = target, case .row(let previous)? = dwellTarget,
           abs(p.y - previous.y) > 2 {
            dwellTimer?.invalidate()
            dwellTimer = nil
            if dwellShowing {
                dwellShowing = false
                bridge?.hush()
            }
        }
        dwellTarget = target

        guard dwellTimer == nil, !dwellShowing else { return }
        let delay = target.isRow ? Self.rowDwellDelay : Self.dwellDelay
        dwellTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwellTimer = nil
                switch target {
                case .pet:
                    guard let state = self.lastState else { return }
                    self.dwellShowing = true
                    // Stays up until the pointer leaves.
                    let now = Date()
                    self.bridge?.showQuota(
                        rows: Chatter.quotaRows(usage: self.currentUsage(), now: now),
                        fallback: Chatter.fallbackLine(state: state)
                    )
                case .row(let p):
                    // The page reports WHICH row; the detail is assembled here,
                    // because it needs the activity log and the statusline
                    // capture, neither of which the page has.
                    self.bridge?.rowSessionId(at: p) { [weak self] id in
                        guard let self, !id.isEmpty else { return }
                        guard let detail = self.hoverDetail(for: id), !detail.isEmpty
                        else { return }
                        self.dwellShowing = true
                        self.bridge?.showDetail(detail)
                    }
                }
            }
        }
    }

    private enum DwellTarget {
        case pet
        case row(CGPoint)

        var isRow: Bool { if case .row = self { return true }; return false }
    }

    /// A pinned list never gets opened, so it never gets the fetch that opening
    /// one performs — and a session started after launch would show its
    /// directory name for as long as it lived. This puts that fetch back on the
    /// only other honest trigger there is: the set of live sessions changing.
    private func refreshTitlesIfPinned(for sessions: [SessionState], now: Date) {
        let ids = Set(sessions.map(\.sessionId))
        guard PanelModel.shouldRefreshTitles(pinned: keepListOpen, currentIds: ids,
                                             refreshedIds: titlesRefreshedIds,
                                             lastRefresh: lastTitleRefresh, now: now)
        else { return }
        // Recorded before the fetch returns, so a slow subprocess cannot let the
        // next tick start a second one.
        titlesRefreshedIds = ids
        lastTitleRefresh = now
        refreshTitles()
    }

    private func refreshTitles() {
        TerminalJump.fetchTitles { [weak self] titles in
            guard let self, !titles.isEmpty else { return }
            self.bridge?.titles = titles
            // The payload now carries names, so the dedup guard lets it through.
            self.render()
        }
    }

    // MARK: - Muted sessions

    private static let hiddenKey = "hiddenSessions.v1"

    /// sessionId → the session's own lastPromptAt when it was muted. Persisted so
    /// muting survives a restart of the pet; see HiddenSessions for why the mark
    /// is a prompt time rather than the moment of muting.
    private var hiddenMarks: [String: Date] = [:]

    private func loadHidden() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.hiddenKey) ?? [:]
        hiddenMarks = raw.compactMapValues { $0 as? Date }
    }

    private func saveHidden() {
        UserDefaults.standard.set(hiddenMarks, forKey: Self.hiddenKey)
    }

    // MARK: - Snooze

    private static let snoozeKey = "snoozedSessions"
    private var snoozeMarks: [String: Snooze.Mark] = [:]

    private func loadSnoozed() {
        let data = UserDefaults.standard.data(forKey: Self.snoozeKey) ?? Data()
        snoozeMarks = Snooze.decode(data)
    }

    private func saveSnoozed() {
        let data = Snooze.encode(snoozeMarks)
        guard !data.isEmpty else { return }
        UserDefaults.standard.set(data, forKey: Self.snoozeKey)
    }

    /// Postpone this session's current wait. Postponing again replaces the
    /// previous delay rather than adding to it.
    private func snooze(sessionID: String, minutes: Int) {
        guard let session = latest.first(where: { $0.sessionId == sessionID }) else { return }
        snoozeMarks[sessionID] = Snooze.mark(for: session, minutes: minutes, now: Date())
        saveSnoozed()
        render()
    }

    private func mute(sessionID: String) {
        guard let session = latest.first(where: { $0.sessionId == sessionID }) else { return }
        hiddenMarks[sessionID] = HiddenSessions.mark(for: session)
        saveHidden()
        render()
    }

    private func unmuteAll() {
        guard !hiddenMarks.isEmpty else { return }
        hiddenMarks = [:]
        saveHidden()
        render()
    }

    /// Called whenever the session list changes, so marks for sessions that have
    /// exited do not accumulate forever.
    private func pruneHidden() {
        let kept = HiddenSessions.pruned(hiddenMarks, keeping: latest)
        guard kept.count != hiddenMarks.count else { return }
        hiddenMarks = kept
        saveHidden()
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/local.claudepet.plist")
    }

    /// The filesystem is the source of truth for whether the LaunchAgent is
    /// installed. Never cache this in UserDefaults: a write that silently
    /// failed, or an uninstall that removed the plist out from under us,
    /// would otherwise leave the menu checkmark lying about actual state.
    private var launchesAtLogin: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func toggleLaunchAtLogin() {
        let url = launchAgentURL
        let enable = !launchesAtLogin

        do {
            if enable {
                let appPath = Bundle.main.bundlePath
                let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>local.claudepet</string>
                  <key>ProgramArguments</key>
                  <array><string>/usr/bin/open</string><string>\(appPath)</string></array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try plist.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // Leave the filesystem exactly as it is on failure. We deliberately
            // do not cache an "enabled" flag anywhere: the next menu render
            // re-reads launchesAtLogin from disk, so a failed write shows up
            // as still-disabled instead of a false checkmark. Without this log
            // a failed toggle is indistinguishable from "the click did nothing".
            NSLog("ClaudePet: launch-at-login toggle (enable=\(enable)) failed: \(error.localizedDescription)")
        }
    }
}
