import Foundation

/// The pure parts of answering, from the board, a prompt a session has up in its terminal: a
/// question menu (AskUserQuestion) or a plan to approve (ExitPlanMode). See BoardBridge.
public enum BoardPrompt {
    /// A key the board presses in a session's terminal, as the byte the terminal sends for it.
    public enum Key: Int, Sendable {
        /// Interrupts a turn (`BoardSend.mayInterrupt`).
        case escape = 27
        /// Picks a dialog's highlighted option — on a plan, its first: approve and go on.
        case enter = 13

        public var text: String { String(UnicodeScalar(UInt8(rawValue))) }
    }

    /// What Claude reads when the user sends a plan back: the dialog's "Tell Claude what to
    /// change", carried by a denial (Claude Code honours a hook's denial of ExitPlanMode, and
    /// shows its message to the model).
    public static func planFeedback(_ text: String) -> String {
        "The user reviewed this plan on the HQ board and wants changes before you start. "
            + "Stay in plan mode, revise the plan, and call ExitPlanMode again. Their feedback:\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Does the board's answer still belong to the prompt the session has up? The pet's dots
    /// carry the prompt's id (`promptAsk`) and kind only while a pet-emit holds it open, and a
    /// new prompt gets a new id — so an answer drawn from a board seconds old answers nothing else.
    public static func matches(dot: [String: Any]?, ask: String, kind: String) -> Bool {
        guard !ask.isEmpty, let dot else { return false }
        return dot["promptAsk"] as? String == ask && dot["askKind"] as? String == kind
    }
}
