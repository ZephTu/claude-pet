import AppKit
import ClaudePetCore

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
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
    /// The user's own preference, independent of whether the window happens to
    /// be visible right now.
    private var reduceMotion = false
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
            self?.render()
        }
        panel.onMirrorChanged = { on in bridge.setMirrored(on) }
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
        reduceMotion = UserDefaults.standard.bool(forKey: Self.reduceMotionKey)
        panel.onClick = { point in bridge.handleClick(at: point) }
        panel.onHover = { [weak self] point, panelOpen in
            if panelOpen { bridge.setHover(at: point) }
            self?.updateDwell(at: point, panelOpen: panelOpen)
        }
        bridge.onMute = { [weak self] id in self?.mute(sessionID: id) }
        // Titles cost a subprocess, so they are fetched when the user opens the
        // list — never on a timer for a panel nobody has looked at.
        bridge.onPanelOpened = { [weak self] in self?.refreshTitles() }
        loadHidden()
        loadSnoozed()
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
            onDemoToggle: { [weak self] in self?.toggleDemo() },
            onReduceMotionToggle: { [weak self] in self?.toggleReduceMotion() },
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
                          demoOn: self.demo != nil,
                          reduceMotionOn: self.reduceMotion)
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
                                        snoozed: snoozeMarks)
        // The hit region is a pair of fixed rectangles now (PetLayout.bodyBox /
        // antennaBox), so the window no longer needs telling about mood.
        // Expiry is judged against `now` rather than by a timer, so sleeping
        // through a delay is a no-op instead of a burst of catch-up reminders.
        let survivingMarks = Snooze.pruned(snoozeMarks, keeping: state.sessions, now: now)
        if survivingMarks.count != snoozeMarks.count {
            snoozeMarks = survivingMarks
            saveSnoozed()
        }
        completions?.reload(now: now)
        let unread = paused ? [] : (completions?.unread ?? [])
        bridge?.push(state, motion: currentMotion(state, now: now))
        bridge?.pushSessions(state.sessions, now: now, hiddenCount: state.hiddenCount,
                             completions: unread, titlesByHandle: bridge?.titles ?? [:],
                             droppedNotice: completions?.takeDropNotice() ?? 0,
                             snoozed: snoozeMarks, prefs: labelPrefs,
                             branches: branches(for: state.sessions))
        // One number for "how many things want me": sessions blocked on the user,
        // plus finished turns they have not looked at.
        // A postponed item does not count toward the badge: the user said "not
        // now", and a number that keeps standing there is still nagging.
        bridge?.setBadge(PanelModel.badge(
            needsYou: PanelModel.needsYou(state.sessions)
                .filter { !Snooze.isSnoozed($0, marks: snoozeMarks, now: now) }.count,
            unreadFinishes: PanelModel.completionRows(unread, live: state.sessions).count))
        // A "done" line has no timer, so something has to retire it. Going back
        // to work is that something: once a session is busy again, the user has
        // plainly seen the news or stopped caring about it.
        if stickyBubble, let previous = lastState,
           !Chatter.justStarted(previous: previous, current: state).isEmpty {
            bridge?.hush()
            stickyBubble = false
        }
        maybeSpeak(state: state, now: now)
        lastState = state
    }

    // MARK: - Talking

    /// How long a line stays up before it takes itself away. Sticky lines
    /// (see `Chatter.isSticky`) ignore this and wait to be replaced instead.
    private static let speechHold: TimeInterval = 6
    /// True while the bubble holds a line with no timer of its own.
    private var stickyBubble = false
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

    private func maybeSpeak(state: GlobalState, now: Date) {
        // Paused means the pet is asleep, and a sleeping robot with a speech
        // bubble is just wrong. It also never sees real transitions while
        // paused, since render() substitutes a fixed idle state.
        guard !paused, !dwellShowing else { return }
        guard let line = Chatter.next(
            state: state, previous: lastState, usage: currentUsage(), now: now,
            lastSpoken: lastSpoken, lastAnything: lastAnything, names: sessionNames(state)
        ) else { return }
        let sticky = Chatter.isSticky(line.kind)
        bridge?.say(line.text, hold: sticky ? 0 : Self.speechHold, emphasis: line.emphasis)
        stickyBubble = sticky
        lastSpoken[line.kind] = now
        lastAnything = now
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

        if !current.alias.isEmpty {
            let clear = NSMenuItem(title: "Clear Name", action: #selector(clearNamePicked(_:)),
                                   keyEquivalent: "")
            clear.target = self
            clear.representedObject = sessionID
            menu.addItem(clear)
        }

        let pin = NSMenuItem(title: current.pinned ? "Unpin" : "Pin to Top",
                             action: #selector(pinPicked(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = sessionID
        menu.addItem(pin)

        let recent = NSMenuItem(title: "Recent Activity…", action: #selector(activityPicked(_:)),
                                keyEquivalent: "")
        recent.target = self
        recent.representedObject = sessionID
        menu.addItem(recent)

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
        alert.informativeText = "Shown instead of the folder name and the tab title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = labelPrefs[id]?.alias ?? ""
        field.placeholderString = session.project
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // The panel is a non-activating window, so the alert needs the app
        // brought forward or it opens behind whatever has focus.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setPrefs(id) { $0.alias = SessionLabels.sanitiseAlias(field.stringValue) }
    }

    @objc private func clearNamePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setPrefs(id) { $0.alias = "" }
    }

    @objc private func pinPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setPrefs(id) { $0.pinned.toggle() }
    }

    /// What this session's tools have been doing.
    ///
    /// Read from the log pet-emit appends to, never from the transcript: the
    /// pet does not read conversations, and this has to keep being true.
    @objc private func activityPicked(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let session = latest.first(where: { $0.sessionId == id })
        else { return }
        let file = petHome.appending(path: "activity")
            .appending(path: SessionLabels.sanitiseAlias(id).isEmpty ? id : id)
            .appendingPathExtension("jsonl")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let entries = ActivityLog.recent(ActivityLog.decode(text), now: Date())

        let alert = NSAlert()
        alert.messageText = SessionLabels.displayName(for: session, prefs: labelPrefs,
                                                      title: titleFor(session))
        alert.informativeText = entries.isEmpty
            ? "No tool calls recorded yet. Only calls made after the pet was installed are logged."
            : entries.map { "· " + $0.line() }.joined(separator: "\n")
        alert.addButton(withTitle: "Close")
        if !entries.isEmpty { alert.addButton(withTitle: "Clear History") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            try? FileManager.default.removeItem(at: file)
        }
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
        let oldest = running.min { ($0.since ?? now) < ($1.since ?? now) }
        let wanted = oldest.map { ActivitySummary.motion(forTool: $0.tool) } ?? .awaiting

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
    private static let reduceMotionKey = "reduceMotion"

    private func startTicker(interval: TimeInterval) {
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    /// Animation runs only when someone could be watching it AND has not asked
    /// for it to stop.
    private func applyMotionSetting() {
        bridge?.setCalm(reduceMotion || !windowVisible)
    }

    private func toggleReduceMotion() {
        reduceMotion.toggle()
        UserDefaults.standard.set(reduceMotion, forKey: Self.reduceMotionKey)
        applyMotionSetting()
    }

    // MARK: - Health and demo

    private var lastJumpFailure = ""

    /// Read-only, and nothing here fixes anything.
    ///
    /// The install script already knows how to edit settings.json safely; a
    /// diagnostic that also repairs is a diagnostic that can turn a question
    /// into an outage.
    private func showHealth() {
        let checks = HealthCollector.run(petHome: petHome, sessions: latest,
                                         usage: currentUsage(),
                                         lastJumpFailure: lastJumpFailure)
        let alert = NSAlert()
        alert.messageText = "Connection status"
        alert.informativeText = checks
            .map { "\($0.status.label) — \($0.name)\n    \($0.detail)" }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The pasteable form, with the home directory collapsed.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HealthReport.summary(checks), forType: .string)
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
            bridge?.hush()
            render()
            return
        }
        demoStep = 0
        advanceDemo()
        demo = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceDemo() }
        }
    }

    private func advanceDemo() {
        let now = Date()
        let steps: [(GlobalMood, String, String)] = [
            (.busy, "", ""),
            (.waiting, "api-server", "Edit AppMain.swift"),
            (.urgent, "api-server", "rm -rf build/"),
            (.idle, "", ""),
        ]
        let (mood, project, on) = steps[demoStep % steps.count]
        demoStep += 1

        let fake = SessionState(
            sessionId: "demo", project: project.isEmpty ? "demo-project" : project,
            cwd: "", state: mood == .busy ? .busy : (mood == .idle ? .idle : .waiting),
            tool: "Bash", detail: "", since: now.addingTimeInterval(-90), updatedAt: now,
            running: mood == .busy
                ? [RunningTool(id: "d", tool: "Bash", target: "npm test", since: now)] : [])
        bridge?.push(GlobalState(mood: mood, sessions: [fake],
                                 waitingProject: project.isEmpty ? nil : project,
                                 waitingOn: on))
        bridge?.pushSessions([fake], now: now)
        bridge?.setBadge(mood == .idle ? "" : "1")
        bridge?.say("demo — the pet is not watching anything right now", hold: 2.2)
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
                                              snoozed: snoozeMarks)
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

    /// Acknowledging finishes. Re-rendering immediately is what makes the badge
    /// and the list agree without waiting for the next tick.
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
        let target: DwellTarget? = {
            if panelOpen, !PetLayout.bodyBox.contains(point) { return .row(point) }
            if !panelOpen, PetLayout.bodyBox.contains(point) { return .pet }
            return nil
        }()

        guard let target else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            if dwellShowing {
                dwellShowing = false
                stickyBubble = false
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
                stickyBubble = false
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
                    self.bridge?.rowTitle(at: p) { [weak self] title in
                        guard let self, !title.isEmpty else { return }
                        self.dwellShowing = true
                        self.bridge?.say(title, hold: 0)
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
