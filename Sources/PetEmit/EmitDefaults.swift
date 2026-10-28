import ClaudePetCore
import Foundation

/// LOCAL PATCH: pet-emit's own defaults — what it does when config.json says
/// nothing usable about a switch (no file, an unreadable file, a missing key, a
/// value that is not a JSON boolean). The file only overrides these, and this
/// is the one place they are defined: the app asks `pet-emit --config` instead
/// of keeping a copy.
enum EmitDefaults {
    /// Upstream behaviour: every finished tool call is recorded.
    static let recordActivity = true
}

/// The switches as pet-emit acts on them: the defaults above, overridden by
/// whatever config.json explicitly says.
enum EffectiveConfig {
    static func recordActivity(petHome: URL) -> Bool {
        PetConfig.load(petHome: petHome).recordActivity ?? EmitDefaults.recordActivity
    }

    /// What `pet-emit --config` prints.
    static func json(petHome: URL) -> Data {
        let object: [String: Any] = [PetConfig.recordActivityKey: recordActivity(petHome: petHome)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }
}
