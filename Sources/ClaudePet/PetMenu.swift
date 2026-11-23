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
    private let onNoteShortcutToggle: (() -> Void)?
    private let onQuickNote: (() -> Void)?
    private let onShowHealth: () -> Void
    private let onKeepListOpenToggle: () -> Void
    private let onLoginToggle: () -> Void
    private let onNoticeHold: (TimeInterval) -> Void
    private let onNoticeCount: (Int) -> Void
    private let onUnmuteAll: () -> Void
    private let onQuit: () -> Void
    private let onShowBoard: (() -> Void)?
    private let onSkin: ((String) -> Void)?
    private let onLanguage: ((String) -> Void)?

    init(
        onPauseToggle: @escaping () -> Void,
        onLoginToggle: @escaping () -> Void,
        onUnmuteAll: @escaping () -> Void,
        onShortcutToggle: @escaping () -> Void,
        onShowHealth: @escaping () -> Void,
        onKeepListOpenToggle: @escaping () -> Void,
        onNoticeHold: @escaping (TimeInterval) -> Void,
        onNoticeCount: @escaping (Int) -> Void,
        onQuit: @escaping () -> Void,
        onShowBoard: (() -> Void)? = nil,
        onSkin: ((String) -> Void)? = nil,
        onLanguage: ((String) -> Void)? = nil,
        onQuickNote: (() -> Void)? = nil,
        onNoteShortcutToggle: (() -> Void)? = nil
    ) {
        self.onQuickNote = onQuickNote
        self.onNoteShortcutToggle = onNoteShortcutToggle
        self.onLanguage = onLanguage
        self.onShowBoard = onShowBoard
        self.onSkin = onSkin
        self.onNoticeHold = onNoticeHold
        self.onNoticeCount = onNoticeCount
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
        noteShortcutOn: Bool = false, keepListOpenOn: Bool = false, problem: HealthCheck? = nil,
        noticeHold: TimeInterval = Chatter.noticeHold, noticeCount: Int = Chatter.noticeCount,
        skin: String = PetSkins.defaultID, canShowSkin: (String) -> Bool = { _ in true },
        language: String = "auto"
    ) {
        let menu = makeMenu(
            paused: paused, launchesAtLogin: launchesAtLogin, mutedCount: mutedCount,
            shortcutOn: shortcutOn, noteShortcutOn: noteShortcutOn, keepListOpenOn: keepListOpenOn, problem: problem,
            noticeHold: noticeHold, noticeCount: noticeCount,
            skin: skin, canShowSkin: canShowSkin, language: language
        )
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Built separately from popUp so the menu's contents can be inspected
    /// without running a modal tracking loop.
    /// - Parameter problem: the first thing found wrong with the install, or nil
    ///   when nothing is — which is when the connection report is left out.
    func makeMenu(paused: Bool, launchesAtLogin: Bool, mutedCount: Int = 0,
                  shortcutOn: Bool = false, noteShortcutOn: Bool = false, keepListOpenOn: Bool = false,
                  problem: HealthCheck? = nil,
                  noticeHold: TimeInterval = Chatter.noticeHold,
                  noticeCount: Int = Chatter.noticeCount,
                  skin: String = PetSkins.defaultID,
                  canShowSkin: (String) -> Bool = { _ in true },
                  language: String = "auto") -> NSMenu {
        let menu = NSMenu()

        if let problem {
            let health = NSMenuItem(title: L("⚠ \(problem.name): \(problem.status.label)…", "⚠ \(problem.name)：\(problem.status.label)…"),
                                    action: #selector(showHealth), keyEquivalent: "")
            health.target = self
            menu.addItem(health)
            menu.addItem(.separator())
        }

        if onShowBoard != nil {
            let board = NSMenuItem(title: L("Task Board…", "任务看板…"), action: #selector(showBoard), keyEquivalent: "")
            board.target = self
            menu.addItem(board)
            if onQuickNote != nil {
                let note = NSMenuItem(title: L("Quick Note…", "记一笔…"), action: #selector(quickNote), keyEquivalent: "")
                note.target = self
                menu.addItem(note)
            }
            menu.addItem(.separator())
        }

        let pause = NSMenuItem(
            title: paused ? L("Wake Up", "醒来") : L("Take a Nap", "小睡一会"),
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let keepOpen = NSMenuItem(title: L("Keep List Open", "保持列表展开"), action: #selector(toggleKeepListOpen),
                                  keyEquivalent: "")
        keepOpen.state = keepListOpenOn ? .on : .off
        keepOpen.target = self
        menu.addItem(keepOpen)

        // Only when there is something to undo — a permanently greyed-out item
        // is just noise in a short menu.
        if mutedCount > 0 {
            let unmute = NSMenuItem(
                title: L("Unmute All (\(mutedCount))", "取消所有静音 (\(mutedCount))"),
                action: #selector(unmuteAll), keyEquivalent: ""
            )
            unmute.target = self
            menu.addItem(unmute)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings", "设置"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let login = NSMenuItem(title: L("Launch at Login", "登录时启动"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin ? .on : .off
        options.addItem(login)
        let shortcut = NSMenuItem(
            title: L("Jump to Waiting Session (\(HotKey.displayName))", "跳到等待中的 session (\(HotKey.displayName))"),
            action: #selector(toggleShortcut), keyEquivalent: "")
        shortcut.state = shortcutOn ? .on : .off
        shortcut.target = self
        options.addItem(shortcut)
        if onNoteShortcutToggle != nil {
            let noteKey = NSMenuItem(
                title: L("Quick Note (\(HotKey.noteDisplayName))", "记一笔 (\(HotKey.noteDisplayName))"),
                action: #selector(toggleNoteShortcut), keyEquivalent: "")
            noteKey.state = noteShortcutOn ? .on : .off
            noteKey.target = self
            options.addItem(noteKey)
        }
        options.addItem(.separator())

        // The "this session finished" bubbles above the pet.
        let hold = NSMenuItem(title: L("Bubble Duration", "气泡停留时间"), action: nil, keyEquivalent: "")
        let holds = NSMenu()
        for seconds in Chatter.noticeHoldChoices {
            let item = NSMenuItem(title: L("\(Int(seconds)) seconds", "\(Int(seconds)) 秒"), action: #selector(pickHold(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == noticeHold ? .on : .off
            holds.addItem(item)
        }
        hold.submenu = holds
        options.addItem(hold)
        let count = NSMenuItem(title: L("Bubbles at Once", "同时显示的气泡数"), action: nil, keyEquivalent: "")
        let counts = NSMenu()
        for n in Chatter.noticeCountChoices {
            let item = NSMenuItem(title: "\(n)", action: #selector(pickCount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n
            item.state = n == noticeCount ? .on : .off
            counts.addItem(item)
        }
        count.submenu = counts
        options.addItem(count)
        options.addItem(.separator())

        // Who the pet is drawn as. A skin whose pictures are not in this build
        // yet is listed greyed out: no action, so AppKit disables it.
        if onSkin != nil {
            let character = NSMenuItem(title: L("Character", "角色"), action: nil, keyEquivalent: "")
            let skins = NSMenu()
            for option in PetSkins.all {
                let ready = canShowSkin(option.id)
                let item = NSMenuItem(title: ready ? option.name : L("\(option.name) (no artwork yet)", "\(option.name)（还没有图）"),
                                      action: ready ? #selector(pickSkin(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.representedObject = option.id
                item.state = option.id == skin ? .on : .off
                skins.addItem(item)
            }
            character.submenu = skins
            options.addItem(character)
            options.addItem(.separator())
        }
        // Named in both languages, so it can be found whichever one is showing.
        if onLanguage != nil {
            let lang = NSMenuItem(title: "Language · 语言", action: nil, keyEquivalent: "")
            let langs = NSMenu()
            for choice in UILanguage.choices {
                let item = NSMenuItem(title: choice.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.id
                item.state = choice.id == language ? .on : .off
                langs.addItem(item)
            }
            lang.submenu = langs
            options.addItem(lang)
            options.addItem(.separator())
        }
        let health = NSMenuItem(title: L("Connection Status…", "连接状态…"), action: #selector(showHealth),
                                keyEquivalent: "")
        health.target = self
        options.addItem(health)
        settings.submenu = options
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit", "退出"), action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func togglePause() { onPauseToggle() }
    @objc private func toggleLogin() { onLoginToggle() }
    @objc private func unmuteAll() { onUnmuteAll() }
    @objc private func toggleShortcut() { onShortcutToggle() }
    @objc private func toggleNoteShortcut() { onNoteShortcutToggle?() }
    @objc private func quickNote() { onQuickNote?() }
    @objc private func showHealth() { onShowHealth() }
    @objc private func toggleKeepListOpen() { onKeepListOpenToggle() }
    @objc private func pickHold(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? TimeInterval { onNoticeHold(seconds) }
    }
    @objc private func pickCount(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? Int { onNoticeCount(n) }
    }
    @objc private func pickSkin(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onSkin?(id) }
    }
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onLanguage?(id) }
    }
    @objc private func quit() { onQuit() }
    @objc private func showBoard() { onShowBoard?() }
}
