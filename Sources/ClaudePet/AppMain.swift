import AppKit
import ClaudePetCore

@main
struct AppMain {
    static func main() {
        // Opened from a terminal, the pet inherits that tab's variables, and so would every
        // session it starts: the board would type messages for them into that tab, or into
        // nothing once it is closed (TerminalTarget.inheritedTerminalKeys).
        for key in TerminalTarget.inheritedTerminalKeys(ProcessInfo.processInfo.environment) { unsetenv(key) }
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
        // What the pet reads from HQ, printed — a development check for TaskIndex.
        if arguments.contains("--hq-snapshot") {
            MainActor.assumeIsolated {
                let s = TaskIndex().snapshot()
                print("installed=\(s.installed) asks=\(s.openAsks.map { "\($0.id):\($0.text.prefix(30))" })")
                print("focus=\(s.focusToday) carry=\(s.carry)")
                for (sid, task) in s.taskBySession.sorted(by: { $0.key < $1.key }) { print("\(sid.prefix(8)) → \(task)") }
            }
            exit(0)
        }
        // The HQ board with live data, as a PNG: `--render-board out.png [js] [--size WxH]`
        // (--size 390x844: the board as a phone shows it).
        if let i = arguments.firstIndex(of: "--render-board"), i + 1 < arguments.count {
            app.setActivationPolicy(.prohibited)
            var rest = Array(arguments[(i + 2)...])
            var size: NSSize?
            if let s = rest.firstIndex(of: "--size"), s + 1 < rest.count {
                let wh = rest[s + 1].split(separator: "x").compactMap { Double($0) }
                if wh.count == 2 { size = NSSize(width: wh[0], height: wh[1]) }
                rest.removeSubrange(s...(s + 1))
            }
            let script = rest.first ?? ""
            MainActor.assumeIsolated {
                // Phone access as the app has it (a development copy: set its own boardServerPort).
                BoardServer.shared.startIfEnabled()
                let window = BoardWindow()
                if let size { window.setContentSize(size) }
                window.renderPreview(to: arguments[i + 1], script: script) { exit($0 ? 0 : 1) }
                _ = Unmanaged.passRetained(window)
            }
            app.run()
        }
        // The board served to phones, alone: `--serve-board PORT` prints a pairing link.
        if let i = arguments.firstIndex(of: "--serve-board"), i + 1 < arguments.count, let port = UInt16(arguments[i + 1]) {
            app.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { BoardServer.shared.serveForDevelopment(port: port) }
            app.run()
        }
        // A page as a phone's browser shows it (no app behind it but its server), as a PNG:
        // `--render-url URL out.png [js] [--size WxH]` — the board from `--serve-board`.
        if let i = arguments.firstIndex(of: "--render-url"), i + 2 < arguments.count {
            app.setActivationPolicy(.prohibited)
            var rest = Array(arguments[(i + 3)...])
            var size = NSSize(width: 390, height: 844)
            if let s = rest.firstIndex(of: "--size"), s + 1 < rest.count {
                let wh = rest[s + 1].split(separator: "x").compactMap { Double($0) }
                if wh.count == 2 { size = NSSize(width: wh[0], height: wh[1]) }
                rest.removeSubrange(s...(s + 1))
            }
            MainActor.assumeIsolated {
                PageShot.render(url: arguments[i + 1], to: arguments[i + 2], script: rest.first ?? "", size: size) { exit($0 ? 0 : 1) }
            }
            app.run()
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
        // Only a launch that means the pet starts one: anything else prints the usage, and a
        // second pet beside a running one exits (PetLaunch says why).
        switch PetLaunch.decide(arguments) {
        case .start: break
        case .help:
            print(PetLaunch.usage)
            exit(0)
        case .unknown(let args):
            FileHandle.standardError.write(Data("unknown argument: \(args.joined(separator: " "))\n\(PetLaunch.usage)\n".utf8))
            exit(2)
        }
        let lock = PetLaunch.lockURL(petHome: Jobs.petHome)
        guard PetLaunch.acquireLock(at: lock, wait: 5) != nil else {
            let pid = PetLaunch.holder(at: lock).map { " (pid \($0))" } ?? ""
            FileHandle.standardError.write(Data("Claude Pet is already running\(pid)\n".utf8))
            exit(0)
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
    private var noteHotKey: HotKey?
    private let quickNote = QuickNotePanel()
    private let git = GitCache()
    private let transcripts = TranscriptCache()
    /// sessionId → turns and context, from the last render.
    private var transcriptStats: [String: TranscriptStats.Progress] = [:]
    /// sessionId → its context against its auto-compact window, from the last render.
    private var contextReadings: [String: ContextBudget.Reading] = [:]
    /// The auto-compact windows from ~/.claude/settings.json, re-read when it changes.
    private var budgetSettings = ContextBudget.Settings()
    private var budgetSettingsStamp: Date?
    /// Which sessions crossed into "long" and are owed a word — see ContextAlarm.
    private var contextAlarm = ContextAlarm()
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
            bridge.setMaxNotices(self?.noticeCount ?? Chatter.noticeCount)
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
            NSLog("ClaudePet: the pet could not animate, showing stills: \(why)")
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
        noticeHold = Chatter.noticeHold(stored: UserDefaults.standard.double(forKey: Self.noticeHoldKey))
        noticeCount = Chatter.noticeCount(stored: UserDefaults.standard.integer(forKey: Self.noticeCountKey))
        bridge.panelPinned = keepListOpen
        panel.onClick = { point in bridge.handleClick(at: point) }
        panel.onDoubleClick = { bridge.handleDoubleClick() }
        bridge.onDoubleClickPet = { [weak self] in self?.toggleBoard() }
        bridge.onOpenBoardAt = { [weak self] task in self?.showBoard(reveal: task) }
        bridge.onOpenSession = { [weak self] sid, kind, handle, source in
            self?.openSession(sid, kind: kind, handle: handle, source: source) ?? .nowhere
        }
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
        watchUsage()
        loadLabels()
        git.onUpdate = { [weak self] in self?.render() }
        transcripts.onUpdate = { [weak self] in self?.render() }
        bridge.onRowMenu = { [weak self] id, point in self?.showRowMenu(sessionID: id, at: point) }
        // Off unless the user asked for it: claiming a system-wide chord
        // uninvited is taking something that was not offered.
        let hotKey = HotKey { [weak self] in self?.jumpToNextWaiting() }
        self.hotKey = hotKey
        if UserDefaults.standard.bool(forKey: Self.hotKeyKey) { hotKey.register() }
        let noteHotKey = HotKey(keyCode: HotKey.noteKeyCode, name: HotKey.noteDisplayName) { [weak self] in self?.showQuickNote() }
        self.noteHotKey = noteHotKey
        if UserDefaults.standard.bool(forKey: Self.noteHotKeyKey) { noteHotKey.register() }
        quickNote.onSubmit = { [weak self] text, images in self?.fileQuickNote(text, images: images) }
        bridge.onSnooze = { [weak self] id, point in self?.askSnooze(sessionID: id, at: point) }
        let completions = CompletionStore(petHome: petHome)
        completions.reload(now: Date(), force: true)
        self.completions = completions
        bridge.onMarkRead = { [weak self] ids in self?.markRead(ids) }
        // The board shares the "finished, not looked at" marks: it shows them on its session rows,
        // and opening a conversation, jumping to it or replying from the board reads them.
        BoardBridge.unreadBySession = { [weak self] in
            Dictionary(grouping: CompletionQueue.shown(self?.completions?.unread ?? [],
                                                       sessions: self?.lastState?.sessions ?? []),
                       by: \.sessionId).mapValues(\.count)
        }
        BoardBridge.onSeen = { [weak self] sid in self?.markSessionRead(sid) }
        BoardBridge.petDots = { [weak self] in self?.bridge?.dotState ?? [:] }
        BoardBridge.onPeek = { [weak self] sid in self?.peekedAt[sid] = Date() }
        BoardBridge.clickTarget = { [weak self] in self?.clickTarget.rawValue ?? "" }
        BoardBridge.onClickTarget = { [weak self] raw in self?.setClickTarget(ClickTarget(stored: raw)) }
        TerminalJump.record = { [weak self] origin, kind in self?.recordJump(origin, kind: kind) }
        BoardBridge.onDecide = { [weak self] id, ask, behavior in
            self?.answer(sessionID: id, askId: ask, behavior: behavior)
        }
        BoardBridge.onReply = { [weak self] id, reply in
            self?.answer(sessionID: id, reply: reply)
        }
        // The board shows the same quota reading the pet does — one pick from the same sources.
        BoardBridge.usage = { [weak self] in
            guard let u = self?.currentUsage(), u.percentagesUsable(now: Date()) else { return nil }
            let iso = ISO8601DateFormatter()
            return ["five_hour": ["used": u.fiveHourPercent, "resets_at": iso.string(from: u.fiveHourResetAt)],
                    "seven_day": ["used": u.sevenDayPercent, "resets_at": iso.string(from: u.sevenDayResetAt)],
                    "source": u.source]
        }
        bridge.onMarkAllRead = { [weak self] in self?.markAllRead() }
        // Phone access to the board, if it was left on (Settings → Phone access).
        BoardServer.shared.startIfEnabled()
        panel.showOnDesktop()
        panel.updateLayoutSide()
        // A saved spot can be on a display that is no longer attached, or one
        // that has since shrunk.
        panel.rescueIfOffScreen()

        let menu = PetMenu(
            onPauseToggle: { [weak self] in
                guard let self else { return }
                paused.toggle()
                // What crossed while paused is not news afterwards: start the
                // context reminders from what is on screen now.
                contextAlarm = ContextAlarm()
                render()
            },
            onLoginToggle: { [weak self] in self?.toggleLaunchAtLogin() },
            onUnmuteAll: { [weak self] in self?.unmuteAll() },
            onShortcutToggle: { [weak self] in self?.toggleHotKey() },
            onShowHealth: { [weak self] in self?.showHealth() },
            onKeepListOpenToggle: { [weak self] in self?.toggleKeepListOpen() },
            onNoticeHold: { [weak self] seconds in
                self?.noticeHold = seconds
                UserDefaults.standard.set(seconds, forKey: Self.noticeHoldKey)
            },
            onNoticeCount: { [weak self] n in
                self?.noticeCount = n
                UserDefaults.standard.set(n, forKey: Self.noticeCountKey)
                self?.bridge?.setMaxNotices(n)
            },
            onQuit: { NSApp.terminate(nil) },
            onShowBoard: { [weak self] in self?.showBoard() },
            onSkin: { [weak panel] id in panel?.setSkin(id) },
            onLanguage: { [weak self] id in self?.setLanguage(id) },
            onQuickNote: { [weak self] in self?.showQuickNote() },
            onNoteShortcutToggle: { [weak self] in self?.toggleNoteHotKey() },
            onClickTarget: { [weak self] target in self?.setClickTarget(target) }
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
                          noteShortcutOn: self.noteHotKey?.isRegistered ?? false,
                          keepListOpenOn: self.keepListOpen,
                          clickTarget: self.clickTarget,
                          problem: HealthCollector.quickProblem(petHome: self.petHome),
                          noticeHold: self.noticeHold, noticeCount: self.noticeCount,
                          skin: panel?.skin ?? PetSkins.defaultID,
                          canShowSkin: { panel?.canShow(skin: $0) ?? false },
                          language: UILanguage.stored)
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

        // Scheduled jobs run under launchd, not here; make sure their agents match the jobs
        // (an upgrade may have moved the runner), and redraw when the board marks failures seen.
        JobsController.shared.onChange = { [weak self] in self?.render() }
        Task { await JobsController.shared.syncAgents() }

        self.panel = panel
        self.bridge = bridge
        self.watcher = watcher
    }

    /// The Dock icon (there only while the board is open — see BoardWindow)
    /// brings the board forward, even when it is minimised. Relaunching the
    /// app while the board is closed (Finder, `open`, an install) does nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.activationPolicy() == .regular, boardWindow != nil { showBoard() }
        return false
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
        // You typed into a session after it finished: you saw what it said.
        if let c = completions {
            let replied = CompletionQueue.answered(c.unread, sessions: state.sessions)
            if !replied.isEmpty { c.markRead(replied) }
        }
        // What finish detection reads: a turn's end counts once it has held — see
        // StateAggregator.settled. Everything that says "it finished" takes this
        // one — the bubble, the Finished list, the badge — and lastState keeps it,
        // so each pair compared is of the same kind.
        let settled = StateAggregator.settled(state, previous: lastState, now: now)
        let unread = paused ? [] : CompletionQueue.shown(completions?.unread ?? [],
                                                         sessions: settled.sessions)
        let hq = taskIndex.snapshot(now: now)
        let jobs = paused ? JobsController.Report() : JobsController.shared.poll(now: now)
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
        noticeTransients(settled, previous: lastState)
        backgroundShells = findBackgroundShells(state.sessions)
        transcriptStats = transcripts.stats(for: state.sessions)
        contextReadings = readContext(for: state.sessions, now: now)
        if !paused { contextAlarm.observe(contextReadings) }
        bridge?.pushSessions(state.sessions, now: now, hiddenCount: state.hiddenCount,
                             background: backgroundShells,
                             completions: unread, titlesByHandle: bridge?.titles ?? [:],
                             droppedNotice: completions?.takeDropNotice() ?? 0,
                             snoozed: snoozeMarks, prefs: labelPrefs,
                             branches: branches(for: state.sessions),
                             turns: transcriptStats.compactMapValues { $0.turns > 0 ? $0.turns : nil },
                             context: contextReadings,
                             tasks: hq.taskBySession, taskStatus: hq.statusBySession,
                             clickTarget: clickTarget,
                             hqAsks: paused ? [] : hq.openAsks.map {
                                 ["id": $0.id, "task": $0.task, "text": $0.text,
                                  "status": hq.statusByTask[$0.task] ?? ""]
                             },
                             jobs: jobs.rows)
        // One number for "how many things want me": sessions blocked on the user,
        // plus finished turns they have not looked at.
        // A postponed item does not count toward the badge: the user said "not
        // now", and a number that keeps standing there is still nagging.
        let badge = PanelModel.badge(
            needsYou: PanelModel.needsYou(state.sessions)
                .filter { !Snooze.isSnoozed($0, marks: snoozeMarks, now: now) }.count
                + (paused ? 0 : hq.openAsks.count)    // questions on the HQ board want an answer too
                + jobs.unseenFailures,                 // and a scheduled job that failed wants a look
            unreadFinishes: PanelModel.completionRows(unread, live: state.sessions).count)
        bridge?.setBadge(badge)
        // What the cat shows is decided here and pushed — see CatSkin.
        bridge?.setCatLook(CatSkin.look(mood: state.mood.rawValue,
                                        phase: StateAggregator.phase(state.sessions),
                                        flash: "",
                                        wanted: !badge.isEmpty,
                                        blockedOn: state.waitingOn, motion: motion,
                                        struggling: state.sessions.contains(where: Struggle.isStruggling)))
        announceFinishes(settled, now: now)
        for n in jobs.notices {
            bridge?.notify(n.text, hold: 25, emphasis: n.emphasis, sessionId: "job:" + n.jobId, jumpable: false)
        }
        // (No daily "pick today's tasks" prompt any more: Focus stays until you change it.)
        if !paused { announceAsks(hq) }
        noticeReturn(state, now: now)
        maybeSpeak(state: settled, now: now)
        lastState = settled
    }

    /// sessionId → commands it left running after its turn ended. Refreshed
    /// every render, so a command that exits drops off within one tick.
    private var backgroundShells: [String: [BackgroundShells.Shell]] = [:]

    /// Only idle sessions: while a turn runs, its own foreground Bash call is a
    /// shell of exactly the same shape and would be counted as background.
    private func findBackgroundShells(_ sessions: [SessionState]) -> [String: [BackgroundShells.Shell]] {
        var out: [String: [BackgroundShells.Shell]] = [:]
        for session in sessions where session.state == .idle {
            guard let pid = session.pid else { continue }
            let shells = BackgroundShells.running(under: pid)
            if !shells.isEmpty { out[session.sessionId] = shells }
        }
        return out
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
    /// `noticeHold` — see window.notify for the stack they sit in.
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
            bridge?.notify(notice.text, hold: noticeHold, emphasis: notice.emphasis,
                           sessionId: notice.sessionId,
                           jumpable: route(for: notice.sessionId) != .nowhere)
        }
        if !notices.isEmpty {
            lastSpoken[.sessionDone] = now
            lastAnything = now
        }
    }
    /// How long the pointer must rest on the pet before it volunteers the quota.
    private static let dwellDelay: TimeInterval = 1

