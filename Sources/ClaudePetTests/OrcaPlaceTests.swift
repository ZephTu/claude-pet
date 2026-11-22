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

        let twoPanes = #"{"ok":true,"result":{"places":[{"worktreeId":"r1::/w","paneKey":"tab1:leaf1","hostId":"local"},{"worktreeId":"r2::/v","paneKey":"tab2:leaf2","hostId":"local"}]}}"#
        let place2 = OrcaPlace.Place(worktreeID: "r2::/v", tabID: "tab2", leafID: "leaf2")
        t.check("an agent resumed in two panes has both places",
                OrcaPlace.places(showOutput: twoPanes) == [place, place2])
        t.check("a place on another host is left out",
                OrcaPlace.places(showOutput: #"{"ok":true,"result":{"places":[{"worktreeId":"r9","paneKey":"t:l","hostId":"ssh-box"},{"worktreeId":"r1::/w","paneKey":"tab1:leaf1","hostId":"local"}]}}"#) == [place])

        func term(_ tab: String = "tab1", _ leaf: String = "leaf1", agent: Any = "", preview: String = "~ %",
                  writable: Bool = true, orphaned: Bool = false, handle: String = "term_1") -> [String: Any] {
            ["handle": handle, "tabId": tab, "leafId": leaf, "agentIdentity": agent, "preview": preview,
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

        // Which session a tab runs: the pet's record of live sessions per terminal handle.
        let me = "11111111-1111-1111-1111-111111111111", other = "22222222-2222-2222-2222-222222222222"
        t.check("a tab another live session runs in is busy, agent identity or not",
                OrcaPlace.live(terminals: [term(agent: "claude", preview: "✻ Thinking…")], place: place,
                               session: me, recorded: ["term_1": other]) == .busy(handle: "term_1"))
        t.check("a prompt with another live session recorded on it is busy, not typed into",
                OrcaPlace.live(terminals: [term()], place: place, session: me, recorded: ["term_1": other]) == .busy(handle: "term_1"))
        t.check("a tab this session is recorded live in is brought forward",
                OrcaPlace.live(terminals: [term(agent: "claude", preview: "✻ Thinking…")], place: place,
                               session: me, recorded: ["term_1": me]) == .agent(handle: "term_1"))
        t.check("agent identity plus this session recorded there beats a prompt-looking line",
                OrcaPlace.live(terminals: [term(agent: "claude", preview: "user@mac smart-agent %")], place: place,
                               session: me, recorded: ["term_1": me]) == .agent(handle: "term_1"))
        t.check("another handle's record doesn't matter",
                OrcaPlace.live(terminals: [term()], place: place, session: me, recorded: ["term_9": other]) == .shell(handle: "term_1"))

        // Choosing among the places.
        let p1 = place, p2 = place2
        func choose(_ terms: [[String: Any]], _ rec: [String: String] = [:]) -> OrcaPlace.Choice? {
            OrcaPlace.choose(places: [p1, p2], terminals: terms, session: me, recorded: rec)
        }
        let shell1 = term(), agent2 = term("tab2", "leaf2", agent: "claude", preview: "✻ Thinking…", handle: "term_2")
        t.check("a pane running the session wins over a shell prompt in another",
                choose([shell1, agent2]) == .bringForward(p2, handle: "term_2"))
        t.check("a sleeping pane wins over a shell prompt: Orca resumes it there, nothing typed",
                choose([shell1]) == .wake(p2))
        t.check("a pane running the session wins over a sleeping one",
                choose([agent2]) == .bringForward(p2, handle: "term_2"))
        t.check("with every pane live and none running it, the prompt gets the command",
                choose([shell1, term("tab2", "leaf2", preview: "Downloading 42.0%", handle: "term_2")]) == .type(p1, handle: "term_1"))
        t.check("a pane another session runs in is skipped",
                choose([shell1, agent2], ["term_2": other]) == .type(p1, handle: "term_1"))
        t.check("every pane busy: nothing to choose, the board finds or opens a tab",
                choose([term(preview: "vim"), agent2], ["term_2": other]) == nil)
        t.check("no places: nothing to choose",
                OrcaPlace.choose(places: [], terminals: [shell1], session: me, recorded: [:]) == nil)

        // Watching a woken tab.
        func watch(_ polls: [[[String: Any]]], rec: [String: String] = [:], settle: Int = 3) -> [OrcaPlace.WakeWatch.Step] {
            var w = OrcaPlace.WakeWatch(settlePolls: settle)
            return polls.map { w.step(places: [p1, p2], woken: p1, terminals: $0, session: me, recorded: rec) }
        }
        let bare = term(), booting = term(preview: "claude --resume …"), running = term(agent: "claude", preview: "✻ Thinking…")
        t.check("a woken tab that stays at a bare prompt gets the command once it settles",
                watch([[], [bare], [bare], [bare]]) == [.wait(seen: nil), .wait(seen: "term_1"), .wait(seen: "term_1"), .type(handle: "term_1")])
        t.check("a woken tab Orca resumes the agent in is never typed into",
                watch([[bare], [booting], [running]]) == [.wait(seen: "term_1"), .wait(seen: "term_1"), .arrived(handle: "term_1")])
        t.check("the prompt count starts over when the tab stops being a bare prompt",
                watch([[bare], [bare], [booting], [bare], [bare]]).contains(where: {
                    if case .type = $0 { return true } else { return false } }) == false)
        t.check("a prompt with an agent identity is not bare",
                watch([[term(agent: "claude")], [term(agent: "claude")], [term(agent: "claude")]]).allSatisfy {
                    if case .wait = $0 { return true } else { return false } })
        t.check("a prompt with this session recorded live on it has arrived",
                watch([[bare]], rec: ["term_1": me]) == [.arrived(handle: "term_1")])
        t.check("a prompt with another session recorded on it is never typed into",
                watch([[bare], [bare], [bare], [bare]], rec: ["term_1": other]).allSatisfy {
                    if case .wait = $0 { return true } else { return false } })
        t.check("the session turning up in another pane ends the watch untyped",
                watch([[bare], [bare, agent2]]) == [.wait(seen: "term_1"), .arrived(handle: "term_2")])
        t.check("the default settle is 3 s of half-second polls", OrcaPlace.WakeWatch().settlePolls == 6)
    }
}
