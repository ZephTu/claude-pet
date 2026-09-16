import AppKit
import ClaudePetCore
import WebKit

/// The pet's window. Every setting here exists to stop the panel behaving like
/// an ordinary window — see the design doc, section 4.
///
/// The window is `PetLayout.windowSize` (400x280), not the size of the pet:
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

    private var layoutHandler: LayoutMessageHandler?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var clickThroughPoll: Timer?

    init() {
        let size = PetLayout.windowSize
        let config = WKWebViewConfiguration()
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
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func loadPetPage() {
        guard let dir = Bundle.module.url(forResource: "pet", withExtension: nil) else {
            // assertionFailure alone is a no-op in release, which is the only
            // build that ships — without this the failure mode is a blank
            // window and no clue anywhere.
            NSLog("ClaudePet: pet resources missing from bundle; the pet will not render")
            assertionFailure("pet resources missing from bundle")
            return
        }
        let index = dir.appendingPathComponent("index.html")
        webView.loadFileURL(index, allowingReadAccessTo: dir)
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
        setFrameOrigin(p)
        return true
    }

    func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    // MARK: - Pixel-level click-through (design doc section 4)

    /// Most of a 400x280 mostly-transparent window is not the pet. Without this
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

    init(onLayout: @escaping (CGRect?, CGRect?) -> Void) {
        self.onLayout = onLayout
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
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
