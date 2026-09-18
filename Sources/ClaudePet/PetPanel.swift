import AppKit
import ClaudePetCore
import WebKit

/// The pet's window. Every setting here exists to stop the panel behaving like
/// an ordinary window — see the design doc, section 4.
///
/// The window is `PetLayout.windowSize` (480x280), not the size of the pet:
/// the expanded session panel lives *inside* it, to the left of the star. The
/// star still sits in the bottom-right 160x160 of the window, so the default
/// origin puts it exactly where the old 160x160 window put it.
@MainActor
final class PetPanel: NSPanel {
    let webView: WKWebView
    private let host: PetHostView

    /// Called once the pet page is ready to receive setMood().
    var onReady: (() -> Void)?

    /// Called on a left click that was not a drag.
    var onClick: ((CGPoint) -> Void)?

    /// Pointer position in CSS coordinates, plus whether the session list is
    /// open. The page cannot track this itself: it receives no mouse events at
    /// all, so :hover never fires there. Reported with the panel closed too,
    /// because resting on the pet is what triggers the quota readout.
    var onHover: ((CGPoint, Bool) -> Void)?

    /// Called on a right-click over the pet, in content-view coordinates.
    var onRightClick: ((NSPoint) -> Void)?

    // Bumped from "petOrigin": that key was written by the old 160x160 window,
    // and reusing it would place the new window 240pt off from where the pet
    // visually was.
    private static let originKey = "petOrigin.v2"
    /// Saved beside the origin: the origin alone no longer says where the pet
    /// IS, because a mirrored window draws it 320pt further left.
    private static let mirroredKey = "petMirrored"

    private var layoutHandler: LayoutMessageHandler?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var clickThroughPoll: Timer?

    /// Retained for as long as the web view: WKWebView does not own it.
    private let petScheme: PetSchemeHandler?

    init() {
        let size = PetLayout.windowSize
        let config = WKWebViewConfiguration()
        // One origin for the page and everything it loads — see PetSchemeHandler.
        petScheme = Bundle.module.url(forResource: "pet", withExtension: nil)
            .map { PetSchemeHandler(root: $0) }
        if let petScheme {
            config.setURLSchemeHandler(petScheme, forURLScheme: PetSchemeHandler.scheme)
        }
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        host = PetHostView(webView: webView)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Float above ordinary windows but never over a full-screen app.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        // Dragging is done by hand in PetHostView. AppKit's background drag is
        // useless here: it only moves the window for views whose
        // mouseDownCanMoveWindow is true, and WKWebView's is false.
        isMovableByWindowBackground = false
        // Clicking the pet must not steal focus from whatever you are typing in.
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true

        // Let the page's own transparency through instead of painting white.
        webView.setValue(false, forKey: "drawsBackground")
        contentView = host

        host.onClick = { [weak self] point in self?.onClick?(point) }
        // The side is decided on release, not during the drag: see updateLayoutSide.
        host.onDragEnded = { [weak self] in self?.updateLayoutSide() }
        host.onRightClick = { [weak self] point in self?.onRightClick?(point) }

        let handler = LayoutMessageHandler { [weak self] panel, bubble in
            self?.host.updateLayout(panel: panel, bubble: bubble)
        }
        // Registered on webView.configuration (the view's own live copy), not the
        // local `config` used at init: WKWebViewConfiguration is documented as
        // being copied when the WKWebView is created, so mutating the original
        // afterwards is not guaranteed to reach the view.
        webView.configuration.userContentController.add(handler, name: "layout")
        layoutHandler = handler

        webView.navigationDelegate = self
        loadPetPage()

        // NSWindow.setFrame(_:display:) is NOT called by setFrameOrigin(_:) — verified
        // by instrumenting it. didMoveNotification is the reliable signal for "the
        // window moved, for any reason" and is what fires on every drag and every
        // programmatic move, so origin persistence hooks off that instead.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove), name: NSWindow.didMoveNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        startClickThroughMonitoring()
    }

