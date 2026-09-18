import AppKit
import ClaudePetCore
import WebKit

/// Renders the real pet page to a PNG, in a window configured exactly like the
/// real one, driven into whatever state you name.
///
/// This exists because the one thing no test in this project can check is
/// whether the drawing and the rectangles agree — the README says so, and the
/// mirrored-layout bug proved it: every test passed and the antenna was still
/// outside its hit region. A skin system doubles that surface, so the answer is
/// to make looking cheap.
///
/// `takeSnapshot` captures the page without the screen-recording permission
/// this app has no business asking for, and the page loads through the real
/// `pet://` handler, so a texture that would hang in production hangs here too.
///
///     ClaudePet --probe-skin index.html /tmp/cat.png 'window.setSkin("cat")'
@MainActor
enum SkinProbe {
    static func run(path: String, imagePath: String, script: String,
                    then finish: @escaping (Int32) -> Void) {
        guard
            let root = Bundle.module.url(forResource: "pet", withExtension: nil),
            let url = PetSchemeHandler.url(path: path)
        else {
            print("pet resources missing from the bundle")
            return finish(1)
        }
        let handler = PetSchemeHandler(root: root)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: PetSchemeHandler.scheme)

        let size = PetLayout.windowSize
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSPanel(contentRect: webView.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.contentView = webView
        // On screen, not parked off it: an occluded or off-screen window has its
        // requestAnimationFrame throttled, and a throttled render of an
        // animation is a render of nothing.
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()

        webView.load(URLRequest(url: url))
        // Held strongly for the duration; the handler is not owned by the view.
        retained = (handler, window, webView)

        after(2.5) {
            webView.evaluateJavaScript(script.isEmpty ? "null" : script) { result, error in
                MainActor.assumeIsolated {
                    if let error { print("script failed: \(error.localizedDescription)") }
                    // Printed so the script can answer questions as well as set
                    // things up. Without this the only way to find out why a
                    // render looked wrong was to guess and re-render.
                    if let result, !(result is NSNull) { print("\(result)") }
                    // Textures load asynchronously; a snapshot taken the instant
                    // the script returns catches the frame before the first one
                    // arrived, which looks exactly like a skin that is broken.
                    after(2.5) { snapshot(webView, to: imagePath, then: finish) }
                }
            }
        }
    }

    private nonisolated(unsafe) static var retained: (PetSchemeHandler, NSPanel, WKWebView)?

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { body() }
        }
    }

    private static func snapshot(_ webView: WKWebView, to path: String,
                                 then finish: @escaping (Int32) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, error in
            MainActor.assumeIsolated {
                guard
                    let image,
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let data = rep.representation(using: .png, properties: [:]),
                    (try? data.write(to: URL(fileURLWithPath: path))) != nil
                else {
                    print("snapshot failed: \(error?.localizedDescription ?? "no image")")
                    return finish(1)
                }
                finish(0)
            }
        }
    }
}
