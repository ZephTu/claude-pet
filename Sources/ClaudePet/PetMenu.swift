import AppKit
import ClaudePetCore

/// Right-click menu on the pet itself.
///
/// The first level holds only what gets reached for during a day: nap, keep
/// the list open, unmute, quit. Things set once live under Settings, and the
/// connection report appears only while something is actually wrong — a
/// diagnostic that is always there is one nobody opens when it matters.
final class PetMenu: NSObject, NSMenuDelegate {
    private let onPauseToggle: () -> Void
    private let onShortcutToggle: () -> Void
    private let onShowHealth: () -> Void
    private let onKeepListOpenToggle: () -> Void
    private let onLoginToggle: () -> Void
    private let onUnmuteAll: () -> Void
    private let onQuit: () -> Void

    init(
        onPauseToggle: @escaping () -> Void,
        onLoginToggle: @escaping () -> Void,
        onUnmuteAll: @escaping () -> Void,
        onShortcutToggle: @escaping () -> Void,
        onShowHealth: @escaping () -> Void,
        onKeepListOpenToggle: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onPauseToggle = onPauseToggle
        self.onShortcutToggle = onShortcutToggle
        self.onShowHealth = onShowHealth
        self.onKeepListOpenToggle = onKeepListOpenToggle
        self.onLoginToggle = onLoginToggle
        self.onUnmuteAll = onUnmuteAll
        self.onQuit = onQuit
    }

    func show(
        at point: NSPoint, in view: NSView,
        paused: Bool, launchesAtLogin: Bool, mutedCount: Int, shortcutOn: Bool = false,
        keepListOpenOn: Bool = false, problem: HealthCheck? = nil
    ) {
        let menu = makeMenu(
            paused: paused, launchesAtLogin: launchesAtLogin, mutedCount: mutedCount,
            shortcutOn: shortcutOn, keepListOpenOn: keepListOpenOn, problem: problem
        )
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Built separately from popUp so the menu's contents can be inspected
    /// without running a modal tracking loop.
    /// - Parameter problem: the first thing found wrong with the install, or nil
    ///   when nothing is — which is when the connection report is left out.
    func makeMenu(paused: Bool, launchesAtLogin: Bool, mutedCount: Int = 0,
                  shortcutOn: Bool = false, keepListOpenOn: Bool = false,
                  problem: HealthCheck? = nil) -> NSMenu {
        let menu = NSMenu()

        if let problem {
            let health = NSMenuItem(title: "⚠ \(problem.name): \(problem.status.label)…",
                                    action: #selector(showHealth), keyEquivalent: "")
            health.target = self
            menu.addItem(health)
            menu.addItem(.separator())
        }

        let pause = NSMenuItem(
            title: paused ? "Wake Up" : "Take a Nap",
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let keepOpen = NSMenuItem(title: "Keep List Open", action: #selector(toggleKeepListOpen),
                                  keyEquivalent: "")
        keepOpen.state = keepListOpenOn ? .on : .off
        keepOpen.target = self
        menu.addItem(keepOpen)

        // Only when there is something to undo — a permanently greyed-out item
        // is just noise in a short menu.
        if mutedCount > 0 {
            let unmute = NSMenuItem(
                title: "Unmute All (\(mutedCount))",
                action: #selector(unmuteAll), keyEquivalent: ""
            )
            unmute.target = self
            menu.addItem(unmute)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let options = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin ? .on : .off
        options.addItem(login)
        let shortcut = NSMenuItem(
            title: "Jump to Waiting Session (\(HotKey.displayName))",
            action: #selector(toggleShortcut), keyEquivalent: "")
        shortcut.state = shortcutOn ? .on : .off
        shortcut.target = self
        options.addItem(shortcut)
        options.addItem(.separator())
        let health = NSMenuItem(title: "Connection Status…", action: #selector(showHealth),
                                keyEquivalent: "")
        health.target = self
        options.addItem(health)
        settings.submenu = options
        menu.addItem(settings)

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
    @objc private func toggleKeepListOpen() { onKeepListOpenToggle() }
    @objc private func quit() { onQuit() }
}