    /// The last render's state as finish detection read it (StateAggregator.settled).
    private var lastState: GlobalState?
    private var lastSpoken: [Chatter.Kind: Date] = [:]
    private var lastAnything: Date?
    private var usageCache: (snapshot: UsageSnapshot?, readAt: Date)?
    /// Which quota reading is newest, learned by watching — and kept in `usage-seen.json` so a
    /// restart does not have to learn it again (see UsageRecency.saved).
    private lazy var usageRecency: UsageRecency =
        (try? Data(contentsOf: usageSeenURL)).flatMap { UsageRecency(saved: $0, now: Date()) } ?? UsageRecency()
    private var usageSeenURL: URL { petHome.appending(path: "usage-seen.json") }
    /// Fires each time a file lands in ~/.claude/pet itself (not its subfolders) — in practice
    /// every quota write. UsageRecency needs to see each session's reading, and the file flips
    /// between them every few seconds, far faster than the 5 s render.
    private var usageWatch: DispatchSourceFileSystemObject?
    /// The watch's backstop: a writer that rewrites in place fires no folder event, and a folder
    /// removed and made again leaves the watch on the old one.
    private var usageTimer: Timer?
    private var dwellTimer: Timer?
    private var dwellShowing = false
    private var dwellTarget: DwellTarget?
    /// A row name needs a shorter fuse than the quota readout: the pointer is
    /// already moving down a list, and a full second feels broken.
    private static let rowDwellDelay: TimeInterval = 0.45

