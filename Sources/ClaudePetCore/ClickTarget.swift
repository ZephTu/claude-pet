import Foundation

/// Where a click on a session in the pet goes — a finish notice above the pet, a row in its
/// list, the jump-to-waiting shortcut. Settings → "Clicking a Session Opens", in the pet's
/// menu and on the board.
///
/// `terminal` (the default) brings back the tab the session runs in. `board` opens the Task
/// Board at the task the session is bound to — in Focus when it is there, in All otherwise —
/// for working from the board instead of the terminal. A session bound to no task has nothing
/// to show on the board, so it still goes to its terminal.
public enum ClickTarget: String, Sendable, CaseIterable {
    case terminal
    case board

    /// The UserDefaults key the choice is kept under.
    public static let key = "clickTarget"

    /// What is stored, or the default for nothing (or anything unknown) stored.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .terminal
    }

    public enum Route: Sendable, Equatable {
        /// Open the board at this task (an id such as "T-062").
        case board(task: String)
        /// Bring back the session's terminal tab.
        case terminal
        /// Neither: no task to show, and no terminal that can be addressed.
        case nowhere
    }

    /// - Parameters:
    ///   - task: the session's task as HQ labels it ("T-062 Claude-pet Dashboard"), nil for none.
    ///   - canJump: whether its terminal can be brought back.
    public func route(task: String?, canJump: Bool) -> Route {
        if self == .board, let id = Self.taskID(task) { return .board(task: id) }
        return canJump ? .terminal : .nowhere
    }

    /// "T-062 Claude-pet Dashboard" → "T-062". Nil for anything that does not start with an id.
    public static func taskID(_ label: String?) -> String? {
        guard let label else { return nil }
        let id = String(label.prefix { !$0.isWhitespace })
        return id.range(of: #"^T-\d+$"#, options: .regularExpression) != nil ? id : nil
    }
}
