import Foundation

/// The single mood the pet displays, distilled from every live session.
public enum GlobalMood: String, Sendable, Equatable {
    case idle
    case busy
    case waiting
    case urgent
}

/// Everything the pet's front end needs to render one frame.
public struct GlobalState: Sendable, Equatable {
    public let mood: GlobalMood
    /// Live sessions only, grouped waiting > busy > idle, and oldest `since`
    /// first inside each group — see StateAggregator.ordered(_:).
    public let sessions: [SessionState]
    /// Project name for the urgent speech bubble; nil unless something is waiting.
    public let waitingProject: String?
    /// What that session is waiting for approval on, when it told us. Shown next
    /// to the project name so the bubble answers "should I go look?" by itself.
    public let waitingOn: String
    /// How many live sessions the user has muted. Shown as a footer line in the
    /// panel so muting something is never a thing the user silently forgets.
    public let hiddenCount: Int

    public init(
        mood: GlobalMood,
        sessions: [SessionState],
        waitingProject: String?,
        hiddenCount: Int = 0,
        waitingOn: String = ""
    ) {
        self.mood = mood
        self.sessions = sessions
        self.waitingProject = waitingProject
        self.hiddenCount = hiddenCount
        self.waitingOn = waitingOn
    }
}