    private var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// Re-reading on every 5 s render would be waste: the watcher below keeps `usageRecency` up to
    /// date between renders, and this only falls back to a read when nothing has arrived lately.
    private func currentUsage() -> UsageSnapshot? {
        let now = Date()
        if let cached = usageCache, now.timeIntervalSince(cached.readAt) < 15 {
            return cached.snapshot
        }
        return sampleUsage(now: now)
    }

    /// Reads the quota sources once and notes the reading.
    private func sampleUsage(now: Date) -> UsageSnapshot? {
        // Up to three sources, read independently and never blended. The one that wins is decided
        // by UsageSources, which puts freshness first: a reading from a better source that has gone
        // stale still describes a window that may have rolled over.
        var candidates: [UsageSnapshot] = []
        if let hud = (try? Data(contentsOf: UsageReader.cacheURL(claudeHome: claudeHome)))
            .flatMap(UsageReader.parse) {
            candidates.append(hud)
        }
        if let saved = (try? Data(contentsOf: UsageReader.snapshotURL(petHome: petHome)))
            .flatMap(UsageReader.parseSnapshot) {
            candidates.append(saved)
        }
        if let line = (try? Data(contentsOf: StatuslineUsage.cacheURL(petHome: petHome)))
            .flatMap(StatuslineUsage.decode) {
            candidates.append(line)
        }
        // Sessions take turns writing their own last-known figures into one file; the figure
        // that appeared last is the true one — see UsageRecency.
        let picked = UsageSources.pick(candidates, now: now)
        // Nothing readable this time (a file mid-write, or claude-hud writing null for a window
        // that ran out): keep what was known rather than blanking the meters until the next write.
        var snapshot = picked ?? usageRecency.current()
        if let picked, picked.percentagesUsable(now: now) {
            if usageRecency.observe(picked, now: now), let data = usageRecency.saved() {
                // Only when a reading is new: a handful of writes an hour. Landing in the watched
                // folder brings one more sample, which finds nothing new and writes nothing.
                try? data.write(to: usageSeenURL, options: .atomic)
            }
            snapshot = usageRecency.current() ?? picked
        }
        usageCache = (snapshot, now)
        return snapshot
    }

