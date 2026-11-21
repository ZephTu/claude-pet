import Foundation

/// The language Claude Pet's own words are shown in: English or Chinese.
///
/// Picked under Settings → Language in the pet's menu, or left to follow the system. The menus
/// and windows read it through `L(_:_:)`; the web pages (the pet's list, the Task Board, its
/// guide) get it as `window.PET_LANG` before their scripts run, and reload when it changes.
/// Technical terms — session, todo, ask, Claude Code's own words — may stay English in Chinese.
public enum UILanguage {
    /// UserDefaults key: "en", "zh", or absent / "auto" to follow the system.
    public static let key = "uiLanguage"
    /// Set to "en" or "zh" to override everything — for `--render-board` and tests.
    public static let environmentKey = "CLAUDE_PET_LANG"
    public static let choices: [(id: String, name: String)] = [("auto", "Follow System · 跟随系统"),
                                                              ("en", "English"), ("zh", "中文")]

    /// "en" or "zh", from what was stored and the system's preferred languages.
    public static func resolve(stored: String?, preferred: [String], environment: String? = nil) -> String {
        if let e = environment, e == "en" || e == "zh" { return e }
        if stored == "en" || stored == "zh" { return stored! }
        for p in preferred {
            let l = p.lowercased()
            if l.hasPrefix("zh") { return "zh" }
            if l.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    /// What is stored: "en", "zh" or "auto".
    public static var stored: String {
        let s = UserDefaults.standard.string(forKey: key)
        return s == "en" || s == "zh" ? s! : "auto"
    }

    public static var current: String {
        resolve(stored: UserDefaults.standard.string(forKey: key), preferred: Locale.preferredLanguages,
                environment: ProcessInfo.processInfo.environment[environmentKey])
    }

    public static var isChinese: Bool { current == "zh" }

    /// The script the web pages get before anything else runs.
    public static var pageScript: String {
        let lang = current
        return "window.PET_LANG = \"\(lang)\"; document.documentElement.lang = \"\(lang)\";"
    }
}

/// `en` or `zh`, whichever the pet is set to show.
public func L(_ en: String, _ zh: String) -> String { UILanguage.isChinese ? zh : en }
