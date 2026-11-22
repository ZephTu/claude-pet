import ClaudePetCore
import Foundation

/// The native UI follows the pet's language: the same calls say Chinese once it is
/// set to zh, and English again once it is set back. Every check is made inside a
/// zh window that is always closed, so the English assertions elsewhere keep holding.
enum LanguageTests {
    static func run(_ t: Harness) {
        print("\n-- language (native strings follow the pet's language)")

        setenv(UILanguage.environmentKey, "zh", 1)
        t.check("a health status says Chinese", HealthCheck.Status.ok.label == "正常")
        t.check("…every one of them", HealthCheck.Status.notConfigured.label == "未设置"
                && HealthCheck.Status.needsAttention.label == "需要处理")
        t.check("a health check's detail says Chinese",
                HealthReport.hooks(installed: 0, expected: 5, binaryExists: true).detail.contains("一个都没装"))
        t.check("skin names say Chinese", PetSkins.all.first?.name == "小猫")
        let note = Chatter.ContextNote(sessionId: "s", name: "api", tokens: 180_000)
        let line = Chatter.contextLine(note)
        t.check("the context reminder says Chinese, keeping /compact and the name",
                line.contains("可以 /compact 或开新会话") && line.hasPrefix("api"))
        let alarm = QuotaAlarm.Alarm(window: .sevenDay, threshold: 80, percent: 83, resetsIn: "2d 4h")
        t.check("the quota warning says Chinese", alarm.text.hasPrefix("每周额度已用 83%"))
        t.check("job validation says Chinese", Job(id: "j1", prompt: "p").problem() == "给任务起个名字。")
        t.check("durations keep their compact form", Chatter.duration(until: Date(timeIntervalSince1970: 3600),
                                                                      now: Date(timeIntervalSince1970: 0)) == "1h 0m")

        setenv(UILanguage.environmentKey, "en", 1)
        t.check("set back to en, the status says English again", HealthCheck.Status.ok.label == "OK")
        t.check("…and so do the skin names", PetSkins.all.first?.name == "Cat")
        t.check("…and the context reminder", Chatter.contextLine(note).contains("/compact or a new session saves quota"))
    }
}
