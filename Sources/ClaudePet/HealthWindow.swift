import AppKit
import ClaudePetCore

/// The connection report, in the pet's own visual language.
///
/// An NSAlert was what this used to be, and an NSAlert cannot be made to look
/// like anything: it brings a system icon, a white sheet and a title in the
/// wrong weight, so a dark, quiet pet opened a bright macOS dialog. This is a
/// borderless panel styled like the session list — same charcoal, same corner
/// radius, same type scale — so it reads as part of the same object.
@MainActor
final class HealthWindow: NSPanel {
    private let onCopy: () -> Void

    init(checks: [HealthCheck], onCopy: @escaping () -> Void) {
        self.onCopy = onCopy
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        // Always dark, whatever the system is set to: this belongs to a pet
        // whose panel is charcoal, and a light report beside a dark list reads
        // as two different apps. The semantic text colours follow this, so
        // nothing here hard-codes white.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        // Follows the pet onto whatever Space and full-screen app it is on.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let body = NSVisualEffectView()
        body.material = .hudWindow
        body.state = .active
        body.blendingMode = .behindWindow
        body.wantsLayer = true
        body.layer?.cornerRadius = 12
        body.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(Self.title("Connection status"))
        for check in checks { stack.addArrangedSubview(Self.row(check)) }
        stack.addArrangedSubview(Self.buttons(target: self))

        body.addSubview(stack)
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView = body
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        setContentSize(stack.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func show(near anchor: NSRect) {
        // Beside the pet, and never off the screen it is on.
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?
            .visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX - frame.width - 12, y: anchor.midY - frame.height / 2)
        if origin.x < visible.minX { origin.x = anchor.maxX + 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    // MARK: - Pieces

    private static func title(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    /// One check: a coloured dot, the name, and the detail underneath.
    ///
    /// The dot carries the status rather than a word, because the word is the
    /// part people stop reading. Colour AND shape differ per status so it does
    /// not depend on colour vision alone.
    private static func row(_ check: HealthCheck) -> NSView {
        let dot = NSTextField(labelWithString: glyph(check.status))
        dot.font = .systemFont(ofSize: 11)
        dot.textColor = colour(check.status)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: check.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .labelColor

        let status = NSTextField(labelWithString: check.status.label)
        status.font = .systemFont(ofSize: 11)
        status.textColor = colour(check.status)

        let head = NSStackView(views: [dot, name, status])
        head.orientation = .horizontal
        head.spacing = 6
        head.alignment = .firstBaseline

        let detail = NSTextField(wrappingLabelWithString: check.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 328

        let column = NSStackView(views: [head, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        return column
    }

    private static func glyph(_ status: HealthCheck.Status) -> String {
        switch status {
        case .ok: return "●"
        case .needsAttention: return "▲"
        case .notConfigured: return "○"
        case .unsupported: return "—"
        case .unknown: return "?"
        }
    }

    private static func colour(_ status: HealthCheck.Status) -> NSColor {
        switch status {
        case .ok: return NSColor(calibratedRed: 0.40, green: 0.64, blue: 0.60, alpha: 1)
        case .needsAttention: return NSColor(calibratedRed: 0.88, green: 0.33, blue: 0.24, alpha: 1)
        case .unknown: return NSColor(calibratedRed: 0.88, green: 0.65, blue: 0.24, alpha: 1)
        case .notConfigured, .unsupported: return .tertiaryLabelColor
        }
    }

    private static func buttons(target: HealthWindow) -> NSView {
        let copy = NSButton(title: "Copy", target: target, action: #selector(copyTapped))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        let close = NSButton(title: "Close", target: target, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.keyEquivalent = "\u{1b}"   // Esc

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, copy, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        return row
    }

    /// Renders the panel to a PNG without a screen.
    ///
    /// Screen capture needs a permission this app has no business asking for,
    /// so layout is checked by drawing the view itself. The blur material does
    /// not exist off-screen, hence the flat backing colour — this verifies
    /// arrangement and type, not the vibrancy.
    static func renderPreview(checks: [HealthCheck], to path: String) -> Bool {
        let window = HealthWindow(checks: checks, onCopy: {})
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    @objc private func copyTapped() {
        onCopy()
        close()
    }

    @objc private func closeTapped() { close() }
}