    private func watchUsage() {
        guard usageWatch == nil else { return }
        try? FileManager.default.createDirectory(at: petHome, withIntermediateDirectories: true)
        let fd = open(petHome.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.sampleUsage(now: Date()) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        usageWatch = source
        usageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.sampleUsage(now: Date()) }
        }
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
        let rearmed = QuotaAlarm.rearmed(quotaSaid, usage: usage, now: now)
        if rearmed != quotaSaid {
            quotaSaid = rearmed
            saveQuotaSaid()
        }
        let decision = QuotaAlarm.evaluate(usage: usage, alreadySaid: quotaSaid, now: now)
        let names = sessionNames(state)
        let contextNote = contextAlarm.due.lazy.compactMap { sid -> Chatter.ContextNote? in
            guard let session = state.sessions.first(where: { $0.sessionId == sid }),
                  let reading = self.contextReadings[sid] else { return nil }
            return Chatter.ContextNote(sessionId: sid, name: names[sid] ?? session.project,
                                       tokens: reading.tokens)
        }.first
        guard let line = Chatter.next(
            state: state, previous: lastState, usage: usage, now: now,
            lastSpoken: lastSpoken, lastAnything: lastAnything, names: names,
            quotaAlarm: decision.speak, contextNote: contextNote
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
        if line.kind == .contextLong, let note = contextNote { contextAlarm.said(note.sessionId) }
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
        answer(sessionID: sessionID, reply: PermissionDecision.Answer(askId: askId, behavior: behavior))
    }

