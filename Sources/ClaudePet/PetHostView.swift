import AppKit
import ClaudePetCore
import WebKit

/// Sits between the panel and the WKWebView and owns every mouse event.
///
/// This exists because WKWebView implements `rightMouseDown:`, `mouseDown:` and
/// friends itself and fills the whole window: while it was the contentView, the
/// window's own overrides were never reached (right-click died at the view
/// layer) and `isMovableByWindowBackground` never engaged (it only moves windows
/// for views whose `mouseDownCanMoveWindow` is true, and WKWebView's is false).
///
/// So the web view is demoted to a pure renderer — `hitTest` never returns it —
/// and left-click / right-click / drag are all resolved here, in one place,
/// against one geometry (`PetLayout`). Scroll is the single exception and is
/// forwarded, so a long session list still scrolls natively.
@MainActor
final class PetHostView: NSView {
    /// Left click that was not a drag, in CSS coordinates. Carries the point
    /// because a click on a session row jumps to that terminal while a click
    /// anywhere else on the pet toggles the panel — and only the page knows
    /// where the rows ended up.
    var onClick: ((CGPoint) -> Void)?
    /// Right click, in this view's coordinates.
    var onRightClick: ((NSPoint) -> Void)?

    private let webView: WKWebView

    /// Interactive regions reported by the page, in CSS coordinates.
    private(set) var panelRect: CGRect?
    private(set) var bubbleRect: CGRect?

    /// True between mouseDown and mouseUp of an actual drag. The click-through
    /// monitor must not flip `ignoresMouseEvents` in the middle of one.
    private(set) var isDragging = false

    private var dragAnchor: NSPoint?
    private var windowAnchor: NSPoint?
    private static let dragThreshold: CGFloat = 3

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: NSRect(origin: .zero, size: PetLayout.windowSize))
        autoresizesSubviews = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    /// The page tells us where the panel and bubble actually ended up, so the
    /// hit region never has to guess at content-dependent layout.
    func updateLayout(panel: CGRect?, bubble: CGRect?) {
        panelRect = panel
        bubbleRect = bubble
    }

    /// AppKit's y grows upward, CSS's grows downward; convert once, here.
    func cssPoint(from viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    /// True when the layout is flipped (pet left, panel right). Kept here
    /// because hit testing is the other half of that flip — the drawing moves
    /// in CSS, the boxes move here, and the two must change together.
    var isMirrored = false

    /// Which figure is on screen. The hit region is measured off the drawing,
    /// so swapping the drawing has to swap the rectangles with it.
    var skin: PetSkin = .robot

    func opaqueRegionContains(_ p: NSPoint) -> Bool {
        PetLayout.isOpaque(at: cssPoint(from: p), panel: panelRect, bubble: bubbleRect,
                           mirrored: isMirrored, skin: skin)
    }

    // MARK: - Event routing

    /// Never hand the event to the web view, and claim nothing in the
    /// transparent region.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return opaqueRegionContains(local) ? self : nil
    }

    /// The app is an accessory and the panel never becomes key, so the first
    /// click must still count instead of being swallowed as an activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragAnchor = screenPoint(of: event)
        windowAnchor = window?.frame.origin
        isDragging = false
    }

    /// Anchor and delta are both taken in SCREEN coordinates. Window
    /// coordinates would feed the drag back into itself: locationInWindow is
    /// measured against a window that this very handler is moving.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor, let origin = windowAnchor, let window else { return }
        let now = screenPoint(of: event)
        let dx = now.x - anchor.x
        let dy = now.y - anchor.y
        if !isDragging, hypot(dx, dy) < Self.dragThreshold { return }
        isDragging = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        dragAnchor = nil
        windowAnchor = nil
        isDragging = false
        if !wasDragging {
            onClick?(cssPoint(from: convert(event.locationInWindow, from: nil)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }

    /// Scrolling has to be translated rather than forwarded. Handing the event
    /// straight to the web view does nothing (measured: scrollTop stayed at 0),
    /// because WKWebView scrolls through its own event path — and it never sees
    /// a real scroll event anyway, since hitTest keeps every event on this view.
    /// Fire-and-forget: a dropped scroll tick costs nothing.
    override func scrollWheel(with event: NSEvent) {
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        let dy = event.hasPreciseScrollingDeltas ? raw : raw * 10
        webView.evaluateJavaScript("window.scrollPanel(\(-dy));", completionHandler: nil)
    }
}
