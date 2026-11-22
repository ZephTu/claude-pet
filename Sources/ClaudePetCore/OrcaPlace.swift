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
    /// asleep; a closed one has none. An agent resumed in two panes shows both. A place on
    /// another host (a `hostId` other than "local") is left out: its terminals aren't this Orca's.
    ///
    /// Each place also carries a `state` (working, blocked, waiting or done), but none of them
    /// says the agent exited — "done" is a finished turn, and a live agent at its prompt shows it
    /// too — so Resume doesn't read it; whether a woken tab got its agent back is told from the
    /// terminal itself (see `WakeWatch`).
    public static func places(showOutput: String) -> [Place] {
        guard let root = json(showOutput), root["ok"] as? Bool == true,
              let places = (root["result"] as? [String: Any])?["places"] as? [[String: Any]] else { return [] }
        return places.compactMap { p in
            if let host = p["hostId"] as? String, host != "local" { return nil }
            guard let wt = p["worktreeId"] as? String, !wt.isEmpty,
                  let pane = p["paneKey"] as? String else { return nil }
            let parts = pane.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Place(worktreeID: wt, tabID: parts[0], leafID: parts[1])
        }
    }

    /// The live terminal in a place's pane, from `orca terminal list --json`'s terminals.
    public enum Live: Equatable {
        /// This session runs in it (Orca resumed it, or it never stopped): just go there.
        case agent(handle: String)
        /// A shell waits at its prompt (Stop left it there): type the resume command there.
        case shell(handle: String)
        /// Something else runs in it — another program, another Claude Code session — or it
        /// can't be written to: leave it alone.
        case busy(handle: String)
    }

    /// The live terminal in `place`, or nil when the pane is asleep (not in the list).
    /// `recorded` maps a terminal handle to the Claude Code session the pet records live in it.
    /// Orca's `agentIdentity` only names the provider ("claude"), so the pet's record is what
    /// tells which session a tab runs: another live session there makes the tab busy.
    public static func live(terminals: [[String: Any]], place: Place, session: String = "",
                            recorded: [String: String] = [:]) -> Live? {
        guard let t = terminal(terminals, place), let handle = t["handle"] as? String, !handle.isEmpty else { return nil }
        let there = recorded[handle]
        if let there, there != session { return .busy(handle: handle) }
        if there != nil { return .agent(handle: handle) }   // this very session is live there
        // Nothing live recorded there: a shell prompt wins over an agent identity Orca may still
        // show after the agent quit.
        if t["connected"] as? Bool == true, t["writable"] as? Bool == true,
           IdleTab.atShellPrompt(t["preview"] as? String ?? "") { return .shell(handle: handle) }
        return agentShown(t) ? .agent(handle: handle) : .busy(handle: handle)
    }

    /// What Resume does with the places Orca has a session in.
    public enum Choice: Equatable {
        /// A tab already runs this session: bring it forward, type nothing.
        case bringForward(Place, handle: String)
        /// A tab sleeps: open its workspace and Orca resumes the session there; type nothing.
        case wake(Place)
        /// A tab waits at a shell prompt: type the resume command there.
        case type(Place, handle: String)
    }

    /// Picks among every place: a tab running this session first, then a sleeping one (Orca
    /// resumes it when woken, so typing anywhere too would run it twice), then a shell prompt.
    /// nil when every place is busy — the caller falls back to an idle tab by title or a new one.
    public static func choose(places: [Place], terminals: [[String: Any]], session: String,
                              recorded: [String: String]) -> Choice? {
        let lives = places.map { live(terminals: terminals, place: $0, session: session, recorded: recorded) }
        let all = Array(zip(places, lives))
        for (p, l) in all { if case .agent(let h)? = l { return .bringForward(p, handle: h) } }
        if let (p, _) = all.first(where: { $0.1 == nil }) { return .wake(p) }
        for (p, l) in all { if case .shell(let h)? = l { return .type(p, handle: h) } }
        return nil
    }

    /// Watches a woken tab. Orca resumes the agent in a sleeping tab by itself, but not one
    /// whose agent had exited before the restart (Stop left it at a shell): that tab wakes to a
    /// bare prompt and stays there. So a prompt with no agent identity and no live session
    /// recorded on it, seen for `settlePolls` polls in a row, gets the resume command — once.
    public struct WakeWatch {
        public enum Step: Equatable {
            /// Not settled yet; `seen` is the woken tab's handle once it is live.
            case wait(seen: String?)
            /// This session runs in one of its places: done, nothing to type.
            case arrived(handle: String)
            /// The woken tab stayed at a bare prompt: type the resume command into it.
            case type(handle: String)
        }
        public let settlePolls: Int
        private var bare = 0
        public init(settlePolls: Int = 6) { self.settlePolls = settlePolls }

        public mutating func step(places: [Place], woken: Place, terminals: [[String: Any]],
                                  session: String, recorded: [String: String]) -> Step {
            for p in places {
                if case .agent(let h)? = OrcaPlace.live(terminals: terminals, place: p, session: session,
                                                        recorded: recorded) { return .arrived(handle: h) }
            }
            let l = OrcaPlace.live(terminals: terminals, place: woken, session: session, recorded: recorded)
            if case .shell(let h)? = l, let t = OrcaPlace.terminal(terminals, woken), !OrcaPlace.agentShown(t) {
                bare += 1
                return bare >= settlePolls ? .type(handle: h) : .wait(seen: h)
            }
            bare = 0
            switch l {
            case .agent(let h)?, .shell(let h)?, .busy(let h)?: return .wait(seen: h)
            case nil: return .wait(seen: nil)
            }
        }
    }

    private static func terminal(_ terminals: [[String: Any]], _ place: Place) -> [String: Any]? {
        terminals.first {
            ($0["tabId"] as? String) == place.tabID && ($0["leafId"] as? String) == place.leafID
                && $0["orphaned"] as? Bool != true
        }
    }

    private static func agentShown(_ t: [String: Any]) -> Bool {
        let agent = t["agentIdentity"]
        return (agent as? String).map { !$0.isEmpty } ?? (agent is [String: Any])
    }

    /// The `--worktree` selector for a place's workspace.
    public static func worktreeSelector(_ place: Place) -> String { "id:" + place.worktreeID }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
