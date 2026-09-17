import AppKit

/// Right-click menu: pause, launch at login, unmute, quit.
final class PetMenu: NSObject, NSMenuDelegate {
    private let onPauseToggle: () -> Void
    private let onShortcutToggle: () -> Void
    private let onShowHealth: () -> Void
    private let onDemoToggle: () -> Void
    private let onReduceMotionToggle: () -> Void
    private let onLoginToggle: () -> Void
    private let onUnmuteAll: () -> Void
    private let onQuit: () -> Void

    init(
        onPauseToggle: @escaping () -> Void,
        onLoginToggle: @escaping () -> Void,
        onUnmuteAll: @escaping () -> Void,
        onShortcutToggle: @escaping () -> Void,
        onShowHealth: @escaping () -> Void,
        onDemoToggle: @escaping () -> Void,
        onReduceMotionToggle: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onPauseToggle = onPauseToggle
        self.onShortcutToggle = onShortcutToggle
        self.onShowHealth = onShowHealth
        self.onDemoToggle = onDemoToggle
        self.onReduceMotionToggle = onReduceMotionToggle
        self.onLoginToggle = onLoginToggle
        self.onUnmuteAll = onUnmuteAll
        self.onQuit = onQuit
    }

    func show(
        at point: NSPoint, in view: NSView,
        paused: Bool, launchesAtLogin: Bool, mutedCount: Int, shortcutOn: Bool = false,
        demoOn: Bool = false, reduceMotionOn: Bool = false
    ) {
        let menu = makeMenu(
            paused: paused, launchesAtLogin: launchesAtLogin, mutedCount: mutedCount,
            shortcutOn: shortcutOn, demoOn: demoOn, reduceMotionOn: reduceMotionOn
        )
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Built separately from popUp so the menu's contents can be inspected
    /// without running a modal tracking loop.
    func makeMenu(paused: Bool, launchesAtLogin: Bool, mutedCount: Int = 0,
                  shortcutOn: Bool = false, demoOn: Bool = false,
                  reduceMotionOn: Bool = false) -> NSMenu {
        let menu = NSMenu()

        let pause = NSMenuItem(
            title: paused ? "Wake Up" : "Take a Nap",
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin ? .on : .off
        menu.addItem(login)

        // Only when there is something to undo — a permanently greyed-out item
        // is just noise in a four-item menu.
        if mutedCount > 0 {
            let unmute = NSMenuItem(
                title: "Unmute All (\(mutedCount))",
                action: #selector(unmuteAll), keyEquivalent: ""
            )
            unmute.target = self
            menu.addItem(unmute)
        }

        menu.addItem(.separator())

        let calm = NSMenuItem(title: "Reduce Motion", action: #selector(toggleReduceMotion),
                              keyEquivalent: "")
        calm.state = reduceMotionOn ? .on : .off
        calm.target = self
        menu.addItem(calm)

        let health = NSMenuItem(title: "Connection Status…", action: #selector(showHealth),
                                keyEquivalent: "")
        health.target = self
        menu.addItem(health)

        let demo = NSMenuItem(title: demoOn ? "Stop Demo" : "Demo the States…",
                              action: #selector(toggleDemo), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)
        menu.addItem(.separator())

        let shortcut = NSMenuItem(
            title: "Jump to Waiting Session (\(HotKey.displayName))",
            action: #selector(toggleShortcut), keyEquivalent: "")
        shortcut.state = shortcutOn ? .on : .off
        shortcut.target = self
        menu.addItem(shortcut)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func togglePause() { onPauseToggle() }
    @objc private func toggleLogin() { onLoginToggle() }
    @objc private func unmuteAll() { onUnmuteAll() }
    @objc private func toggleShortcut() { onShortcutToggle() }
    @objc private func showHealth() { onShowHealth() }
    @objc private func toggleDemo() { onDemoToggle() }
    @objc private func toggleReduceMotion() { onReduceMotionToggle() }
    @objc private func quit() { onQuit() }
}
