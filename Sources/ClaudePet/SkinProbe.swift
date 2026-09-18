import AppKit
import WebKit

/// A spike, not a feature: does WebGL run inside the pet's own WKWebView?
///
/// A second pet skin ships as five PNGs and a WebGL renderer that warps them.
/// Every other question about that feature — how states map, where the lamp
/// goes, how big the textures should be — is downstream of this one, and none
/// of it is worth planning if WebGL turns out to be unavailable or slow in a
/// borderless, non-opaque, floating panel.
///
/// The web view is configured exactly like the real one (`drawsBackground`
/// false above all) so the answer transfers. `takeSnapshot` captures the
/// rendered page without the screen-recording permission this app has no
/// business asking for.
///
/// Delete this file with the spike. It is not wired into the app.
@MainActor
enum SkinProbe {
    static func run(page: URL, imagePath: String, then finish: @escaping (Int32) -> Void) {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 180),
                                configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // Off-screen but in a real window: a web view with no window does not
        // get a compositor, and WebGL is exactly the thing that needs one.
        let window = NSPanel(contentRect: webView.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.contentView = webView
        // On screen, not parked off it: an occluded or off-screen window gets its
        // requestAnimationFrame throttled, and a throttled measurement of an
        // animation is a measurement of nothing.
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()

        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        report(webView: webView, imagePath: imagePath, window: window,
               deadline: Date().addingTimeInterval(12), then: finish)
    }

    private static func report(webView: WKWebView, imagePath: String, window: NSPanel,
                               deadline: Date, then finish: @escaping (Int32) -> Void) {
        let js = "JSON.stringify(window.__probe || {})"
        webView.evaluateJavaScript(js) { result, _ in
            MainActor.assumeIsolated {
                let text = result as? String ?? "{}"
                let done = text.contains("\"ready\":true")
                guard done || Date() >= deadline else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        MainActor.assumeIsolated {
                            report(webView: webView, imagePath: imagePath, window: window,
                                   deadline: deadline, then: finish)
                        }
                    }
                    return
                }
                print(text)
                snapshot(webView: webView, to: imagePath) { ok in
                    // Then hold, animating, so the CPU cost can be sampled from
                    // outside. It has to be sampled from outside: the page runs
                    // in a separate WebContent process, so the app's own CPU
                    // time does not include a single one of these frames — and
                    // `performance.now()` inside the page is coarsened enough
                    // that a frame's cost reads as exactly zero.
                    print("holding 20s — sample the WebContent process now")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                        MainActor.assumeIsolated {
                            window.orderOut(nil)
                            finish(ok && done ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    private static func snapshot(webView: WKWebView, to path: String,
                                 then finish: @escaping (Bool) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, error in
            MainActor.assumeIsolated {
                guard
                    let image,
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let data = rep.representation(using: .png, properties: [:])
                else {
                    print("snapshot failed: \(error?.localizedDescription ?? "no image")")
                    return finish(false)
                }
                finish((try? data.write(to: URL(fileURLWithPath: path))) != nil)
            }
        }
    }
}