    /// `answer`, with what a question or a plan is answered with: the picks, or feedback.
    private func answer(sessionID: String, reply: PermissionDecision.Answer) {
        let now = Date()
        let askId = reply.askId
        let file = PermissionDecision.fileURL(petHome: petHome, sessionId: sessionID)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? PermissionDecision.encode(reply).write(to: file, options: .atomic)) != nil else {
            bridge?.say(L("could not answer — use the terminal", "没能回应 — 请到终端里处理"), hold: 5, variant: .warn)
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

    /// sessionId → its context, measured against the auto-compact window its
    /// model has (see ContextBudget). The transcript's token count wins: it is
    /// exact and always there. A fresh statusline percentage — a share of the
    /// model's whole window — covers a session whose transcript has no reply yet.
    private func readContext(for sessions: [SessionState], now: Date) -> [String: ContextBudget.Reading] {
        reloadBudgetSettings()
        var out: [String: ContextBudget.Reading] = [:]
        for session in sessions {
            let read = transcriptStats[session.sessionId]
            let model = read?.model ?? ""
            let budget = ContextBudget.budget(model: model, settings: budgetSettings)
            if let read, read.contextTokens > 0 {
                out[session.sessionId] = ContextBudget.Reading(tokens: read.contextTokens, budget: budget)
            } else if let insight = insights[session.sessionId], insight.isFresh(now: now),
                      let percent = insight.contextPercent {
                // A share of a window this does not know (no model read yet), so
                // it is shown as it came, not turned into tokens.
                out[session.sessionId] = ContextBudget.Reading(percentOnly: percent)
            }
        }
        return out
    }

    /// `/autocompact` writes the user settings file; a stat per render is all
    /// it costs to notice.
    private func reloadBudgetSettings() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard stamp != budgetSettingsStamp else { return }
        budgetSettingsStamp = stamp
        budgetSettings = (try? Data(contentsOf: url)).map(ContextBudget.parse) ?? ContextBudget.Settings()
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

        let rename = NSMenuItem(title: current.alias.isEmpty ? L("Name This Session…", "给这个 session 起名…") : L("Rename…", "重命名…"),
                                action: #selector(renamePicked(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = sessionID
        menu.addItem(rename)

        let pin = NSMenuItem(title: current.pinned ? L("Unpin", "取消置顶") : L("Pin to Top", "置顶"),
                             action: #selector(pinPicked(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = sessionID
        menu.addItem(pin)

        menu.addItem(.separator())
        let mute = NSMenuItem(title: L("Mute Until I Speak To It", "静音，直到我再和它说话"),
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
        alert.messageText = L("Name this session", "给这个 session 起名")
        alert.informativeText = L("Shown instead of the folder name and the tab title. "
            + "Leave it empty to go back to those.",
            "显示时代替文件夹名和标签页标题。留空就恢复原样。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = labelPrefs[id]?.alias ?? ""
        field.placeholderString = session.project
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save", "保存"))
        alert.addButton(withTitle: L("Cancel", "取消"))
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
    private static let noticeHoldKey = "noticeHoldSeconds"
    private static let noticeCountKey = "noticeCount"
    /// Settings → Bubble Duration / Bubbles at Once.
    private var noticeHold = Chatter.noticeHold
    private var noticeCount = Chatter.noticeCount

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
    private var boardWindow: BoardWindow?
    /// HQ's view of the world: tasks per session, open asks, today's focus.
    private let taskIndex = TaskIndex()
    /// Asks already announced, so each new one is said once (nil until the first read, which
    /// only records what is there — a restart must not replay old questions).
    private var announcedAsks: Set<String>?

    /// A new question on the HQ board gets a notice, like a finished turn does; clicking it goes
    /// to the session that asked.
    private func announceAsks(_ hq: TaskIndex.Snapshot) {
        let ids = Set(hq.openAsks.map(\.id))
        guard let already = announcedAsks else { announcedAsks = ids; return }
        for ask in hq.openAsks where !already.contains(ask.id) {
            let text = ask.text.count > 90 ? String(ask.text.prefix(90)) + "…" : ask.text
            bridge?.notify(L("\(ask.task) asks: \(text)", "\(ask.task) 在问：\(text)"), hold: 25, emphasis: ask.task, sessionId: ask.session,
                           jumpable: !ask.session.isEmpty)
        }
        // Remember every ask announced, not only the ones open now: one put off with "Later"
        // leaves the list and comes back the next day — that is not a new question.
        announcedAsks = already.union(ids)
    }


    /// Settings → Language, or the board's own switch: "en", "zh", or "auto" to follow the
    /// system. Menus are built when opened, so only the pages and the open report need redoing.
    private func setLanguage(_ id: String) {
        guard id != UILanguage.stored else { return }
        if id == "en" || id == "zh" { UserDefaults.standard.set(id, forKey: UILanguage.key) }
        else { UserDefaults.standard.removeObject(forKey: UILanguage.key) }
        panel?.reloadForLanguage()
        boardWindow?.reloadForLanguage()
        if healthWindow?.isVisible == true { showHealth() }
    }

    /// The HQ task board. One window, reused: closing hides it, reopening
    /// refreshes it.
    private func showBoard(reveal task: String = "", session: String = "") {
        let window = boardWindow ?? BoardWindow()
        boardWindow = window
        window.present(reveal: task, session: session)
    }

    // MARK: - Where a click on a session goes

    /// Settings → "Clicking a Session Opens": its terminal, or its task on the board.
    private var clickTarget = ClickTarget(stored: UserDefaults.standard.string(forKey: ClickTarget.key))

    /// From the pet's menu or the board's settings, which both show this one value.
    private func setClickTarget(_ target: ClickTarget) {
        guard target != clickTarget else { return }
        clickTarget = target
        UserDefaults.standard.set(target.rawValue, forKey: ClickTarget.key)
        // Rows bound to a task but with no terminal become clickable, or stop being.
        render()
    }

    /// Where a click on this session would go, its terminal taken from what the pet last read.
    private func route(for sessionID: String) -> ClickTarget.Route {
        let terminal = latest.first { $0.sessionId == sessionID }?.terminal
        return clickTarget.route(task: taskIndex.snapshot().taskBySession[sessionID],
                                 canJump: terminal.map { TerminalTarget.canJump(kind: $0.kind) } ?? false)
    }

    /// Opens a session from the pet — a notice, a row in its list, the shortcut — where
    /// Settings says: its terminal, or the board at its task, with the session picked out and
    /// its conversation open. Returns where it went; `.nowhere` opened nothing.
    @discardableResult
    private func openSession(_ sid: String, kind: String, handle: String, source: String) -> ClickTarget.Route {
        let canJump = !handle.isEmpty && TerminalTarget.canJump(kind: kind)
        let route = clickTarget.route(task: sid.isEmpty ? nil : taskIndex.snapshot().taskBySession[sid],
                                      canJump: canJump)
        switch route {
        case .board(let task):
            TerminalJump.record?(.init(session: sid, source: source), "board")
            showBoard(reveal: task, session: sid)
        case .terminal:
            TerminalJump.jump(kind: kind, handle: handle, from: .init(session: sid, source: source))
        case .nowhere:
            break
        }
        return route
    }

    /// Double-click on the pet: show the board, or put it away if it is
    /// already in view. A board that is open but buried counts as not shown.
    private func toggleBoard() {
        if let w = boardWindow, w.isVisible, w.occlusionState.contains(.visible) {
            w.orderOut(nil)
        } else {
            showBoard()
        }
    }
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
        guard let found = HealthCollector.quickProblemKeyed(petHome: petHome),
              mentionedProblem != found.key else { return }
        mentionedProblem = found.key
        let problem = found.check
        bridge?.say(L("\(problem.name): \(problem.detail) — right-click me for details",
                      "\(problem.name)：\(problem.detail) — 右键点我看详情"),
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

    /// Computed, so the captions follow the language the pet is set to (see `L`).
    private static var demoSteps: [DemoStep] { [
        DemoStep(caption: L("editing a file", "在改文件"), mood: .busy, tool: "Edit",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: L("reading around the code", "在读代码"), mood: .busy, tool: "Read",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: L("waiting on a command", "在等一条命令跑完"), mood: .busy, tool: "Bash",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: L("a tool call was interrupted", "一次工具调用被打断了"), mood: .busy, tool: "Bash",
                 project: "api-server", waitingOn: "", phase: "", flash: "trouble"),
        DemoStep(caption: L("compacting its context", "在 compact 它的 context"), mood: .busy, tool: "",
                 project: "api-server", waitingOn: "", phase: "compacting", flash: ""),
        DemoStep(caption: L("waiting on a background agent", "在等一个后台 agent"), mood: .busy, tool: "",
                 project: "api-server", waitingOn: "", phase: "awaiting-agent", flash: ""),
        DemoStep(caption: L("asking to run something", "要运行什么，等你授权"), mood: .waiting, tool: "",
                 project: "api-server", waitingOn: "rm -rf build/", phase: "", flash: ""),
        DemoStep(caption: L("asking you a question", "在问你问题"), mood: .waiting, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
        DemoStep(caption: L("ignored for a minute", "一分钟没人理了"), mood: .urgent, tool: "",
                 project: "api-server", waitingOn: "rm -rf build/", phase: "", flash: ""),
        DemoStep(caption: L("a turn just finished", "刚做完一轮"), mood: .idle, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: "done"),
        DemoStep(caption: L("nothing to do", "空闲"), mood: .idle, tool: "",
                 project: "api-server", waitingOn: "", phase: "", flash: ""),
    ] }

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
        bridge?.say(L("demo · \(step.caption)", "演示 · \(step.caption)"), hold: 0, emphasis: L("demo", "演示"))
    }

    // MARK: - Shortcut

    private static let hotKeyKey = "globalShortcutEnabled"

    private static let noteHotKeyKey = "quickNoteShortcutEnabled"

    private func toggleHotKey() { toggle(hotKey, key: Self.hotKeyKey) }
    private func toggleNoteHotKey() { toggle(noteHotKey, key: Self.noteHotKeyKey) }

    private func toggle(_ hotKey: HotKey?, key: String) {
        guard let hotKey else { return }
        if hotKey.isRegistered {
            hotKey.unregister()
            UserDefaults.standard.set(false, forKey: key)
            return
        }
        // Only remember it as on if it actually took: another app may already
        // own the chord, and a menu tick that lies is worse than no feature.
        let ok = hotKey.register()
        UserDefaults.standard.set(ok, forKey: key)
        if !ok {
            bridge?.say(L("\(hotKey.name) is taken by another app", "\(hotKey.name) 已被别的应用占用"), hold: 5)
        }
    }

    // MARK: - Quick notes

    /// The shortcut again while the box is up closes it.
    private func showQuickNote() {
        if quickNote.isVisible { quickNote.close() } else { quickNote.show() }
    }

    /// Files the note (`hq inbox add`), has it sorted (`hq inbox sort`, a few seconds), and says
    /// where it went — or that it waits in Needs you, where it can be moved with a click.
    private func fileQuickNote(_ text: String, images: [String]) {
        Task { @MainActor [weak self] in
            let added = await BoardBridge.noteAdd(text: text, images: images, via: "hotkey")
            guard let id = Self.noteJSON(added.0)?["id"] as? String else {
                let err = added.1 ?? "?"
                self?.bridge?.say(L("Couldn't note that: \(err)", "没记下：\(err)"), hold: 6)
                // Nothing typed is lost: the box comes back with it.
                self?.quickNote.restore(text: text, images: images, error: err)
                return
            }
            self?.bridge?.say(L("Noted — sorting…", "记下了，正在分拣…"), hold: 4)
            let sorted = await BoardBridge.noteSort(id)
            guard let note = Self.noteJSON(sorted.0) else {
                self?.bridge?.say(L("Noted, but sorting failed — it's in Needs you", "记下了，但分拣出错——在 Needs you 里"), hold: 6)
                return
            }
            if note["state"] as? String == "sorted", let dest = note["dest"] as? [String: Any] {
                let label = Self.noteDestLabel(dest)
                self?.bridge?.say(L("Filed: \(label)", "已放到：\(label)"), hold: 6, emphasis: label)
            } else {
                self?.bridge?.say(L("Not sure where that goes — it's waiting in Needs you", "没把握放哪——在 Needs you 里等你挑"), hold: 6)
            }
        }
    }

    private static func noteJSON(_ out: Any?) -> [String: Any]? {
        guard let text = out as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Where a note went, the way the board says it (board.js destLabel).
    static func noteDestLabel(_ d: [String: Any]) -> String {
        let task = d["task"] as? String ?? ""
        switch d["kind"] as? String ?? "" {
        case "task": return L("new task “\(d["title"] as? String ?? "")”", "新任务「\(d["title"] as? String ?? "")」")
        case "todo": return "\(task) " + L("todo", "待办") + " @\(d["owner"] as? String ?? "me")"
        case "note": return "\(task) " + L("log", "记录")
        case "update": return "\(task) " + L("update", "更新") + updateDetail(d)
        default: return L("your todo", "我的待办")
        }
    }

    /// What an update changes beyond its log line, as board.js updateDetail says it.
    static func updateDetail(_ d: [String: Any]) -> String {
        var bits: [String] = []
        if let s = d["status"] as? String, !s.isEmpty {
            bits.append("→ " + (statusWord[s].map { L($0.0, $0.1) } ?? s))
        }
        if let n = d["next"] as? String, !n.isEmpty { bits.append(L("next", "下一步")) }
        if let st = d["state"] as? String, !st.isEmpty { bits.append(L("state", "状态说明")) }
        if let done = d["done"] as? [String], !done.isEmpty {
            if done.count == 1 {
                // The todo itself, without its owner, shortened as the board does.
                var t = done[0].replacingOccurrences(of: #"^@\S+\s+"#, with: "", options: .regularExpression)
                if t.count > 24 { t = String(t.prefix(23)) + "…" }
                bits.append("✓ \(t)")
            } else {
                bits.append(L("✓ \(done.count) todos", "勾掉 \(done.count) 条待办"))
            }
        }
        return bits.isEmpty ? "" : " · " + bits.joined(separator: " · ")
    }
    private static let statusWord: [String: (String, String)] = [
        "active": ("ready", "待推进"), "blocked": ("blocked", "卡住"), "waiting-on-me": ("needs you", "等你"),
        "done": ("done", "完成"), "abandoned": ("abandoned", "放弃")]

    /// Go to whatever has been waiting longest. Every outcome says what
    /// happened — a shortcut that does nothing visible is one the user stops
    /// trusting after the first silent press.
    private func jumpToNextWaiting() {
        let now = Date()
        let state = StateAggregator.aggregate(latest, now: now, hidden: hiddenMarks,
                                              snoozed: snoozeMarks, approved: isSettled)
        guard let target = PanelModel.jumpTarget(state.sessions, snoozed: snoozeMarks, now: now)
        else {
            bridge?.say(L("nothing is waiting on you", "没有在等你的 session"), hold: 3)
            return
        }
        // Its terminal, or its task on the board — the same setting as a click.
        guard openSession(target.sessionId, kind: target.terminal?.kind ?? "",
                          handle: target.terminal?.handle ?? "", source: "hotkey") != .nowhere else {
            // Still a jump the user wanted; the log is about why, not whether it worked.
            TerminalJump.record?(.init(session: target.sessionId, source: "hotkey"), "")
            bridge?.say(L("\(target.project) is waiting, but its terminal cannot be addressed",
                          "\(target.project) 在等你，但跳不到它的终端"),
                        hold: 5, emphasis: target.project)
            return
        }
    }

    /// When each session's conversation was last shown in the board's Peek, since the pet started.
    private var peekedAt: [String: Date] = [:]

    /// One line in jumps.jsonl: what the session was doing when the user went back to its
    /// terminal, and from where — see JumpLog.
    private func recordJump(_ origin: TerminalJump.Origin, kind: String) {
        let now = Date()
        let sid = origin.session
        // Muted sessions count too: hiding a row says nothing about why you went to it.
        let session = StateAggregator.aggregate(latest, now: now, approved: isSettled).sessions
            .first { $0.sessionId == sid }
        let state = JumpLog.state(of: session, quiet: session.map { StateAggregator.isQuiet($0, now: now) } ?? false)
        // Gone quiet: count from the silence, not from when the work began.
        let entered = state == .interrupted ? session?.updatedAt : session?.since
        let event = JumpLog.Event(
            at: now, session: sid, source: origin.source, state: state,
            view: origin.view,
            task: sid.isEmpty ? nil : taskIndex.snapshot(now: now).taskBySession[sid],
            project: session?.project ?? "",
            context: contextReadings[sid]?.percent,
            waited: entered.map { Int(max(0, now.timeIntervalSince($0))) },
            peekedAgo: peekedAt[sid].map { Int(max(0, now.timeIntervalSince($0))) },
            terminal: kind)
        JumpLog.append(event, to: petHome.appending(path: "jumps.jsonl"))
    }

    /// Offers 5 / 15 / 30 minutes at the pointer.
    ///
    /// A menu rather than a fixed delay: "remind me later" without saying when
    /// is how an item quietly becomes an item nobody ever sees again.
    private func askSnooze(sessionID: String, at point: CGPoint) {
        guard !sessionID.isEmpty, let view = panel?.contentView else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L("Remind me in…", "多久后提醒我…"), action: nil, keyEquivalent: "").isEnabled = false
        for minutes in Snooze.options {
            let item = NSMenuItem(title: L("\(minutes) minutes", "\(minutes) 分钟"),
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
                                    transcript: transcriptStats[sessionID],
                                    context: contextReadings[sessionID],
                                    lastActivity: recent,
                                    background: backgroundShells[sessionID] ?? [], now: Date())
    }

    /// Acknowledging finishes. Re-rendering immediately is what makes the badge
    /// and the list agree without waiting for the next tick.
    /// A click on a finish notice: the same as clicking that session's row in
    /// Finished. Go there and call its finishes read; with nowhere to go, open
    /// the list, which is where the row is.
    private func openNotice(sessionID: String) {
        bridge?.dismissNotice(sessionID)
        // A scheduled job's notice: its runs are on the board.
        if sessionID.hasPrefix("job:") { return showBoard(reveal: "jobs") }
        let terminal = latest.first(where: { $0.sessionId == sessionID })?.terminal
        guard openSession(sessionID, kind: terminal?.kind ?? "", handle: terminal?.handle ?? "",
                          source: "pet-notice") != .nowhere else {
            bridge?.setPanelOpen(true)
            return
        }
        markSessionRead(sessionID)
    }

    private func markSessionRead(_ sessionID: String) {
        let ids = (completions?.unread ?? []).filter { $0.sessionId == sessionID }.map(\.eventId)
        if !ids.isEmpty { markRead(ids) }
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
