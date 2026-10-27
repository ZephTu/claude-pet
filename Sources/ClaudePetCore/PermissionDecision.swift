import Foundation

/// Answering a permission prompt from the pet instead of from the terminal.
///
/// Claude Code runs PermissionRequest hooks ALONGSIDE its own dialog, and the
/// first to answer wins: the terminal prompt appears at once as usual, and the
/// hook may settle it first. So pet-emit holds that hook open, the app writes
/// the user's click to a file, and pet-emit hands it back as the hook's output.
/// Answering in the terminal instead simply wins the race; the pet's late
/// answer, if any, is ignored by Claude Code.
///
/// Every request carries an `askId` minted by pet-emit and written into the
/// session file. A decision names the ask it answers, so a click on a prompt
/// that has since been replaced by another can never approve the new one.
public enum PermissionDecision {
    public enum Behavior: String, Sendable, Equatable {
        case allow
        case deny
    }

    public struct Answer: Sendable, Equatable {
        public let askId: String
        public let behavior: Behavior

        public init(askId: String, behavior: Behavior) {
            self.askId = askId
            self.behavior = behavior
        }
    }

    /// How long pet-emit keeps the hook open. Below the hook's own timeout in
    /// settings.json (`SettingsPatch.permissionTimeout`) so pet-emit always
    /// leaves on its own terms rather than being killed mid-write.
    public static let wait: TimeInterval = 590

    /// What a denial tells Claude, so the model knows a person said no rather
    /// than guessing at a tool failure.
    public static let denyMessage = "The user denied this from Claude Pet."

    /// One file per session: a session has at most one prompt up at a time.
    public static func fileURL(petHome: URL, sessionId: String) -> URL {
        petHome.appending(path: "decisions")
            .appending(path: CompletionQueue.sanitise(sessionId) + ".json")
    }

    public static func encode(_ answer: Answer) -> Data {
        let doc = ["askId": answer.askId, "behavior": answer.behavior.rawValue]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }

    public static func decode(_ data: Data) -> Answer? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let d = raw as? [String: String],
            let askId = d["askId"], !askId.isEmpty,
            let behavior = d["behavior"].flatMap(Behavior.init(rawValue:))
        else { return nil }
        return Answer(askId: askId, behavior: behavior)
    }

    /// The hook output Claude Code reads a PermissionRequest decision from.
    public static func hookOutput(_ behavior: Behavior) -> Data {
        var decision: [String: Any] = ["behavior": behavior.rawValue]
        if behavior == .deny { decision["message"] = denyMessage }
        let doc: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: .sortedKeys)) ?? Data()
    }

    /// Should a hook waiting on `askId` give up, given the session file now?
    ///
    /// The file moving on means the prompt is gone — answered in the terminal
    /// and already followed by the next event, or replaced by another prompt —
    /// and holding the hook any longer would only keep a process alive.
    public static func isStale(askId: String, sessionDocument: [String: Any]?) -> Bool {
        guard let doc = sessionDocument else { return true }
        return doc["state"] as? String != "waiting" || doc["askId"] as? String != askId
    }
}
