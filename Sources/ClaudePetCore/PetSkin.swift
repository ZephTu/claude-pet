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
    /// The five pictures the kit ships.
    public enum Pose: String, Sendable, Equatable, CaseIterable {
        case idle, working, waiting, sleeping, urgent
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

        public init(pose: Pose, lamp: Lamp) {
            self.pose = pose
            self.lamp = lamp
        }
    }

    /// - Parameters:
    ///   - mood: busy / waiting / urgent / idle, as `GlobalMood` spells them.
    ///   - phase: "compacting", "awaiting-agent", or empty.
    ///   - flash: "done", "trouble", or empty — a transient, not a state.
    ///   - wanted: something wants the user (the chest badge is non-empty).
    public static func look(mood: String, phase: String, flash: String,
                            wanted: Bool) -> Look {
        Look(pose: pose(mood: mood, wanted: wanted),
             lamp: lamp(mood: mood, phase: phase, flash: flash))
    }

    public static func pose(mood: String, wanted: Bool) -> Pose {
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
