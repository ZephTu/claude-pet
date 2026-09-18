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
/// What is NOT lossy is the lamp. The lamp is the pet's one peripherally
/// readable signal ("you can read it without focusing on it") and the artwork
/// has nothing like it, so the host draws it above the canvas, in the same
/// place whichever skin is loaded. That is what keeps the cat honest: it loses
/// poses, not signals, and the two states with no picture still say so.
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

    /// A lamp token, not a colour. `pet.css` owns the palette, so the robot's
    /// bulb and the cat's lamp cannot drift apart into two greens.
    public enum Lamp: String, Sendable, Equatable, CaseIterable {
        case working
        case compacting
        case awaiting
        case waiting
        case urgent
        case done
        case trouble
        case off
    }

    public struct Look: Sendable, Equatable {
        public let pose: Pose
        public let lamp: Lamp
        public let mark: Mark

        public init(pose: Pose, lamp: Lamp, mark: Mark = .none) {
            self.pose = pose
            self.lamp = lamp
            self.mark = mark
        }
    }

    /// - Parameters:
    ///   - mood: busy / waiting / urgent / idle, as `GlobalMood` spells them.
    ///   - phase: "compacting", "awaiting-agent", or empty.
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
             lamp: lamp(mood: mood, phase: phase, flash: flash),
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

    public static func lamp(mood: String, phase: String, flash: String) -> Lamp {
        // A transient outranks the state it happens during. `done` especially:
        // a finished turn is the one thing this project exists to show, and it
        // is exactly one of the two states the artwork cannot draw. If the lamp
        // does not carry it, nothing does.
        switch flash {
        case "done": return .done
        case "trouble": return .trouble
        default: break
        }
        switch mood {
        case "urgent": return .urgent
        case "waiting": return .waiting
        case "busy":
            // The poses these three share are identical, so the lamp is the
            // only place the difference survives at all.
            switch phase {
            case "compacting": return .compacting
            case "awaiting-agent": return .awaiting
            default: return .working
            }
        default: return .off
        }
    }
}
