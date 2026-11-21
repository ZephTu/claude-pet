import Foundation

/// Which character the pet is drawn as.
///
/// Every skin draws the same nine poses (`CatSkin.Pose`), so a skin is only a
/// folder of pictures under `Resources/pet/skins/<id>/`: `assets/<pose>.png`
/// for the stills and, once its videos are cut, `frames/` for the animation.
/// The page picks the folder from `index.html?skin=<id>`; nothing else in the
/// app knows which skin is on.
public enum PetSkins {
    public struct Skin: Sendable, Equatable {
        /// The folder name under `skins/`, and what is stored in the defaults.
        public let id: String
        /// What the menu calls it.
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Every skin the app knows about, in menu order. A skin listed here whose
    /// pictures are not in the bundle yet is shown greyed out, not hidden: it
    /// says the skin is coming without pretending it can be picked.
    public static let all: [Skin] = [
        Skin(id: "cat", name: "Cat"),
        Skin(id: "cultivator", name: "散修"),
    ]

    /// The cat: the one skin every install is guaranteed to have.
    public static let defaultID = "cat"

    /// The still pictures a skin needs, relative to the pet resource folder.
    /// All nine or the skin is not offered: a skin missing a pose would show
    /// nothing at all the first time the pet entered it.
    public static func stills(for id: String) -> [String] {
        CatSkin.Pose.allCases.map { "skins/\(id)/assets/\($0.rawValue).png" }
    }

    /// Whether a skin has every still picture it needs.
    /// - Parameter hasFile: whether a path relative to the pet resource folder exists.
    public static func isComplete(_ id: String, hasFile: (String) -> Bool) -> Bool {
        isValidID(id) && stills(for: id).allSatisfy(hasFile)
    }

    /// The skin to show: the stored choice when it can still be drawn, the cat
    /// otherwise. A choice can stop being drawable — a build without that skin's
    /// pictures, a typo in the defaults — and the answer to that is the cat, not
    /// a blank window.
    public static func resolve(stored: String?, isComplete: (String) -> Bool) -> String {
        guard let stored, all.contains(where: { $0.id == stored }), isComplete(stored)
        else { return defaultID }
        return stored
    }

    /// A skin id goes into a URL and a file path, so it is held to the folder
    /// names the page itself accepts.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
