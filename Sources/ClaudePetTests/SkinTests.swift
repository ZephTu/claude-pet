import ClaudePetCore
import Foundation

/// Skins: which ones can be picked, and what is shown when the stored one cannot.
enum SkinTests {
    static func run(_ t: Harness) {
        print("\n-- skins")
        let all = Set(PetSkins.stills(for: "cat"))

        t.check("a skin needs one still per pose", PetSkins.stills(for: "cat").count == CatSkin.Pose.allCases.count)
        t.check("stills live under the skin's own folder",
                PetSkins.stills(for: "cultivator").allSatisfy { $0.hasPrefix("skins/cultivator/assets/") })
        t.check("a skin with every still is complete", PetSkins.isComplete("cat") { all.contains($0) })
        t.check("a skin missing one pose is not",
                !PetSkins.isComplete("cat") { all.contains($0) && !$0.hasSuffix("/urgent.png") })
        t.check("a skin with no pictures is not", !PetSkins.isComplete("cultivator") { all.contains($0) })
        t.check("an id that could escape a path is never complete", !PetSkins.isComplete("../cat") { _ in true })

        let onlyCat: (String) -> Bool = { $0 == "cat" }
        let both: (String) -> Bool = { _ in true }
        t.check("nothing stored is the cat", PetSkins.resolve(stored: nil, isComplete: both) == "cat")
        t.check("a stored skin that can be drawn is kept",
                PetSkins.resolve(stored: "cultivator", isComplete: both) == "cultivator")
        t.check("a stored skin without its pictures falls back to the cat",
                PetSkins.resolve(stored: "cultivator", isComplete: onlyCat) == "cat")
        t.check("a stored id nobody knows falls back to the cat",
                PetSkins.resolve(stored: "dragon", isComplete: both) == "cat")
        t.check("the default is a known skin", PetSkins.all.contains { $0.id == PetSkins.defaultID })
        t.check("every known id is a safe folder name", PetSkins.all.allSatisfy { PetSkins.isValidID($0.id) })
        t.check("ids are unique", Set(PetSkins.all.map(\.id)).count == PetSkins.all.count)

        // The real bundle: the cat must ship whole, or every install that falls
        // back to it shows nothing.
        let pet = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pet")
        t.check("the cat ships every still picture", PetSkins.isComplete("cat") {
            FileManager.default.fileExists(atPath: pet.appendingPathComponent($0).path)
        })
    }
}
