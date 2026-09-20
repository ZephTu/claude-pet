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

    /// What a machine with nothing stored yet draws. The cat: it has a picture
    /// for nearly every state the pet has, and the robot's one advantage — a
    /// lamp that separates the busy states — stopped being an advantage when
    /// compaction, reading and waiting-on-an-agent got drawings of their own.
    ///
    /// Not the same thing as the WebGL fallback. If the cat cannot draw, the
    /// page reverts to the robot and says so (see `revertToRobot`); that path
    /// has to stay the robot whatever the default is, because the robot is the
    /// one that cannot fail.
    public static let standard: PetSkin = .cat

    /// Unknown values decode to the default rather than to nothing: a settings
    /// file written by a newer build must not leave the user with no pet.
    public static func named(_ raw: String?) -> PetSkin {
        PetSkin(rawValue: raw ?? "") ?? standard
    }
}

/// Pose and host-drawn glyph for the cat skin. Busy activity, compaction and
/// background-agent waiting now have distinct artwork. The host still owns
/// question/approval glyphs so their meaning is independent of the picture.
public enum CatSkin {
    public enum Pose: String, Sendable, Equatable, CaseIterable {
        case idle, working, waiting, sleeping, urgent, finished, reading, compacting
        case awaitingAgent = "awaiting-agent"
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
    ///   - phase: "compacting", "awaiting-agent", or empty.
    ///   - motion: the host's already-stabilized tool activity; reading gets a book.
    ///   - flash: "done", "trouble", or empty — a transient, not a state.
    ///   - wanted: something wants the user (the chest badge is non-empty).
    ///   - blockedOn: what a waiting session is blocked on, empty when it is
    ///     simply waiting for an answer. Only a PermissionRequest fills it in,
    ///     which is what makes it the honest way to tell "decide this" from
    ///     "answer me" — the alternative was reading English out of a
    ///     notification message.
    public static func look(mood: String, phase: String, flash: String,
                            wanted: Bool, blockedOn: String = "",
                            motion: ActivitySummary.Motion? = nil) -> Look {
        Look(pose: pose(mood: mood, wanted: wanted, flash: flash, phase: phase, motion: motion),
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

    public static func pose(mood: String, wanted: Bool, flash: String = "",
                            phase: String = "", motion: ActivitySummary.Motion? = nil) -> Pose {
        // Transients win; phases only select a pose inside busy, never waiting.
        if flash == "done" { return .finished }
        switch mood {
        case "busy":
            if phase == "compacting" { return .compacting }
            if phase == "awaiting-agent" { return .awaitingAgent }
            return motion == .reading ? .reading : .working
        case "waiting", "urgent": return mood == "urgent" ? .urgent : .waiting
        default:
            // The kit's two resting pictures earn their keep here: a session
            // that just finished is not the same thing as a desk nobody has
            // anything waiting on. Awake with something unread, asleep without.
            return wanted ? .idle : .sleeping
        }
    }
}
