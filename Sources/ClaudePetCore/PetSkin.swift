import Foundation

/// Which figure the pet draws.
///
/// The robot is an SVG whose every state is a CSS rule. A skin made of painted
/// artwork cannot work that way — it has as many states as it has pictures —
/// so a second skin is not a re-skin of the first, it is a lossy projection of
/// the pet's state onto however many pictures exist.
public enum PetSkin: String, Sendable, Equatable, CaseIterable {
    case robot
    case cat

    public var displayName: String {
        switch self {
        case .robot: return "Robot"
        case .cat: return "Cat"
        }
    }

    /// Unknown values decode to the robot rather than to nothing: a settings
    /// file written by a newer build must not leave the user with no pet.
    public static func named(_ raw: String?) -> PetSkin {
        PetSkin(rawValue: raw ?? "") ?? .robot
    }
}

/// What the cat skin draws for a given pet state.
///
/// The cat has five pictures against the pet's eleven states, so the pose is
/// lossy by construction: three different busy poses, compaction and waiting on
/// a background agent all become one picture of a cat at a laptop. Two of the
/// eleven — a finished turn and an interrupted tool — have no picture at all.
///
/// The cat has no lamp. It had one — a host-drawn dot above the canvas, in the
/// robot's own colours — and it was taken out on purpose: a coloured disc
/// sitting on top of painted artwork reads as a sticker stuck to the cat, not
/// as part of it.
///
/// What that costs, exactly: the three busy states (working, compacting,
/// waiting on a background agent) are one picture now and nothing tells them
/// apart. Everything else survives in the artwork itself — a raised paw plus a
/// glyph for the two kinds of waiting, the kit's own painted alarm for being
/// ignored, a bob of the idle picture for a finished turn, and a warning glyph
/// over a working cat for an interrupted tool. The robot keeps its bulb, so a
/// user who needs the busy states told apart has a skin that tells them.
public enum CatSkin {
    /// The five pictures the kit ships, plus one the renderer makes from an
    /// existing picture.
    public enum Pose: String, Sendable, Equatable, CaseIterable {
        case idle, working, waiting, sleeping, urgent
        /// The `idle` picture with a short bob, for the 1.6s after a turn ends.
        /// Not a sixth texture — there is no artwork for a finished turn, and a
        /// still picture cannot say "just now" anyway. See cat-pet.js.
        case finished
    }

    /// A glyph the host draws beside the figure.
    ///
    /// These used to be painted into the textures, which is how the cat ended
    /// up holding up a paw with a QUESTION MARK over it while asking for
    /// permission to run `rm -rf` — a question mark means "I am unsure", and
    /// approval means "you decide". The artwork could not tell them apart
    /// because one picture was doing both jobs.
    ///
    /// Drawn by the host instead, so one "raised paw" picture serves both, and
    /// so a new glyph never costs a new drawing of the whole cat.
    public enum Mark: String, Sendable, Equatable, CaseIterable {
        case none
        /// It wants you to type something.
        case question
        /// It wants a decision, or a tool call came back interrupted. One glyph
        /// for both, exactly as the robot does it — its monitor shows the same
        /// warning in both cases, and the POSE is what tells them apart.
        case warn
    }

    public struct Look: Sendable, Equatable {
        public let pose: Pose
        public let mark: Mark

        public init(pose: Pose, mark: Mark = .none) {
            self.pose = pose
            self.mark = mark
        }
    }

    /// - Parameters:
    ///   - mood: busy / waiting / urgent / idle, as `GlobalMood` spells them.
    ///   - phase: "compacting", "awaiting-agent", or empty. Unused: it is the
    ///     one thing the cat cannot draw, and the lamp that used to carry it is
    ///     gone. Kept in the signature because the caller has it and a skin with
    ///     more pictures would need it.
    ///   - flash: "done", "trouble", or empty — a transient, not a state.
    ///   - wanted: something wants the user (the chest badge is non-empty).
    ///   - blockedOn: what a waiting session is blocked on, empty when it is
    ///     simply waiting for an answer. Only a PermissionRequest fills it in,
    ///     which is what makes it the honest way to tell "decide this" from
    ///     "answer me" — the alternative was reading English out of a
    ///     notification message.
    public static func look(mood: String, phase: String, flash: String,
                            wanted: Bool, blockedOn: String = "") -> Look {
        Look(pose: pose(mood: mood, wanted: wanted, flash: flash),
             mark: mark(mood: mood, flash: flash, blockedOn: blockedOn))
    }

    /// The pose a transient imposes, or nil to keep whatever is showing.
    ///
    /// A finished turn replaces the pose, because that IS the whole signal. An
    /// interrupted tool must not: the session is still working, and swapping
    /// the picture would say it stopped.
    public static func flashPose(_ flash: String) -> Pose? {
        flash == "done" ? .finished : nil
    }

    public static func mark(mood: String, flash: String, blockedOn: String) -> Mark {
        // An interrupted call is a warning over a cat that is still working.
        if flash == "trouble" { return .warn }
        // `urgent` already has its own painted alarm, and a second glyph beside
        // it would be two warnings for one thing.
        guard mood == "waiting" else { return .none }
        return blockedOn.isEmpty ? .question : .warn
    }

    public static func pose(mood: String, wanted: Bool, flash: String = "") -> Pose {
        // A turn ending is a moment, not a state, and the artwork has no
        // picture for it. The renderer bobs the idle picture instead — which
        // beats the alternative, which was nothing at all.
        if flash == "done" { return .finished }
        switch mood {
        case "busy": return .working
        case "waiting", "urgent": return mood == "urgent" ? .urgent : .waiting
        default:
            // The kit's two resting pictures earn their keep here: a session
            // that just finished is not the same thing as a desk nobody has
            // anything waiting on. Awake with something unread, asleep without.
            return wanted ? .idle : .sleeping
        }
    }
}