    // Lifetime assumption: this panel is created once in AppMain and lives for
    // the whole process, so deinit in practice never runs. The mouse monitors
    // and the poll timer are therefore torn down only in
    // AppMain.applicationWillTerminate (via stopClickThroughMonitoring()), not
    // here — deinit is nonisolated (Swift 6 strict concurrency will not let it
    // touch these MainActor-isolated, non-Sendable stored properties), so it
    // only clears the one piece of state that is safe and cheap to clear from
    // a nonisolated context.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidMove() {
        saveOrigin()
        updateLayoutSide()
    }

    /// A display was plugged in, unplugged, or changed resolution.
    ///
    /// The saved spot can now be on no screen at all, or on one that shrank. The
    /// pet is moved back to somewhere reachable rather than left where nobody
    /// can click it — and it moves the minimum distance, so a setup that is
    /// still valid is not rearranged for no reason.
    @objc private func screensChanged() {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if let fixed = PetLayout.rescued(windowOrigin: frame.origin, visibleFrame: visible,
                                         mirrored: host.isMirrored) {
            setFrameOrigin(fixed)
            saveOrigin()
        }
        updateLayoutSide()
    }

    /// Called after any move: decides which side the panel opens on, and tells
    /// both halves — the page for drawing, the host view for hit testing.
    ///
    /// Recomputed on every move rather than once at launch, so dragging between
    /// displays and unplugging one both go through the same path as a drag.
    func updateLayoutSide() {
        // Never mid-drag. The flip moves the window, and the drag would undo
        // that on its very next event from its own anchor — which is the jump
        // this guard exists to prevent. Decided on release instead.
        guard !host.isDragging else { return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        guard visible.width > 0 else { return }
        let flip = PetLayout.shouldMirror(windowOrigin: frame.origin, visibleFrame: visible,
                                          mirrored: host.isMirrored)
        guard flip != host.isMirrored else { return }
        host.isMirrored = flip
        UserDefaults.standard.set(flip, forKey: Self.mirroredKey)
        onMirrorChanged?(flip)
        // The drawing just moved 320pt across the window; move the window the
        // other way so the pet stays under the spot it was dropped on.
        setFrameOrigin(NSPoint(x: frame.origin.x + PetLayout.flipShift(toMirrored: flip),
                               y: frame.origin.y))
    }

    /// The layout flipped; the page has to be told so it can move the drawing.
    var onMirrorChanged: ((Bool) -> Void)?

    /// Whether anything could actually be looking at the window. Covered by
    /// another window, on another Space, or on a sleeping display all read as
    /// not visible.
    var onVisibilityChanged: ((Bool) -> Void)?

    @objc private func occlusionChanged() {
        onVisibilityChanged?(occlusionState.contains(.visible))
    }

    var isMirrored: Bool { host.isMirrored }

    func rescueIfOffScreen() { screensChanged() }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps a window's top edge below the menu bar. Measured on this
    /// machine: asking a borderless panel for origin y=980 on a 1080pt screen
    /// gives back y=770 — its top pinned to the menu bar at 1050. The pet is
    /// drawn 140pt below the window's top, so that constraint is a 140pt band
    /// under the menu bar that the pet simply cannot be dragged into, and from
    /// the outside it looks like the pet is hitting an invisible shelf.
    ///
    /// The window is mostly transparent, so there is nothing to protect here —
    /// what has to stay reachable is the PET, and `PetHostView` clamps that
    /// against the screen the cursor is on while the drag is happening.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    private func loadPetPage() {
        guard petScheme != nil, let index = PetSchemeHandler.url(path: "index.html") else {
            // assertionFailure alone is a no-op in release, which is the only
            // build that ships — without this the failure mode is a blank
            // window and no clue anywhere.
            NSLog("ClaudePet: pet resources missing from bundle; the pet will not render")
            assertionFailure("pet resources missing from bundle")
            return
        }
        webView.load(URLRequest(url: index))
    }

    /// Which figure to draw. Changing it re-renders the page's pet slot; it does
    /// not reload anything.
    func setSkin(_ skin: PetSkin) { host.skin = skin }

    /// The page could not draw the skin it was given and is showing the robot.
    var onSkinFailed: ((String) -> Void)? {
        get { layoutHandler?.onSkinFailed }
        set { layoutHandler?.onSkinFailed = newValue }
    }

    /// Show without activating the app or pulling focus.
    func showOnDesktop() {
        if !restoreOrigin(), let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - frame.width - 40, y: f.minY + 40))
        }
        orderFrontRegardless()
    }

    /// Remember where the pet was dragged to, so it comes back to the same spot.
    @discardableResult
    func restoreOrigin() -> Bool {
        guard let s = UserDefaults.standard.string(forKey: Self.originKey) else { return false }
        let p = NSPointFromString(s)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: p, size: frame.size)) })
        else { return false }  // saved spot is on a screen that is no longer attached
        // Before the origin: the origin was saved for THIS side, and applying it
        // to the other one puts the pet 320pt from where it was left.
        host.isMirrored = UserDefaults.standard.bool(forKey: Self.mirroredKey)
        setFrameOrigin(p)
        return true
    }

    func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    // MARK: - Pixel-level click-through (design doc section 4)

    /// Most of a 480x280 mostly-transparent window is not the pet. Without this
    /// the whole rectangle is a dead zone that eats clicks meant for the window
    /// underneath.
    ///
    /// The computation only runs while the cursor is inside the window's rect,
    /// as the design doc asks — outside it, the answer cannot matter.
    private func startClickThroughMonitoring() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }

        // The monitors alone are not enough. Once ignoresMouseEvents is true the
        // window is out of the event path entirely, and not every way the cursor
        // can move posts a .mouseMoved event the monitor sees (a warp posts none
        // at all — measured). A slow poll that only does arithmetic while the
        // cursor is inside the window rect is the safety net: without it the pet
        // can get stuck click-through and stop responding altogether.
        let poll = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(poll, forMode: .common)
        clickThroughPoll = poll
    }

    func stopClickThroughMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        clickThroughPoll?.invalidate()
        clickThroughPoll = nil
    }

    /// Exposed (rather than private) so the behaviour can be driven and measured
    /// without a real cursor.
    func updateClickThrough(cursor: NSPoint = NSEvent.mouseLocation) {
        // Never flip mid-drag: losing the events halfway through would drop the pet.
        guard !host.isDragging else { return }
        guard frame.contains(cursor) else {
            // Left the window entirely: a point that can never hit anything
            // clears both the row highlight and the quota readout.
            onHover?(CGPoint(x: -1, y: -1), host.panelRect != nil)
            return
        }
        let local = host.convert(convertPoint(fromScreen: cursor), from: nil)
        ignoresMouseEvents = !host.opaqueRegionContains(local)
        onHover?(host.cssPoint(from: local), host.panelRect != nil)
    }
}

extension PetPanel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onReady?()
    }
}

/// Receives the page's own measurement of where the panel and bubble ended up.
/// Kept separate from PetPanel because WKUserContentController retains its
/// handlers strongly, and the window must not be kept alive by its own web view.
@MainActor
final class LayoutMessageHandler: NSObject, WKScriptMessageHandler {
    private let onLayout: (CGRect?, CGRect?) -> Void
    /// A skin that could not draw itself; the page has already fallen back to
    /// the robot and this is how Swift finds out.
    var onSkinFailed: ((String) -> Void)?

    init(onLayout: @escaping (CGRect?, CGRect?) -> Void) {
        self.onLayout = onLayout
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        // The page draws the robot instead, but the hit rectangles live on this
        // side — without this the cat's box would be tested against a robot.
        if let why = body["skinFailed"] as? String { onSkinFailed?(why) }
        onLayout(Self.rect(body["panel"]), Self.rect(body["bubble"]))
    }

    private static func rect(_ raw: Any?) -> CGRect? {
        guard let d = raw as? [String: Any],
              let x = d["x"] as? Double, let y = d["y"] as? Double,
              let w = d["w"] as? Double, let h = d["h"] as? Double,
              w > 0, h > 0
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
