import AppKit

/// Right-click menu: pause, launch at login, unmute, quit.
final class PetMenu: NSObject, NSMenuDelegate {
    private let onPauseToggle: () -> Void
    private let onLoginToggle: () -> Void
    private let onUnmuteAll: () -> Void
    private let onQuit: () -> Void

    init(
        onPauseToggle: @escaping () -> Void,
        onLoginToggle: @escaping () -> Void,
        onUnmuteAll: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onPauseToggle = onPauseToggle
        self.onLoginToggle = onLoginToggle
        self.onUnmuteAll = onUnmuteAll
        self.onQuit = onQuit
    }

    func show(
        at point: NSPoint, in view: NSView,
        paused: Bool, launchesAtLogin: Bool, mutedCount: Int
    ) {
        let menu = makeMenu(
            paused: paused, launchesAtLogin: launchesAtLogin, mutedCount: mutedCount
        )
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Built separately from popUp so the menu's contents can be inspected
    /// without running a modal tracking loop.
    func makeMenu(paused: Bool, launchesAtLogin: Bool, mutedCount: Int = 0) -> NSMenu {
        let menu = NSMenu()

        let pause = NSMenuItem(
            title: paused ? "唤醒宠物" : "让宠物睡一会",
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin ? .on : .off
        menu.addItem(login)

        // Only when there is something to undo — a permanently greyed-out item
        // is just noise in a four-item menu.
        if mutedCount > 0 {
            let unmute = NSMenuItem(
                title: "取消静音（\(mutedCount) 个）",
                action: #selector(unmuteAll), keyEquivalent: ""
            )
            unmute.target = self
            menu.addItem(unmute)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func togglePause() { onPauseToggle() }
    @objc private func toggleLogin() { onLoginToggle() }
    @objc private func unmuteAll() { onUnmuteAll() }
    @objc private func quit() { onQuit() }
}
