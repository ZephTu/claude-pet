import Foundation
import WebKit
import ClaudePetCore

/// Pushes GlobalState into the page. Skips redundant pushes so a busy session
/// firing hooks every second does not restart the CSS animation every second.
///
/// Nothing is sent, and nothing is recorded, until the page says it is ready.
/// That gate is load-bearing: the first render happens inside
/// applicationDidFinishLaunching, long before loadFileURL finishes, so
/// `window.setMood` does not exist yet. Recording that push as "the last state
/// sent" made the dedup guard suppress every later push of the same state —
/// the pet stayed on the page's default `idle` until the global mood happened
/// to change on its own.
@MainActor
final class WebBridge {
    /// The user pressed × on a session row.
    var onMute: ((String) -> Void)?
    /// The session list just became visible.
    var onPanelOpened: (() -> Void)?

    private weak var webView: WKWebView?
    private var isReady = false
    private var last: GlobalState?
    private var lastSessionsPayload: String?
    private var lastHoverPoint: CGPoint?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// Call from the navigation delegate's didFinish, before re-rendering.
    /// Clearing the dedup memory here also covers a reload: the page is back at
    /// its defaults, so whatever we sent before must be sent again.
    func markReady() {
        isReady = true
        last = nil
        lastSessionsPayload = nil
    }

    func push(_ state: GlobalState) {
        guard isReady else { return }
        guard state != last else { return }
        last = state

        let project = state.waitingProject.map { "\"\(escape($0))\"" } ?? "null"
        let on = "\"\(escape(state.waitingOn))\""
        evaluate("window.setMood(\"\(state.mood.rawValue)\", \(project), \(on));")
    }

    /// Left click on the pet expands or collapses the session panel. Swift owns
    /// this because the host view now consumes every mouse event before the page
    /// can see it — see PetHostView.
    func togglePanel() {
        guard isReady, let webView else { return }
        webView.evaluateJavaScript("window.togglePanel();") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if result as? Bool == true { self?.onPanelOpened?() }
            }
        }
    }

    /// Resolve a left click: a session row we can jump to wins, anything else
    /// toggles the panel.
    ///
    /// The row lookup has to happen in the page, because row positions depend on
    /// content height and on the panel's own scroll offset. That makes this
    /// asynchronous, which is why the toggle lives in the callback rather than
    /// running first and being undone.
    func handleClick(at point: CGPoint) {
        guard isReady, let webView else { return }
        let js = "window.hitRow(\(point.x), \(point.y));"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    NSLog("ClaudePet: hitRow failed: \(error.localizedDescription)")
                    self.togglePanel()
                    return
                }
                guard let row = result as? [String: Any] else {
                    self.togglePanel()
                    return
                }
                switch row["action"] as? String {
                case "mute":
                    if let id = row["sessionId"] as? String, !id.isEmpty {
                        // The list stays open: muting several in a row is the
                        // common case, and reopening the panel each time is worse
                        // than leaving it up.
                        self.onMute?(id)
                    }
                case "jump":
                    guard
                        let kind = row["kind"] as? String,
                        let handle = row["handle"] as? String,
                        !handle.isEmpty
                    else {
                        self.togglePanel()
                        return
                    }
                    TerminalJump.jump(kind: kind, handle: handle)
                    // The list has served its purpose once we are jumping away.
                    self.evaluate("window.togglePanel();")
                default:
                    self.togglePanel()
                }
            }
        }
    }

    /// Show a line for `hold` seconds. Fire-and-forget: the page owns the timer,
    /// because a dropped call must not leave a bubble stuck on screen.
    func say(_ text: String, hold: TimeInterval) {
        guard isReady else { return }
        evaluate("window.say(\(jsString(text)), \(Int(hold * 1000)));")
    }

    /// Asks the page for the session name under this point, then hands it back.
    func rowTitle(at point: CGPoint, completion: @escaping @MainActor (String) -> Void) {
        guard isReady, let webView else { return completion("") }
        webView.evaluateJavaScript("window.rowTitle(\(point.x), \(point.y));") { result, _ in
            MainActor.assumeIsolated { completion(result as? String ?? "") }
        }
    }

    /// Draws the quota meters. Numbers go over as structured values, not as a
    /// formatted string, so the page can lay out bars and nothing has to be
    /// escaped.
    func showQuota(rows: [Chatter.QuotaRow], fallback: String) {
        guard isReady else { return }
        let items = rows.map { ["label": $0.label, "percent": $0.percent, "resetsIn": $0.resetsIn] }
        guard
            let data = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("window.showQuota(\(json), \(jsString(fallback)));")
    }

    func hush() {
        guard isReady else { return }
        evaluate("window.hush();")
    }

    /// Quota numbers and project names both end up inside a JS string literal.
    private func jsString(_ s: String) -> String {
        "\"\(escape(s))\""
    }

    /// Highlight the row under the pointer. Skips repeats so a stationary cursor
    /// under the 0.08s click-through poll costs nothing.
    func setHover(at point: CGPoint) {
        guard isReady, point != lastHoverPoint else { return }
        lastHoverPoint = point
        evaluate("window.setHoverAt(\(point.x), \(point.y));")
    }

    /// Project names come from directory names, so they can contain anything.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// handle → tab title, refreshed when the user opens the list.
    var titles: [String: String] = [:]

    func pushSessions(_ sessions: [SessionState], now: Date, hiddenCount: Int = 0) {
        guard isReady else { return }
        // Only rows that share a project with another need naming inline.
        let ambiguous = StateAggregator.ambiguousProjects(sessions)
        let items = sessions.map { s -> [String: Any] in
            var item: [String: Any] = [
                "sessionId": s.sessionId,
                "project": s.project,
                "state": s.state.rawValue,
                "tool": s.tool,
                // Notification message. Design doc section 2 puts it in the
                // expanded panel and keeps it out of the bubble.
                "detail": s.detail,
                "waitedSeconds": Int(max(0, now.timeIntervalSince(s.since))),
            ]
            // Only sessions we can actually jump to carry these, and only those
            // rows render as clickable.
            if let t = s.terminal, TerminalTarget.canJump(kind: t.kind) {
                item["termKind"] = t.kind
                item["termHandle"] = t.handle
                // The project column is just the directory name, so three
                // sessions in one repo all read the same. The tab title is what
                // tells them apart.
                if let title = titles[t.handle], !TerminalTitles.isUseless(title) {
                    item["title"] = title
                    // Shown inline, in place of the notification text, because
                    // knowing WHICH daily_work this is beats knowing it is
                    // waiting — the first column already said that.
                    if ambiguous.contains(s.project) { item["nameInline"] = true }
                }
            }
            return item
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let payload = "\(json)|\(hiddenCount)"
        guard payload != lastSessionsPayload else { return }
        lastSessionsPayload = payload
        evaluate("window.setSessions(\(json), \(hiddenCount));")
    }

    /// A nil completionHandler swallows JS errors silently, which is exactly how
    /// the startup bug above stayed invisible. Log instead.
    private func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("ClaudePet: JS push failed: \(error.localizedDescription)")
            }
        }
    }
}
