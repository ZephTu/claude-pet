import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the pet's own files under `pet://`, so the page and everything it
/// loads share one origin.
///
/// The page used to load over `file://`, where WebKit treats every file as its
/// own origin. That is fine for a stylesheet and a script, and fatal for a
/// texture: uploading an image from one file into a WebGL context created by
/// another throws a security error — from inside the image's `onload` handler,
/// where the loader's promise neither resolves nor rejects. The result is a pet
/// that never appears and never explains why. The spike hit exactly that: a
/// window with the lamp and the badge drawn and no cat.
///
/// One custom scheme removes the whole class of problem, and costs a page load
/// path that is a few lines longer.
final class PetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pet"
    /// The authority in `pet://app/index.html`. Anything else is refused, so a
    /// typo produces a 404 rather than a silent empty page.
    static let host = "app"

    private let root: URL
    /// Tasks WebKit has told us to stop. Replying to a stopped task is an
    /// exception, not a no-op, so this is not optional bookkeeping.
    private var cancelled = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        cancelled.remove(id)

        guard let url = task.request.url, url.host == Self.host else {
            return fail(task, id, "unexpected host")
        }
        // Percent-decoded and then re-checked against the root: a path with
        // `..` in it would otherwise read any file the app can reach.
        let relative = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            return fail(task, id, "outside the resource directory")
        }
        guard let data = try? Data(contentsOf: file) else {
            return fail(task, id, "no such file: \(relative)")
        }

        let response = URLResponse(url: url, mimeType: Self.mimeType(for: file),
                                   expectedContentLength: data.count, textEncodingName: nil)
        guard !cancelled.contains(id) else { return }
        task.didReceive(response)
        guard !cancelled.contains(id) else { return }
        task.didReceive(data)
        guard !cancelled.contains(id) else { return }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        cancelled.insert(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ why: String) {
        NSLog("ClaudePet: pet:// refused — \(why)")
        guard !cancelled.contains(id) else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    /// A wrong type here is not cosmetic: a `.js` served as `text/plain` does
    /// not execute, and the pet renders nothing.
    static func mimeType(for file: URL) -> String {
        if let type = UTType(filenameExtension: file.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    static func url(path: String) -> URL? {
        URL(string: "\(scheme)://\(host)/\(path)")
    }
}
