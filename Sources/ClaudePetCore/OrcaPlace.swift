import Foundation

/// Where Orca keeps a Claude Code session, so Resume can go back to that tab.
///
/// Orca remembers which tab each agent runs in, across a restart too: after a restart a tab
/// sleeps until its workspace is opened, and then Orca resumes the agent in it by itself. A
/// sleeping tab is not in `orca terminal list` (live terminals only), so looking for a tab by
/// title finds nothing and the board used to open a second tab — and the session then ran twice
/// once the workspace woke. `orca agent show` answers by Orca's own session ID, and given
/// Claude Code's session id it says which Orca ID to use instead; this reads both answers.
/// Pure so it can be tested without Orca.
public enum OrcaPlace {
    /// A pane Orca has the session in: its workspace, its tab and the pane within the tab.
    public struct Place: Equatable {
        public let worktreeID: String
        public let tabID: String
        public let leafID: String
        public init(worktreeID: String, tabID: String, leafID: String) {
            self.worktreeID = worktreeID; self.tabID = tabID; self.leafID = leafID
        }
    }

    /// The Orca session ID from `orca agent show <claude session id> --json`: Orca refuses a
    /// provider's own id with `agent_provider_id` and names the ID to use ("Address it as
    /// orca_session_id:<id>."). nil when Orca doesn't know the session (`agent_unknown`) or the
    /// output can't be read.
    public static func orcaSessionID(showOutput: String) -> String? {
        guard let root = json(showOutput) else { return nil }
        if root["ok"] as? Bool == true, let id = (root["result"] as? [String: Any])?["orcaSessionId"] as? String,
           !id.isEmpty { return id }
        guard let err = root["error"] as? [String: Any], err["code"] as? String == "agent_provider_id",
              let msg = err["message"] as? String,
              let r = msg.range(of: #"orca_session_id:[0-9A-Za-z_-]+"#, options: .regularExpression)
        else { return nil }
        return String(msg[r].dropFirst("orca_session_id:".count))
    }

    /// The tabs `orca agent show orca_session_id:<id> --json` places the agent in — open or
    /// asleep; a closed one has none.
    public static func places(showOutput: String) -> [Place] {
        guard let root = json(showOutput), root["ok"] as? Bool == true,
              let places = (root["result"] as? [String: Any])?["places"] as? [[String: Any]] else { return [] }
        return places.compactMap { p in
            guard let wt = p["worktreeId"] as? String, !wt.isEmpty,
                  let pane = p["paneKey"] as? String else { return nil }
            let parts = pane.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Place(worktreeID: wt, tabID: parts[0], leafID: parts[1])
        }
    }

    /// The live terminal in a place's pane, from `orca terminal list --json`'s terminals.
    public enum Live: Equatable {
        /// An agent runs in it (Orca resumed it, or it never stopped): just go there.
        case agent(handle: String)
        /// A shell waits at its prompt (Stop left it there): type the resume command there.
        case shell(handle: String)
        /// Something else runs in it, or it can't be written to: leave it alone.
        case busy(handle: String)
    }

    public static func live(terminals: [[String: Any]], place: Place) -> Live? {
        guard let t = terminals.first(where: {
                  ($0["tabId"] as? String) == place.tabID && ($0["leafId"] as? String) == place.leafID
                      && $0["orphaned"] as? Bool != true }),
              let handle = t["handle"] as? String, !handle.isEmpty else { return nil }
        let agent = t["agentIdentity"]
        let hasAgent = (agent as? String).map { !$0.isEmpty } ?? (agent is [String: Any])
        // A shell prompt wins over an agent identity Orca may still show after the agent quit.
        if t["connected"] as? Bool == true, t["writable"] as? Bool == true,
           IdleTab.atShellPrompt(t["preview"] as? String ?? "") { return .shell(handle: handle) }
        return hasAgent ? .agent(handle: handle) : .busy(handle: handle)
    }

    /// The `--worktree` selector for a place's workspace.
    public static func worktreeSelector(_ place: Place) -> String { "id:" + place.worktreeID }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
