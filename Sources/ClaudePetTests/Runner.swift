import ClaudePetCore
import CoreGraphics
import Foundation

@main
struct Runner {
    static func main() {
        let t = Harness()

        let json = """
        {"sessionId":"abc","project":"multica","cwd":"/Users/dev/Projects/demo-app",
         "state":"busy","tool":"Bash","detail":"",
         "since":"2026-09-15T10:20:00Z","updatedAt":"2026-09-15T10:23:45Z"}
        """.data(using: .utf8)!

        let s = SessionState.decode(from: json)
        t.check("decodes a well-formed file", s != nil)
        t.check("reads sessionId", s?.sessionId == "abc")
        t.check("reads project", s?.project == "multica")
        t.check("reads state", s?.state == .busy)
        t.check("reads tool", s?.tool == "Bash")
        // 2026-09-15T10:20:00Z verified via `python3 -c "import datetime;print(int(datetime.datetime(2026,9,15,10,20,0,tzinfo=datetime.timezone.utc).timestamp()))"`
        // and cross-checked with `date -j -u -f "%Y-%m-%dT%H:%M:%SZ" ... "+%s"`; both report 1789467600.
        t.check("parses since as ISO8601", s?.since == Date(timeIntervalSince1970: 1_789_467_600))
        t.check("garbage returns nil", SessionState.decode(from: Data("{ not json".utf8)) == nil)
        t.check("missing field returns nil", SessionState.decode(from: Data(#"{"sessionId":"a"}"#.utf8)) == nil)

        // ---- StateAggregator ----
        let t0 = Date(timeIntervalSince1970: 1_789_467_600)  // Reference "now" = 2026-09-15T10:20:00Z, the same instant as the decode test above
        func mk(_ id: String, _ st: SessionActivity, sinceAgo: TimeInterval = 0,
                updatedAgo: TimeInterval = 0, project: String = "p") -> SessionState {
            SessionState(sessionId: id, project: project, cwd: "/tmp/\(project)",
                         state: st, tool: "", detail: "",
                         since: t0.addingTimeInterval(-sinceAgo),
                         updatedAt: t0.addingTimeInterval(-updatedAgo))
        }

        t.check("empty input is idle",
                StateAggregator.aggregate([], now: t0).mood == .idle)
        t.check("all idle is idle",
                StateAggregator.aggregate([mk("a", .idle), mk("b", .idle)], now: t0).mood == .idle)
        t.check("busy beats idle",
                StateAggregator.aggregate([mk("a", .idle), mk("b", .busy)], now: t0).mood == .busy)
        t.check("waiting beats busy",
                StateAggregator.aggregate([mk("a", .busy), mk("b", .waiting)], now: t0).mood == .waiting)
        t.check("waiting beats busy regardless of order",
                StateAggregator.aggregate([mk("a", .waiting), mk("b", .busy)], now: t0).mood == .waiting)

        // Dead-session boundary: 900s is still alive, 901s is dead
        t.check("899s stale still counts",
                StateAggregator.aggregate([mk("a", .busy, updatedAgo: 899)], now: t0).mood == .busy)
        t.check("exactly 900s still counts",
                StateAggregator.aggregate([mk("a", .busy, updatedAgo: 900)], now: t0).mood == .busy)
        t.check("901s is dropped",
                StateAggregator.aggregate([mk("a", .busy, updatedAgo: 901)], now: t0).mood == .idle)
        t.check("dead sessions leave the list",
                StateAggregator.aggregate([mk("a", .busy, updatedAgo: 901)], now: t0).sessions.isEmpty)

        // Escalation boundary: 60s is still waiting, 61s becomes urgent
        t.check("waiting 59s is not urgent",
                StateAggregator.aggregate([mk("a", .waiting, sinceAgo: 59)], now: t0).mood == .waiting)
        t.check("waiting exactly 60s is not urgent",
                StateAggregator.aggregate([mk("a", .waiting, sinceAgo: 60)], now: t0).mood == .waiting)
        t.check("waiting 61s is urgent",
                StateAggregator.aggregate([mk("a", .waiting, sinceAgo: 61)], now: t0).mood == .urgent)

        // Urgency follows the OLDEST since, not the newest
        let mixed = [mk("a", .waiting, sinceAgo: 5, project: "fresh"),
                     mk("b", .waiting, sinceAgo: 300, project: "stuck")]
        t.check("oldest waiting drives urgency",
                StateAggregator.aggregate(mixed, now: t0).mood == .urgent)
        t.check("bubble names the longest-waiting project",
                StateAggregator.aggregate(mixed, now: t0).waitingProject == "stuck")
        t.check("no bubble when nothing waits",
                StateAggregator.aggregate([mk("a", .busy)], now: t0).waitingProject == nil)

        // Being busy for a long time never escalates; only waiting does
        t.check("long-running busy never turns urgent",
                StateAggregator.aggregate([mk("a", .busy, sinceAgo: 9999)], now: t0).mood == .busy)

        // A dead waiting session must not keep the pet alarmed forever
        t.check("dead waiting session does not keep pet urgent",
                StateAggregator.aggregate([mk("a", .waiting, sinceAgo: 5000, updatedAgo: 5000)], now: t0).mood == .idle)

        // ---- StateAggregator.ordered(_:) — row order ----
        // Group order is waiting > busy > idle; the input is deliberately not in that order
        let groupMix = [mk("a", .idle), mk("b", .busy), mk("c", .waiting)]
        t.check("sessions come back waiting, then busy, then idle",
                StateAggregator.aggregate(groupMix, now: t0).sessions.map(\.sessionId) == ["c", "b", "a"])

        // Within a group, oldest since first; the input is deliberately newest-first
        let sameGroup = [mk("x", .idle, sinceAgo: 10), mk("y", .idle, sinceAgo: 100)]
        t.check("within a group, oldest since comes first",
                StateAggregator.aggregate(sameGroup, now: t0).sessions.map(\.sessionId) == ["y", "x"])

        // Dead dropped and live kept in the SAME call — not the degenerate all-or-nothing case
        let deadAndLive = [mk("d", .busy, updatedAgo: 901), mk("l", .busy, updatedAgo: 0)]
        t.check("dead sessions excluded while live ones in the same call are retained",
                StateAggregator.aggregate(deadAndLive, now: t0).sessions.map(\.sessionId) == ["l"])

        // ---- PetLayout: window geometry and click-through ----
        // Regression guard: the panel used to be laid out at right:100% of a 160px body,
        // which put it entirely off-window at negative x.
        let win = CGRect(origin: .zero, size: PetLayout.windowSize)
        let expandedPanel = CGRect(x: 2, y: 14, width: 232, height: 260)
        t.check("expanded panel sits fully inside the window",
                win.contains(expandedPanel))
        t.check("pet box sits fully inside the window",
                win.contains(PetLayout.petBox))
        // pet.css pins #pet at right:20 bottom:20 of the 400x280 stage. If those
        // two numbers ever drift apart, every hit-test coordinate below is wrong.
        t.check("pet box matches #pet's right:20 bottom:20 in pet.css",
                PetLayout.petBox.maxX == win.maxX - 20 && PetLayout.petBox.maxY == win.maxY - 20)
        t.check("pet box centre is the SVG viewBox origin",
                PetLayout.petBox.midX == PetLayout.petCenter.x
                && PetLayout.petBox.midY == PetLayout.petCenter.y)
        t.check("panel and pet box do not overlap",
                !expandedPanel.intersects(PetLayout.petBox))
        t.check("both hit boxes stay inside the pet box",
                PetLayout.petBox.contains(PetLayout.bodyBox)
                && PetLayout.petBox.contains(PetLayout.antennaBox))
        // The antenna box hangs above the body box. A gap between them would be
        // a dead strip across the robot's neck.
        t.check("antenna box overlaps the body box, leaving no dead strip",
                PetLayout.antennaBox.maxY >= PetLayout.bodyBox.minY
                && PetLayout.bodyBox.minX <= PetLayout.antennaBox.minX
                && PetLayout.bodyBox.maxX >= PetLayout.antennaBox.maxX)

        func opaque(_ x: CGFloat, _ y: CGFloat,
                    panel: CGRect? = nil, bubble: CGRect? = nil) -> Bool {
            PetLayout.isOpaque(at: CGPoint(x: x, y: y), panel: panel, bubble: bubble)
        }
        // viewBox coordinate -> stage coordinate, the same mapping pet.css uses.
        func at(_ vx: CGFloat, _ vy: CGFloat) -> CGPoint {
            CGPoint(x: PetLayout.petCenter.x + vx, y: PetLayout.petCenter.y + vy)
        }
        func opaqueAt(_ vx: CGFloat, _ vy: CGFloat) -> Bool {
            let p = at(vx, vy)
            return opaque(p.x, p.y)
        }

        t.check("the robot's torso is opaque", opaqueAt(-14, 5))
        t.check("the monitor is opaque", opaqueAt(25, -14))
        // The desk runs the full width of the drawing; the old circular region
        // left both of its ends unclickable.
        t.check("the desk's left end is opaque", opaqueAt(-44, 20))
        t.check("the desk's right end is opaque", opaqueAt(44, 20))
        // The bulb sits above the body box and is the brightest thing on screen;
        // without antennaBox it would look clickable and pass clicks through.
        t.check("the antenna bulb is opaque", opaqueAt(-14, -44))
        t.check("the top of the antenna is opaque", opaqueAt(-14, -51))
        t.check("above the antenna is transparent", !opaqueAt(-14, -58))
        // urgent lifts the figure 5pt; the head must stay reachable mid-jolt.
        t.check("the robot's head is opaque at rest", opaqueAt(-14, -34))
        t.check("the robot's head is still opaque lifted 5pt by the urgent jolt",
                opaqueAt(-14, -39))
        // Most of the window is transparent and must pass clicks through to whatever is under it
        t.check("beyond the desk's left end is transparent", !opaqueAt(-54, 20))
        t.check("beyond the desk's right end is transparent", !opaqueAt(54, 20))
        t.check("below the desk is transparent", !opaqueAt(0, 40))
        t.check("the window's far corner is transparent", !opaque(10, 10))
        t.check("the collapsed panel's area is transparent", !opaque(100, 250))
        t.check("the expanded panel's area is opaque", opaque(100, 250, panel: expandedPanel))
        t.check("the bubble's area is opaque when shown",
                opaque(320, 130, bubble: CGRect(x: 280, y: 122, width: 80, height: 22)))
        t.check("the bubble's area is transparent when hidden", !opaque(320, 130))

        // ---- TerminalTarget: jumping back to a session's terminal ----
        t.check("orca and iterm2 are jumpable",
                TerminalTarget.canJump(kind: "orca") && TerminalTarget.canJump(kind: "iterm2"))
        // An unrecognised terminal degrades to "not clickable" rather than a dead click
        t.check("an unknown or empty kind is not jumpable",
                !TerminalTarget.canJump(kind: "vscode") && !TerminalTarget.canJump(kind: ""))

        // The w/t/p prefix is the tab's position when the shell started and goes stale
        // as soon as tabs are reordered; the uuid does not
        t.check("the w/t/p prefix is stripped from ITERM_SESSION_ID",
                TerminalTarget.iTermUUID(from: "w0t1p0:9E1C2A3B-1111-2222-3333-444455556666")
                == "9E1C2A3B-1111-2222-3333-444455556666")
        t.check("an id with no colon is passed through unchanged",
                TerminalTarget.iTermUUID(from: "9E1C2A3B-1111") == "9E1C2A3B-1111")
        t.check("only the first colon splits, so a uuid keeps any later ones",
                TerminalTarget.iTermUUID(from: "w0t0p0:AB:CD") == "AB:CD")

        // The one genuinely dangerous input here: it comes from an environment variable,
        // is written to a file by one process, and pasted into a script another process
        // executes. A quote or newline would end the literal and run as code.
        t.check("a real uuid passes the AppleScript-injection guard",
                TerminalTarget.isSafeITermUUID("9E1C2A3B-1111-2222-3333-444455556666"))
        t.check("an empty uuid is rejected", !TerminalTarget.isSafeITermUUID(""))
        t.check("a quote is rejected",
                !TerminalTarget.isSafeITermUUID("AB\" & (do shell script \"rm -rf ~\") & \""))
        t.check("a newline is rejected", !TerminalTarget.isSafeITermUUID("AB\ndo shell script \"x\""))
        t.check("a space is rejected", !TerminalTarget.isSafeITermUUID("AB CD"))
        t.check("a non-hex letter is rejected", !TerminalTarget.isSafeITermUUID("ABZZ"))

        // A state file predating this field must decode as "not jumpable", not be dropped
        let withoutTerminal = Data("""
        {"sessionId":"s1","project":"p","cwd":"/tmp","state":"busy","tool":"Bash",
         "detail":"","since":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z"}
        """.utf8)
        t.check("a state file written before this feature still decodes",
                SessionState.decode(from: withoutTerminal)?.terminal == nil)

        let withTerminal = Data("""
        {"sessionId":"s2","project":"p","cwd":"/tmp","state":"busy","tool":"Bash",
         "detail":"","since":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z",
         "terminal":{"kind":"orca","handle":"term_abc123"}}
        """.utf8)
        t.check("a terminal reference round-trips out of the state file",
                SessionState.decode(from: withTerminal)?.terminal
                == TerminalRef(kind: "orca", handle: "term_abc123"))

        // identify(): both handle variables are ordinary exported variables and are
        // inherited by child processes, so bare presence cannot say which terminal
        // the human is actually sitting in front of
        let orcaOnly = ["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": "term_x"]
        t.check("an Orca shell is identified as orca",
                TerminalTarget.identify(environment: orcaOnly) == TerminalRef(kind: "orca", handle: "term_x"))
        let itermOnly = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:AB-CD"]
        t.check("an iTerm2 shell is identified as iterm2",
                TerminalTarget.identify(environment: itermOnly) == TerminalRef(kind: "iterm2", handle: "w0t0p0:AB-CD"))
        // Caught for real while testing: running the suite inside Orca left
        // ORCA_TERMINAL_HANDLE in the environment, and presence alone sent an iTerm2
        // session to a completely unrelated Orca tab
        let both = [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t0p0:AB-CD",
            "ORCA_TERMINAL_HANDLE": "term_stale",
        ]
        t.check("TERM_PROGRAM wins when a stale handle from another terminal is inherited",
                TerminalTarget.identify(environment: both) == TerminalRef(kind: "iterm2", handle: "w0t0p0:AB-CD"))
        // With TERM_PROGRAM absent, bare presence is all there is — better than nothing
        t.check("a missing TERM_PROGRAM falls back to whichever handle exists",
                TerminalTarget.identify(environment: ["ORCA_TERMINAL_HANDLE": "term_y"])
                == TerminalRef(kind: "orca", handle: "term_y"))
        t.check("a terminal we cannot address yields no reference",
                TerminalTarget.identify(environment: ["TERM_PROGRAM": "Apple_Terminal"]) == nil)
        // Also caught for real: running under Terminal.app while carrying an inherited
        // Orca handle, where falling back on presence offers a jump to an unrelated tab
        t.check("a known-but-unsupported terminal does not fall back to an inherited handle",
                TerminalTarget.identify(environment: [
                    "TERM_PROGRAM": "Apple_Terminal",
                    "ORCA_TERMINAL_HANDLE": "term_stale",
                ]) == nil)
        t.check("an empty handle is treated as absent",
                TerminalTarget.identify(environment: ["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": ""]) == nil)

        // ---- Liveness: ask the kernel, do not watch the clock ----
        // Reported by a user: an open session nobody is touching fires no hooks at all,
        // so updatedAt stands still and it vanished from the panel after 15 minutes —
        // while being very much alive
        t.check("the current process is detected as running",
                ProcessProbe.isRunning(pid: ProcessInfo.processInfo.processIdentifier,
                                       named: ProcessProbe.processName(
                                           pid: ProcessInfo.processInfo.processIdentifier) ?? "?"))
        t.check("a pid that cannot exist is not running",
                !ProcessProbe.isRunning(pid: 0, named: "claude"))
        t.check("a negative pid is not running",
                !ProcessProbe.isRunning(pid: -1, named: "claude"))
        // Pids are recycled, so "that pid is alive" is not enough — launchd is always
        // alive and is not claude
        t.check("a live pid running something else does not count as claude",
                !ProcessProbe.isRunning(pid: 1, named: "claude"))
        t.check("pid 1 is launchd", ProcessProbe.processName(pid: 1) == "launchd")
        // Caught for real: the kernel's p_comm is "claude.exe" while ps -o comm shows
        // "claude", the basename of argv[0]. Exact-matching "claude" recognised nothing.
        t.check("the kernel's claude.exe matches the claude prefix",
                ProcessProbe.nameMatches("claude.exe", "claude"))
        t.check("a bare claude also matches, in case the name changes back",
                ProcessProbe.nameMatches("claude", "claude"))
        t.check("an unrelated process does not match",
                !ProcessProbe.nameMatches("launchd", "claude"))
        t.check("an empty wanted name matches nothing",
                !ProcessProbe.nameMatches("claude.exe", ""))
        t.check("every process has a parent except the root",
                (ProcessProbe.parentPID(of: ProcessInfo.processInfo.processIdentifier) ?? 0) > 0)

        // With a pid recorded, a live process keeps the session listed however long it idles
        let ancient = Date(timeIntervalSince1970: 1_700_000_000)
        let idleButOpen = SessionState(
            sessionId: "open", project: "p", cwd: "/tmp", state: .idle, tool: "",
            detail: "", since: ancient, updatedAt: ancient, terminal: nil, pid: 4242)
        t.check("a session whose process is alive survives any amount of silence",
                StateAggregator.aggregate([idleButOpen], now: t0,
                                          isLive: { _, _ in true }).sessions.count == 1)
        t.check("a session whose process is gone is dropped immediately",
                StateAggregator.aggregate([idleButOpen], now: t0,
                                          isLive: { _, _ in false }).sessions.isEmpty)

        // Legacy files with no pid still honour the timeout — upgrading must not turn
        // them all into zombies
        let legacyFresh = mk("legacy-fresh", .busy, updatedAgo: 100)
        let legacyStale = mk("legacy-stale", .busy, updatedAgo: 901)
        t.check("a legacy file with no pid still honours the timeout",
                StateAggregator.isLive(legacyFresh, now: t0)
                && !StateAggregator.isLive(legacyStale, now: t0))

        // lastPromptAt is Date? — Optional covers a MISSING key, not a key present with
        // an empty string. The latter throws, and a throw drops the whole session from
        // the panel silently, so both shapes are checked.
        let emptyPrompt = Data("""
        {"sessionId":"s","project":"p","cwd":"/tmp","state":"busy","tool":"","detail":"",
         "since":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z","lastPromptAt":""}
        """.utf8)
        t.check("an empty lastPromptAt does not take the whole session down",
                SessionState.decode(from: emptyPrompt) != nil)
        let missingPrompt = Data("""
        {"sessionId":"s","project":"p","cwd":"/tmp","state":"busy","tool":"","detail":"",
         "since":"2026-09-16T00:00:00Z","updatedAt":"2026-09-16T00:00:00Z"}
        """.utf8)
        t.check("a missing lastPromptAt decodes as nil",
                SessionState.decode(from: missingPrompt)?.lastPromptAt == nil)

        // ---- Muting: hidden until you speak to it again ----
        let t1 = t0.addingTimeInterval(-3600)
        func session(_ id: String, _ act: SessionActivity, prompt: Date?) -> SessionState {
            SessionState(sessionId: id, project: id, cwd: "/tmp", state: act, tool: "",
                         detail: "", since: t1, updatedAt: t0, terminal: nil, pid: nil,
                         lastPromptAt: prompt)
        }
        let spoke = session("a", .idle, prompt: t1)
        let mark = HiddenSessions.mark(for: spoke)
        t.check("muting records the session's own last prompt, not the wall clock",
                mark == t1)
        t.check("a muted session stays hidden while nothing new is said",
                HiddenSessions.isHidden(spoke, marks: ["a": mark]))
        // The heart of the feature: only the USER speaking brings it back
        let spokeAgain = session("a", .idle, prompt: t0)
        t.check("a muted session returns as soon as the user speaks to it again",
                !HiddenSessions.isHidden(spokeAgain, marks: ["a": mark]))
        // The session working on its own does not count, or a long job would instantly
        // un-mute itself
        let busyButSilent = session("a", .busy, prompt: t1)
        t.check("the session working on its own does not un-mute it",
                HiddenSessions.isHidden(busyButSilent, marks: ["a": mark]))
        let neverSpoken = session("b", .idle, prompt: nil)
        t.check("muting a session never typed into still sticks",
                HiddenSessions.isHidden(neverSpoken,
                                        marks: ["b": HiddenSessions.mark(for: neverSpoken)]))
        t.check("an unmuted session is never hidden",
                !HiddenSessions.isHidden(spoke, marks: [:]))
        // Re-muting records a fresh mark, or speak → return → mute again would not stick
        t.check("re-muting after speaking sticks again",
                HiddenSessions.isHidden(spokeAgain,
                                        marks: ["a": HiddenSessions.mark(for: spokeAgain)]))

        // A muted session is out of the list AND out of the mood — otherwise the pet
        // waves about something the user cannot see, which is worse than seeing it
        let mutedWaiting = session("w", .waiting, prompt: t1)
        let visible = session("v", .idle, prompt: t1)
        let muted = StateAggregator.aggregate([mutedWaiting, visible], now: t0,
                                              hidden: ["w": t1], isLive: { _, _ in true })
        t.check("a muted session is dropped from the list",
                muted.sessions.map(\.sessionId) == ["v"])
        t.check("a muted session cannot make the pet wave",
                muted.mood == .idle && muted.waitingProject == nil)
        t.check("the panel is told how many are muted", muted.hiddenCount == 1)
        // A session that has exited should not be counted as hidden
        let deadMuted = StateAggregator.aggregate([mutedWaiting, visible], now: t0,
                                                  hidden: ["w": t1],
                                                  isLive: { s, _ in s.sessionId != "w" })
        t.check("a muted session that has exited is not counted as hidden",
                deadMuted.hiddenCount == 0)

        t.check("marks for departed sessions are pruned away",
                HiddenSessions.pruned(["a": t1, "gone": t1], keeping: [spoke]) == ["a": t1])

        // ---- Speech: quota data ----
        // Another plugin's private cache: its shape can change without warning, so any
        // surprise must degrade to silence
        let realCache = Data("""
        {"data":{"planName":"Team","fiveHour":6,"sevenDay":25,
          "fiveHourResetAt":"2026-09-16T07:40:00.039Z",
          "sevenDayResetAt":"2026-09-21T20:00:00.039Z"},
         "timestamp":1789528307450,
         "lastGoodData":{"planName":"Team","fiveHour":6,"sevenDay":25,
          "fiveHourResetAt":"2026-09-16T07:40:00.039Z",
          "sevenDayResetAt":"2026-09-21T20:00:00.039Z"}}
        """.utf8)
        let snap = UsageReader.parse(realCache)
        t.check("the real claude-hud cache parses", snap != nil)
        t.check("percentages come through", snap?.fiveHourPercent == 6 && snap?.sevenDayPercent == 25)
        // The cache writes fractional seconds (…:00.039Z), which a plain ISO8601 parser rejects
        t.check("a reset time with fractional seconds parses",
                snap?.fiveHourResetAt == Date(timeIntervalSince1970: 1789544400.039))
        t.check("the capture time comes from the millisecond timestamp",
                snap?.capturedAt == Date(timeIntervalSince1970: 1789528307.450))
        // Falling back to lastGoodData keeps one failed refresh from blanking the display
        let onlyLastGood = Data("""
        {"lastGoodData":{"planName":"Team","fiveHour":9,"sevenDay":30,
          "fiveHourResetAt":"2026-09-16T07:40:00Z","sevenDayResetAt":"2026-09-21T20:00:00Z"},
         "timestamp":1789528307450}
        """.utf8)
        t.check("a failed refresh falls back to lastGoodData",
                UsageReader.parse(onlyLastGood)?.fiveHourPercent == 9)
        t.check("garbage parses to nothing rather than crashing",
                UsageReader.parse(Data("not json".utf8)) == nil)
        t.check("a cache missing the fields we need parses to nothing",
                UsageReader.parse(Data(#"{"data":{"planName":"Team"}}"#.utf8)) == nil)

        // Percentages go stale (nothing refreshes them unless the statusline runs);
        // reset instants are absolute and do not
        let stale = UsageSnapshot(planName: "Team", fiveHourPercent: 90, sevenDayPercent: 90,
                                  fiveHourResetAt: t0.addingTimeInterval(3600),
                                  sevenDayResetAt: t0.addingTimeInterval(86400),
                                  capturedAt: t0.addingTimeInterval(-3600))
        t.check("percentages older than half an hour are not trusted",
                !stale.percentagesUsable(now: t0))

        // ---- Speech: when it may speak at all ----
        let quiet = GlobalState(mood: .idle, sessions: [], waitingProject: nil)
        let busyState = GlobalState(mood: .busy, sessions: [session("x", .busy, prompt: nil)],
                                    waitingProject: nil)
        let alarmed = GlobalState(mood: .urgent, sessions: [], waitingProject: "p")
        let fresh = UsageSnapshot(planName: "Team", fiveHourPercent: 10, sevenDayPercent: 10,
                                  fiveHourResetAt: t0.addingTimeInterval(10 * 60),
                                  sevenDayResetAt: t0.addingTimeInterval(86400),
                                  capturedAt: t0)

        // While raising the alarm the bubble belongs to "who needs you" — no small talk
        t.check("nothing is said while the pet is raising the alarm",
                Chatter.next(state: alarmed, previous: quiet, usage: fresh, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)
        let waitingState = GlobalState(mood: .waiting, sessions: [], waitingProject: "p")
        t.check("nothing is said while a session waits on the user",
                Chatter.next(state: waitingState, previous: quiet, usage: fresh, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)

        t.check("an imminent quota reset is worth saying",
                Chatter.next(state: quiet, previous: quiet, usage: fresh, now: t0,
                             lastSpoken: [:], lastAnything: nil)?.kind == .quotaResetting)
        // Just spoke: stay quiet, however many occasions there are
        t.check("the global cooldown silences everything",
                Chatter.next(state: quiet, previous: quiet, usage: fresh, now: t0,
                             lastSpoken: [:],
                             lastAnything: t0.addingTimeInterval(-60)) == nil)
        t.check("the same kind stays quiet until its own cooldown expires",
                Chatter.next(state: quiet, previous: quiet, usage: fresh, now: t0,
                             lastSpoken: [.quotaResetting: t0.addingTimeInterval(-600)],
                             lastAnything: t0.addingTimeInterval(-600)) == nil)

        // A reset that already happened must not be announced as "N minutes away"
        let past = UsageSnapshot(planName: "Team", fiveHourPercent: 10, sevenDayPercent: 10,
                                 fiveHourResetAt: t0.addingTimeInterval(-60),
                                 sevenDayResetAt: t0.addingTimeInterval(86400), capturedAt: t0)
        t.check("a reset that already happened is not announced",
                Chatter.next(state: quiet, previous: quiet, usage: past, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)

        // A nearly-spent quota is worth saying, but stale numbers are worse than silence
        let high = UsageSnapshot(planName: "Team", fiveHourPercent: 20, sevenDayPercent: 85,
                                 fiveHourResetAt: t0.addingTimeInterval(4 * 3600),
                                 sevenDayResetAt: t0.addingTimeInterval(86400), capturedAt: t0)
        t.check("a nearly-spent weekly quota is worth saying",
                Chatter.next(state: quiet, previous: quiet, usage: high, now: t0,
                             lastSpoken: [:], lastAnything: nil)?.kind == .quotaHigh)
        let highButStale = UsageSnapshot(planName: "Team", fiveHourPercent: 20, sevenDayPercent: 85,
                                         fiveHourResetAt: t0.addingTimeInterval(4 * 3600),
                                         sevenDayResetAt: t0.addingTimeInterval(86400),
                                         capturedAt: t0.addingTimeInterval(-3600))
        t.check("a stale percentage is never announced",
                Chatter.next(state: quiet, previous: quiet, usage: highButStale, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)

        // "Finished" needs a previous busy state, or a fresh launch would greet you with it
        t.check("finishing is announced when busy turns idle",
                Chatter.next(state: quiet, previous: busyState, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil)?.kind == .finished)
        t.check("a fresh launch does not greet the user with a transition line",
                Chatter.next(state: quiet, previous: nil, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)

        // Long-running is worth a line; just-started is not
        let longBusy = GlobalState(
            mood: .busy,
            sessions: [SessionState(sessionId: "l", project: "multica", cwd: "/tmp", state: .busy,
                                    tool: "Bash", detail: "", since: t0.addingTimeInterval(-1800),
                                    updatedAt: t0)],
            waitingProject: nil)
        t.check("a long-running session is remarked on",
                Chatter.next(state: longBusy, previous: longBusy, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil)?.kind == .longRun)
        let justStarted = GlobalState(
            mood: .busy,
            sessions: [SessionState(sessionId: "j", project: "p", cwd: "/tmp", state: .busy,
                                    tool: "", detail: "", since: t0.addingTimeInterval(-60),
                                    updatedAt: t0)],
            waitingProject: nil)
        t.check("a session that just started is not",
                Chatter.next(state: justStarted, previous: justStarted, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)

        // The on-demand readout was asked for, so no cooldown applies
        let rows = Chatter.quotaRows(usage: fresh, now: t0)
        t.check("the hover readout returns one row per window", rows.count == 2)
        t.check("rows are labelled and carry a countdown",
                rows[0].label == "5h" && rows[0].percent == 10 && !rows[0].resetsIn.isEmpty)
        // No claude-hud, or a stale cache: there is nothing honest to draw
        t.check("no rows without a usable reading",
                Chatter.quotaRows(usage: nil, now: t0).isEmpty
                && Chatter.quotaRows(usage: highButStale, now: t0).isEmpty)
        t.check("the fallback line still says something useful",
                Chatter.fallbackLine(state: quiet) == "No live sessions")
        // A percentage outside 0-100 would draw a bar past the end of its track
        let overflow = UsageSnapshot(planName: "Team", fiveHourPercent: 140, sevenDayPercent: -5,
                                     fiveHourResetAt: t0.addingTimeInterval(600),
                                     sevenDayResetAt: t0.addingTimeInterval(86400), capturedAt: t0)
        let clamped = Chatter.quotaRows(usage: overflow, now: t0)
        t.check("percentages are clamped to the track",
                clamped[0].percent == 100 && clamped[1].percent == 0)

        t.check("a countdown under an hour reads in minutes",
                Chatter.duration(until: t0.addingTimeInterval(44 * 60), now: t0) == "44m")
        t.check("a countdown over an hour reads h+m",
                Chatter.duration(until: t0.addingTimeInterval(104 * 60), now: t0) == "1h 44m")
        t.check("a multi-day countdown reads d+h",
                Chatter.duration(until: t0.addingTimeInterval(4 * 86400 + 14 * 3600), now: t0) == "4d 14h")
        t.check("a reset already past reads as now",
                Chatter.duration(until: t0.addingTimeInterval(-60), now: t0) == "now")

        // ---- The terminal tab title IS the session's name ----
        // The project column is only a directory name; three sessions in one repo match
        let orcaList = Data("""
        {"result":{"terminals":[
          {"handle":"term_a","title":"✳ 客户A回归缺陷跟进"},
          {"handle":"term_b","title":"◐ 🤖 20260915-new game"},
          {"handle":"term_c","title":"Terminal 1"},
          {"handle":"term_d"}
        ]}}
        """.utf8)
        let titles = TerminalTitles.parseOrca(orcaList)
        // A CJK title on purpose: tab titles are arbitrary user text, and the
        // glyph-stripping loop must not mangle multi-byte characters.
        t.check("a non-ASCII title survives parsing intact",
                titles["term_a"] == "客户A回归缺陷跟进")
        // Terminals prepend an ANIMATED status glyph; keeping it makes one session look
        // like it renames itself every second
        t.check("the animated status glyph is stripped",
                titles["term_b"] == "🤖 20260915-new game")
        t.check("a terminal with no title is skipped", titles["term_d"] == nil)
        t.check("another app's CLI changing shape degrades to no titles",
                TerminalTitles.parseOrca(Data("[]".utf8)).isEmpty)

        // A default name is not worth a hover and a bubble
        t.check("default terminal names are treated as useless",
                TerminalTitles.isUseless("Terminal 1") && TerminalTitles.isUseless("zsh")
                && TerminalTitles.isUseless("  "))
        t.check("a real name is not useless",
                !TerminalTitles.isUseless("release regression triage"))

        // An iTerm2 session has no title of its own — the tab does — so the script
        // emits id<TAB>title pairs
        let itermOut = "AB-CD\t✳ bug intake review\nEF-GH\tTerminal 2\nbroken line\n"
        let iterm = TerminalTitles.parseITerm(itermOut)
        t.check("iterm2 id/title pairs are parsed", iterm["AB-CD"] == "bug intake review")
        t.check("a malformed line is skipped rather than fatal", iterm.count == 2)

        // A second line is spent on the name only where a project is ambiguous
        let one = [session("a", .idle, prompt: nil)]
        t.check("a lone session needs no disambiguation",
                StateAggregator.ambiguousProjects(one).isEmpty)
        let twoSame = [
            SessionState(sessionId: "1", project: "daily_work", cwd: "/a", state: .idle,
                         tool: "", detail: "", since: t0, updatedAt: t0),
            SessionState(sessionId: "2", project: "daily_work", cwd: "/a", state: .idle,
                         tool: "", detail: "", since: t0, updatedAt: t0),
            SessionState(sessionId: "3", project: "multica", cwd: "/b", state: .idle,
                         tool: "", detail: "", since: t0, updatedAt: t0),
        ]
        t.check("only the shared project is flagged",
                StateAggregator.ambiguousProjects(twoSame) == ["daily_work"])

        // ---- PermissionRequest: say WHAT is blocked, not just that something is ----
        // The old signal was Notification's English copy — contains("waiting for
        // your input") — which fails silently the day that wording changes.
        t.check("a bash command is quoted back verbatim",
                PermissionSummary.describe(toolName: "Bash",
                                           toolInput: ["command": "rm -rf build/"])
                == "rm -rf build/")
        // A full path eats the whole bubble; the file name is what identifies it
        t.check("an edit names the file, not the path",
                PermissionSummary.describe(toolName: "Edit",
                                           toolInput: ["file_path": "/a/b/c/AppMain.swift"])
                == "Edit AppMain.swift")
        t.check("a fetch names the host",
                PermissionSummary.describe(toolName: "WebFetch",
                                           toolInput: ["url": "https://example.com/a/b?c=d"])
                == "WebFetch example.com")
        // A tool we do not special-case still names itself — better than "needs you"
        t.check("an unknown tool falls back to its own name",
                PermissionSummary.describe(toolName: "SomeNewTool", toolInput: [:])
                == "SomeNewTool")
        t.check("a tool with no name at all still yields something",
                PermissionSummary.describe(toolName: "", toolInput: [:]) == "permission")
        // A heredoc would otherwise turn the bubble into a paragraph
        t.check("newlines and runs of spaces collapse to one line",
                PermissionSummary.describe(toolName: "Bash",
                                           toolInput: ["command": "echo a\n\n   b\tc"])
                == "echo a b c")
        let long = String(repeating: "x", count: 200)
        let clamped2 = PermissionSummary.describe(toolName: "Bash", toolInput: ["command": long])
        t.check("a very long command is clamped with an ellipsis",
                clamped2.count == PermissionSummary.maxLength && clamped2.hasSuffix("…"))

        // ---- "which session just finished" ----
        func sess(_ id: String, _ act: SessionActivity, project: String = "p") -> SessionState {
            SessionState(sessionId: id, project: project, cwd: "/tmp", state: act, tool: "",
                         detail: "", since: t0, updatedAt: t0)
        }
        let wasBusy = GlobalState(mood: .busy, sessions: [sess("a", .busy), sess("b", .busy)],
                                  waitingProject: nil)
        let oneDone = GlobalState(mood: .busy, sessions: [sess("a", .idle), sess("b", .busy)],
                                  waitingProject: nil)
        t.check("the session that stopped is identified by id",
                Chatter.justFinished(previous: wasBusy, current: oneDone).map(\.sessionId) == ["a"])
        // A session that closed or was muted did not "finish" — it left
        let oneGone = GlobalState(mood: .busy, sessions: [sess("b", .busy)], waitingProject: nil)
        t.check("a session that disappeared is not reported as finished",
                Chatter.justFinished(previous: wasBusy, current: oneGone).isEmpty)
        // The project is a directory name shared by several sessions; the tab
        // title is what tells the user which one just came to rest
        t.check("the tab title is used when there is one",
                Chatter.doneLine([sess("a", .idle, project: "daily_work")],
                                 names: ["a": "email reply"]) == "email reply done")
        t.check("the project name is the fallback",
                Chatter.doneLine([sess("a", .idle, project: "daily_work")], names: [:])
                == "daily_work done")
        t.check("two at once are named, more than two are counted",
                Chatter.doneLine([sess("a", .idle), sess("b", .idle)], names: ["a": "x", "b": "y"])
                == "x, y done"
                && Chatter.doneLine([sess("a", .idle), sess("b", .idle), sess("c", .idle)],
                                    names: [:]).hasSuffix("3 sessions done"))

        // This is the point of the feature: it must get through even when a quota
        // line was said a minute ago, or the user would not hear about it
        let justSpoke = t0.addingTimeInterval(-60)
        t.check("a finished session is announced despite the global cooldown",
                Chatter.next(state: oneDone, previous: wasBusy, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: justSpoke)?.kind == .sessionDone)
        // But it still respects its own cooldown, so a flapping session cannot spam
        t.check("it stays quiet inside its own cooldown",
                Chatter.next(state: oneDone, previous: wasBusy, usage: nil, now: t0,
                             lastSpoken: [.sessionDone: t0.addingTimeInterval(-5)],
                             lastAnything: nil) == nil)

        t.finish()
    }
}
