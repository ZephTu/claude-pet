import AppKit
import ClaudePetCore

/// The quick-note box (⌃⌥⌘N, or "Quick Note…" in the pet's menu): one line, a link or a pasted
/// screenshot, filed by `hq inbox` — see BoardBridge.noteAdd / noteSort.
///
/// A non-activating panel, like Spotlight's: it takes the keyboard without bringing the pet
/// forward, so closing it puts you back in whatever you were typing in.
@MainActor
final class QuickNotePanel: NSObject, NSWindowDelegate, NSTextViewDelegate {
    /// Called with the text and the saved images' paths; the panel has closed by then.
    var onSubmit: ((String, [String]) -> Void)?

    private var panel: NSPanel?
    private var textView: NoteTextView?
    private var hint: NSTextField?
    private var images: [String] = []

    func show() {
        if panel == nil { build() }
        guard let panel, let textView else { return }
        // Where the pointer is: the screen you're looking at.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height / 4 - panel.frame.height))
        }
        updateHint()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func close() { panel?.orderOut(nil) }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = L("Quick note", "记一笔")
        p.titlebarAppearsTransparent = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self

        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 34, width: 492, height: 66))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let tv = NoteTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 15)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        tv.onImage = { [weak self] data, mime in self?.addImage(data, mime: mime) }
        scroll.documentView = tv

        let hint = NSTextField(labelWithString: "")
        hint.frame = NSRect(x: 14, y: 10, width: 492, height: 16)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width]

        content.addSubview(scroll)
        content.addSubview(hint)
        p.contentView = content
        panel = p
        textView = tv
        self.hint = hint
    }

    private func updateHint() {
        let parts = [L("Enter files it", "回车记下"), L("Shift-Enter: new line", "Shift+回车换行"),
                     L("paste a screenshot", "可以粘贴截图"), L("Esc closes", "Esc 关闭")]
        let imgs = images.isEmpty ? "" : L("📎 \(images.count) image(s) · ", "📎 \(images.count) 张图 · ")
        hint?.stringValue = imgs + parts.joined(separator: " · ")
    }

    private func addImage(_ data: Data, mime: String) {
        let r = BoardBridge.saveImage(data, mime: mime)
        if let path = (r.0 as? [String: String])?["path"] {
            images.append(path)
            updateHint()
        } else if let err = r.1 {
            hint?.stringValue = err
        }
    }

    private func submit() {
        guard let textView else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let imgs = images
        textView.string = ""
        images = []
        close()
        onSubmit?(text, imgs)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Enter arrives as insertNewline too: tell them apart by the event.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

/// A text view that turns a pasted image (a screenshot, or an image file copied in Finder) into
/// a saved file rather than inline rich text.
final class NoteTextView: NSTextView {
    var onImage: ((Data, String) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let exts = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let files = urls.filter { exts[$0.pathExtension.lowercased()] != nil }
            if !files.isEmpty {
                for f in files { if let d = try? Data(contentsOf: f) { onImage?(d, exts[f.pathExtension.lowercased()]!) } }
                return
            }
        }
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onImage?(png, "image/png")
            return
        }
        pasteAsPlainText(sender)
    }
}
