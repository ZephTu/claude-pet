import ClaudePetCore
import Foundation

/// Reads `quotes.json`, the corpus behind the pet's one line a day.
///
/// Read once at launch and held: it is nine kilobytes, and re-reading it on
/// every five-second render to pick the same line again would be pure waste.
///
/// Every failure here ends at `Phrases.builtinQuotes` rather than at an empty
/// bubble. A missing or corrupt resource is a broken install, and the morning
/// somebody's install is broken is the worst possible morning to say nothing.
enum QuoteBook {
    /// Keyed by the same short codes the file uses.
    private static func code(_ language: Phrases.Language) -> String {
        switch language {
        case .english: return "en"
        case .chinese: return "zh"
        }
    }

    static func load(_ language: Phrases.Language, bundle: Bundle = .module) -> [String] {
        guard
            let root = bundle.url(forResource: "pet", withExtension: nil),
            let data = try? Data(contentsOf: root.appending(path: "quotes.json")),
            let byLanguage = try? JSONDecoder().decode([String: [String]].self, from: data),
            let lines = byLanguage[code(language)]
        else {
            return Phrases.builtinQuotes(language)
        }
        // A file that parsed but holds nothing for this language is the same
        // situation as no file at all.
        let usable = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return usable.isEmpty ? Phrases.builtinQuotes(language) : usable
    }
}
