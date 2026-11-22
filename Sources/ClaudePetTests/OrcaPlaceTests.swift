import ClaudePetCore
import Foundation

/// Resume goes back to the Orca tab Orca keeps a session in — asleep after a restart too.
enum OrcaPlaceTests {
    static func run(_ t: Harness) {
        print("\n-- Orca place (Resume in the tab Orca keeps)")
        let refused = #"{"ok":false,"error":{"code":"agent_provider_id","message":"5b6ce3f7-18c7-46cc-9227-9a8c69be9699 is the agent's own conversation id, not its Orca session ID. Address it as orca_session_id:1ddf3a81-a89c-4579-8f1a-adf9c79abe5f."}}"#
        t.check("Claude's session id is refused with the Orca ID to use",
                OrcaPlace.orcaSessionID(showOutput: refused) == "1ddf3a81-a89c-4579-8f1a-adf9c79abe5f")
        t.check("an unknown session has no Orca ID",
                OrcaPlace.orcaSessionID(showOutput: #"{"ok":false,"error":{"code":"agent_unknown","message":"No agent x on this Orca."}}"#) == nil)
        t.check("an accepted id gives its own Orca ID",
                OrcaPlace.orcaSessionID(showOutput: #"{"ok":true,"result":{"orcaSessionId":"abc"}}"#) == "abc")
        t.check("unreadable output has no Orca ID", OrcaPlace.orcaSessionID(showOutput: "orca: not running") == nil)

        let shown = #"{"ok":true,"result":{"orcaSessionId":"x","places":[{"worktreeId":"r1::/w","paneKey":"tab1:leaf1","state":"done"}]}}"#
        let place = OrcaPlace.Place(worktreeID: "r1::/w", tabID: "tab1", leafID: "leaf1")
        t.check("a place is its workspace, tab and pane", OrcaPlace.places(showOutput: shown) == [place])
        t.check("a closed agent has no place",
                OrcaPlace.places(showOutput: #"{"ok":true,"result":{"orcaSessionId":"x","places":[]}}"#).isEmpty)
        t.check("a malformed pane key is skipped",
                OrcaPlace.places(showOutput: #"{"ok":true,"result":{"places":[{"worktreeId":"r","paneKey":"tab1"}]}}"#).isEmpty)
        t.check("the workspace selector is its id", OrcaPlace.worktreeSelector(place) == "id:r1::/w")

        func term(_ tab: String = "tab1", _ leaf: String = "leaf1", agent: Any = "", preview: String = "~ %",
                  writable: Bool = true, orphaned: Bool = false) -> [String: Any] {
            ["handle": "term_1", "tabId": tab, "leafId": leaf, "agentIdentity": agent, "preview": preview,
             "connected": true, "writable": writable, "orphaned": orphaned]
        }
        t.check("a sleeping tab is not live", OrcaPlace.live(terminals: [], place: place) == nil)
        t.check("another pane of the tab is not the place",
                OrcaPlace.live(terminals: [term("tab1", "leaf2")], place: place) == nil)
        t.check("an orphaned terminal is not the place",
                OrcaPlace.live(terminals: [term(orphaned: true)], place: place) == nil)
        t.check("a tab running the agent is brought forward, not typed into",
                OrcaPlace.live(terminals: [term(agent: "claude", preview: "✻ Thinking…")], place: place) == .agent(handle: "term_1"))
        t.check("a shell prompt Stop left behind gets the resume command",
                OrcaPlace.live(terminals: [term()], place: place) == .shell(handle: "term_1"))
        t.check("a shell prompt wins over a stale agent identity",
                OrcaPlace.live(terminals: [term(agent: "claude", preview: "user@mac smart-agent %")], place: place) == .shell(handle: "term_1"))
        t.check("another program running there is left alone",
                OrcaPlace.live(terminals: [term(preview: "Downloading 42.0%")], place: place) == .busy(handle: "term_1"))
        t.check("a read-only terminal is left alone",
                OrcaPlace.live(terminals: [term(writable: false)], place: place) == .busy(handle: "term_1"))
    }
}
