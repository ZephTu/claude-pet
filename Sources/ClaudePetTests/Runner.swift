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

        t.check("the robot's torso is opaque", opaqueAt(-9, 6))
        t.check("the monitor is opaque", opaqueAt(30, 0))
        // The desk runs the full width of the drawing; the old circular region
        // left both of its ends unclickable.
        t.check("the desk's left end is opaque", opaqueAt(-44, 21))
        t.check("the desk's right end is opaque", opaqueAt(44, 21))
        // The bulb sits above the body box and is the brightest thing on screen;
        // without antennaBox it would look clickable and pass clicks through.
        t.check("the antenna bulb is opaque", opaqueAt(-8.7, -40.5))
        t.check("the top of the antenna is opaque", opaqueAt(-9, -49))
        t.check("above the antenna is transparent", !opaqueAt(-9, -56))
        // urgent lifts the figure 5pt; the head must stay reachable mid-jolt.
        t.check("the robot's head is opaque at rest", opaqueAt(-9, -18))
        t.check("the robot's head is still opaque lifted 5pt by the urgent jolt",
                opaqueAt(-9, -23))
        // Most of the window is transparent and must pass clicks through to whatever is under it
        // Mirrored layout: the pet moves to the window's left, so every box that
        // knows where it is has to move with it or the figure stops being
        // clickable exactly when it is nearest the screen edge.
        t.check("mirroring keeps the box the same size",
                PetLayout.mirrored(PetLayout.bodyBox).width == PetLayout.bodyBox.width
                && PetLayout.mirrored(PetLayout.bodyBox).height == PetLayout.bodyBox.height)
        // The assertion that matters, and the one an earlier version got wrong:
        // flipping MOVES the pet element, it does not mirror the drawing inside
        // it. So every box keeps its offset within the pet. Reflecting instead
        // gives the right answer for bodyBox — symmetric inside the pet — and
        // puts the antenna bulb outside its own hit region.
        for box in [PetLayout.bodyBox, PetLayout.antennaBox] {
            t.check("a mirrored box keeps its offset inside the pet",
                    PetLayout.mirrored(box).minX - PetLayout.mirroredPetBox.minX
                        == box.minX - PetLayout.petBox.minX)
        }
        // The panel and the pet must not overlap at either width — this is what
        // stops a wider panel from creeping under the figure.
        let panelRight: CGFloat = 2 + 310
        t.check("the panel stops short of the pet",
                panelRight < PetLayout.petBox.minX)
        t.check("and the mirrored panel does too",
                PetLayout.windowSize.width - panelRight > PetLayout.mirroredPetBox.maxX)

        t.check("the mirrored boxes stay inside the mirrored pet",
                PetLayout.mirroredPetBox.contains(PetLayout.mirrored(PetLayout.bodyBox))
                && PetLayout.mirroredPetBox.contains(PetLayout.mirrored(PetLayout.antennaBox)))
        // Not an involution, and it should not be: this maps normal → flipped,
        // and the pet only ever moves in that one direction.
        t.check("everything shifts by exactly the pet's own displacement",
                PetLayout.mirrored(PetLayout.bodyBox).minX - PetLayout.bodyBox.minX
                    == PetLayout.mirroredPetBox.minX - PetLayout.petBox.minX)
        t.check("the antenna stays above the body after mirroring",
                PetLayout.mirrored(PetLayout.antennaBox).maxY
                    >= PetLayout.mirrored(PetLayout.bodyBox).minY)
        let mirroredBody = PetLayout.mirrored(PetLayout.bodyBox)
        t.check("a point on the mirrored body is opaque only when mirrored",
                PetLayout.isOpaque(at: CGPoint(x: mirroredBody.midX, y: mirroredBody.midY),
                                   panel: nil, bubble: nil, mirrored: true)
                && !PetLayout.isOpaque(at: CGPoint(x: mirroredBody.midX, y: mirroredBody.midY),
                                       panel: nil, bubble: nil, mirrored: false))

        // Flipping is decided by whether the panel would fall off the screen,
        // and only done when flipping actually helps.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        t.check("a window well inside the screen does not flip",
                !PetLayout.shouldMirror(windowOrigin: CGPoint(x: 600, y: 100),
                                        visibleFrame: screen))
        t.check("a window hanging off the left flips",
                PetLayout.shouldMirror(windowOrigin: CGPoint(x: -120, y: 100),
                                       visibleFrame: screen))
        // A window wider than what is left of the screen cannot be helped by
        // flipping — it would only move the problem to the other edge.
        t.check("flipping is skipped when it would not help",
                !PetLayout.shouldMirror(windowOrigin: CGPoint(x: -120, y: 100),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 260, height: 900)))

        // The flip has to hold the PET still. It slides the drawing 320pt across
        // the window, and at the left edge that is a leap straight out of view —
        // which is exactly what dragging the pet to the left edge used to do.
        t.check("flipping moves the window by the width the drawing moves",
                PetLayout.flipShift(toMirrored: true) == 320
                    && PetLayout.flipShift(toMirrored: false) == -320)

        // ...and having moved the window, the rule must not change its mind.
        // Reading the WINDOW's origin, it would: the shifted window is back
        // inside the screen, so the next answer is "unmirror", which shifts it
        // out again — a pet flapping between two places forever.
        let off = CGPoint(x: -120, y: 100)
        let flipped = CGPoint(x: off.x + PetLayout.flipShift(toMirrored: true), y: off.y)
        t.check("a window that flipped and moved stays flipped",
                PetLayout.shouldMirror(windowOrigin: flipped, visibleFrame: screen,
                                       mirrored: true))
        t.check("and the pet is in the same place before and after the flip",
                off.x + PetLayout.petBox.minX
                    == flipped.x + PetLayout.mirroredPetBox.minX)

        // Coming back the other way it does unflip — once there is room for the
        // panel on the left again, plus the hysteresis band. "Room" is measured
        // from the PET: the panel lives in the 340pt to its left.
        func mirroredWindow(petLeftAt x: CGFloat) -> CGPoint {
            CGPoint(x: x - PetLayout.mirroredPetBox.minX, y: 100)
        }
        t.check("dragged back towards the middle, it flips back",
                !PetLayout.shouldMirror(windowOrigin: mirroredWindow(petLeftAt: 420),
                                        visibleFrame: screen, mirrored: true))
        t.check("but not while it is still sitting on the line",
                PetLayout.shouldMirror(windowOrigin: mirroredWindow(petLeftAt: 350),
                                       visibleFrame: screen, mirrored: true))

        // Unplugging a display, or a resolution change, can leave the pet
        // outside every screen. Only the PET has to be rescued, not the whole
        // window — most of it is transparent, and insisting all 400pt fit would
        // stop the pet ever sitting near an edge.
        let desk = CGRect(x: 0, y: 0, width: 1440, height: 875)
        t.check("a pet already on screen is left where the user put it",
                PetLayout.rescued(windowOrigin: CGPoint(x: 900, y: 100),
                                  visibleFrame: desk) == nil)
        t.check("a pet off the right edge is pulled back",
                PetLayout.rescued(windowOrigin: CGPoint(x: 1400, y: 100),
                                  visibleFrame: desk) != nil)
        t.check("a pet below the screen is pulled back",
                PetLayout.rescued(windowOrigin: CGPoint(x: 900, y: -400),
                                  visibleFrame: desk) != nil)
        // The rescue has to actually land it on screen, not merely move it.
        if let fixed = PetLayout.rescued(windowOrigin: CGPoint(x: 1400, y: -400),
                                         visibleFrame: desk) {
            t.check("a rescued window puts the pet fully back on screen",
                    PetLayout.rescued(windowOrigin: fixed, visibleFrame: desk) == nil)
        } else {
            t.check("a rescued window puts the pet fully back on screen", false)
        }
        // A window whose left 280pt hang off the screen is FINE: that part is
        // transparent. Rescuing it would be the bug.
        t.check("transparent margin hanging off an edge is not a reason to move",
                PetLayout.rescued(windowOrigin: CGPoint(x: -240, y: 100),
                                  visibleFrame: desk) == nil)

        t.check("beyond the desk's left end is transparent", !opaqueAt(-54, 21))
        t.check("beyond the desk's right end is transparent", !opaqueAt(54, 21))
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
        // The percentage no longer decides this — QuotaAlarm does, on crossing a
        // threshold — so Chatter only relays an alarm it is handed.
        t.check("a high percentage alone no longer says anything",
                Chatter.next(state: quiet, previous: quiet, usage: high, now: t0,
                             lastSpoken: [:], lastAnything: nil) == nil)
        t.check("but an alarm handed in is relayed",
                Chatter.next(state: quiet, previous: quiet, usage: high, now: t0,
                             lastSpoken: [:], lastAnything: nil,
                             quotaAlarm: QuotaAlarm.Alarm(window: .sevenDay, threshold: 85,
                                                          percent: 85, resetsIn: "1d 0h"))?
                    .kind == .quotaHigh)
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
        // justStarted is what retires the sticky "done" bubble: the user typing
        // at any session again means they are past needing to be told
        t.check("a session going back to work is spotted",
                Chatter.justStarted(previous: oneDone, current: wasBusy).map(\.sessionId) == ["a"])
        t.check("nothing starting reads as nothing starting",
                Chatter.justStarted(previous: wasBusy, current: wasBusy).isEmpty)
        // A brand new session counts as started — it was not busy before because
        // it did not exist, and the user did just type at it
        let plusNew = GlobalState(mood: .busy, sessions: [sess("a", .busy), sess("b", .busy),
                                                          sess("c", .busy)], waitingProject: nil)
        t.check("a session that appeared already busy counts as started",
                Chatter.justStarted(previous: wasBusy, current: plusNew).map(\.sessionId) == ["c"])
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
        // The name is what the eye should land on, not the word "done"
        t.check("the single finished session's name is marked for emphasis",
                Chatter.next(state: oneDone, previous: wasBusy, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil,
                             names: ["a": "email reply"])?.emphasis == "email reply")
        // Two names cannot be one contiguous styled run, so nothing is marked
        let twoDone = GlobalState(mood: .idle, sessions: [sess("a", .idle), sess("b", .idle)],
                                  waitingProject: nil)
        t.check("two at once mark nothing, since the run would be discontiguous",
                Chatter.next(state: twoDone, previous: wasBusy, usage: nil, now: t0,
                             lastSpoken: [:], lastAnything: nil,
                             names: ["a": "x", "b": "y"])?.emphasis == "")
        // Whatever is emphasised has to actually occur in the text, or the page
        // silently falls back to plain rendering
        let done1 = Chatter.next(state: oneDone, previous: wasBusy, usage: nil, now: t0,
                                 lastSpoken: [:], lastAnything: nil, names: ["a": "email reply"])
        t.check("the emphasised run is a substring of the line",
                done1.map { $0.text.contains($0.emphasis) } == true)
        // But it still respects its own cooldown, so a flapping session cannot spam
        t.check("it stays quiet inside its own cooldown",
                Chatter.next(state: oneDone, previous: wasBusy, usage: nil, now: t0,
                             lastSpoken: [.sessionDone: t0.addingTimeInterval(-5)],
                             lastAnything: nil) == nil)

        // A "done" line is the one the user is actually waiting for, and they
        // are looking at a terminal, not at the corner of the screen. It has no
        // expiry of its own; everything else takes itself away.
        t.check("only the done line is sticky",
                Chatter.Kind.allCases.filter(Chatter.isSticky) == [.sessionDone])

        // ---- CompletionQueue: finishes must survive not being shown ----
        // The bug this exists for: a finish that happens while another session is
        // blocked, or inside the speech cooldown, was dropped outright — because
        // the only record of it was the difference between two snapshots, and
        // lastState advanced regardless.
        func ev(_ sid: String, _ turn: String, _ at: TimeInterval,
                project: String = "api", name: String = "") -> CompletionEvent {
            CompletionEvent(sessionId: sid, turnKey: turn, project: project,
                            displayName: name.isEmpty ? project : name,
                            finishedAt: t0.addingTimeInterval(at))
        }

        t.check("the event id is derived from session and turn, not from chance",
                ev("a", "T1", 0).eventId == ev("a", "T1", 99).eventId
                && ev("a", "T1", 0).eventId != ev("a", "T2", 0).eventId
                && ev("a", "T1", 0).eventId != ev("b", "T1", 0).eventId)

        // Delivering the same Stop twice must not produce two rows.
        t.check("the same turn recorded twice collapses to one",
                CompletionQueue.dedupe([ev("a", "T1", 0), ev("a", "T1", 5)]).count == 1)
        t.check("two turns of one session stay separate",
                CompletionQueue.dedupe([ev("a", "T1", 0), ev("a", "T2", 5)]).count == 2)

        let blobs: [Data] = [
            Data(#"{"sessionId":"a","turnKey":"T1","project":"api","displayName":"api","finishedAt":"2026-09-17T10:00:00Z"}"#.utf8),
            Data("not json at all".utf8),
            Data(#"{"sessionId":"","turnKey":"T2","project":"x","displayName":"x","finishedAt":"2026-09-17T10:00:01Z"}"#.utf8),
            Data(#"{"sessionId":"b","turnKey":"T1","project":"web","displayName":"web","finishedAt":"garbage"}"#.utf8),
        ]
        let decoded = CompletionQueue.decode(blobs)
        t.check("a corrupt file does not take the queue down with it",
                decoded.map(\.sessionId) == ["a"])

        let read: Set<String> = [ev("a", "T1", 0).eventId]
        t.check("read events are filtered out",
                CompletionQueue.unread([ev("a", "T1", 0), ev("a", "T2", 1)], read: read)
                    .map(\.turnKey) == ["T2"])

        // Retention: 7 days, 500 rows, read rows go first.
        let staleTurn = ev("a", "OLD", -8 * 24 * 3600)
        let freshTurn = ev("a", "NEW", -60)
        let aged = CompletionQueue.prune([staleTurn, freshTurn], read: [], now: t0)
        t.check("anything past the retention window is dropped",
                aged.keep.map(\.turnKey) == ["NEW"] && aged.droppedUnread == 1)

        var many: [CompletionEvent] = []
        for i in 0..<(CompletionQueue.hardLimit + 40) {
            many.append(ev("a", "T\(i)", -Double(CompletionQueue.hardLimit + 40 - i)))
        }
        // The read rows sit in the MIDDLE, not at the front. If they were the
        // oldest, "drop read first" and "drop oldest first" would be the same
        // policy and this assertion would prove nothing.
        let readIds = Set(many[100..<140].map(\.eventId))
        let capped = CompletionQueue.prune(many, read: readIds, now: t0)
        t.check("the cap is met by dropping read rows first",
                capped.keep.count == CompletionQueue.hardLimit
                && capped.droppedRead == 40 && capped.droppedUnread == 0)
        // The proof it spent the read rows and not simply the oldest ones.
        t.check("the oldest unread row survives while read rows are spent",
                capped.keep.first?.turnKey == many.first?.turnKey)

        // Nothing read: the cap can only be met by dropping unread, and that has
        // to be reported rather than done quietly.
        let cappedAllUnread = CompletionQueue.prune(many, read: [], now: t0)
        t.check("dropping unread to meet the cap is counted, not silent",
                cappedAllUnread.keep.count == CompletionQueue.hardLimit
                && cappedAllUnread.droppedUnread == 40)
        t.check("the rows kept under pressure are the newest ones",
                cappedAllUnread.keep.last?.turnKey == many.last?.turnKey)

        // ---- PanelModel: what the user sees, and what survives a session ----
        func panelSess(_ id: String, _ act: SessionActivity, project: String,
                       ago: TimeInterval = 0, terminal: TerminalRef? = nil) -> SessionState {
            SessionState(sessionId: id, project: project, cwd: "/tmp", state: act, tool: "",
                         detail: "", since: t0.addingTimeInterval(-ago), updatedAt: t0,
                         terminal: terminal)
        }
        let liveA = panelSess("a", .idle, project: "api",
                              terminal: TerminalRef(kind: "orca", handle: "h-a"))
        let waitingB = panelSess("b", .waiting, project: "web", ago: 300)
        let waitingC = panelSess("c", .waiting, project: "cli", ago: 60)

        t.check("the longest wait is dealt with first",
                PanelModel.needsYou([waitingC, waitingB, liveA]).map(\.sessionId) == ["b", "c"])
        t.check("everything else stays in the other group",
                PanelModel.others([waitingC, waitingB, liveA]).map(\.sessionId) == ["a"])

        // Four turns of one session are one thing to look at, not four.
        let fourTurns = (1...4).map {
            CompletionEvent(sessionId: "a", turnKey: "T\($0)", project: "api",
                            displayName: "api",
                            finishedAt: t0.addingTimeInterval(Double($0) * 60))
        }
        let folded = PanelModel.completionRows(fourTurns, live: [liveA])
        t.check("several turns of one session fold into one row",
                folded.count == 1 && folded[0].count == 4)
        t.check("the folded row carries every id, so one click clears them all",
                folded[0].eventIds.count == 4)
        t.check("a row for a live session with a terminal can be jumped to",
                folded[0].canJump && !folded[0].sessionClosed)

        // The case the queue exists for: the session is gone, the work still
        // happened, and the row must not pretend it can jump there.
        let orphan = PanelModel.completionRows(fourTurns, live: [])
        t.check("a finish outlives its session", orphan.count == 1)
        t.check("an orphaned row is marked closed and cannot be jumped to",
                orphan[0].sessionClosed && !orphan[0].canJump)
        t.check("an orphaned row keeps the name it had when it finished",
                orphan[0].label == "api")

        t.check("a live row prefers the terminal tab title",
                PanelModel.completionRows(fourTurns, live: [liveA],
                                          titles: ["h-a": "email reply"])[0].label == "email reply")
        t.check("a useless tab title is not preferred over the recorded name",
                PanelModel.completionRows(fourTurns, live: [liveA],
                                          titles: ["h-a": "Terminal 1"])[0].label == "api")

        // Newest session first, so what just happened is at the top.
        let older = CompletionEvent(sessionId: "z", turnKey: "T1", project: "old",
                                    displayName: "old", finishedAt: t0)
        t.check("the most recently finished session leads",
                PanelModel.completionRows(fourTurns + [older], live: [])
                    .map(\.sessionId) == ["a", "z"])

        // The second line must not repeat what the first column already says.
        t.check("the name is not printed twice",
                !PanelModel.shouldShowNameInline(displayed: "email reply",
                                                 title: "email reply", ambiguous: true))
        t.check("but it is shown when the first column says something else",
                PanelModel.shouldShowNameInline(displayed: "my alias",
                                                title: "email reply", ambiguous: true))
        t.check("and never when the project is unambiguous anyway",
                !PanelModel.shouldShowNameInline(displayed: "daily_work",
                                                 title: "email reply", ambiguous: false))
        t.check("a useless title is not worth a second line",
                !PanelModel.shouldShowNameInline(displayed: "daily_work",
                                                 title: "Terminal 1", ambiguous: true))

        // The click that had no effect: a row whose terminal is gone used to
        // explain itself and leave the badge exactly where it was.
        t.check("a finished row with a live terminal is opened, then cleared",
                PanelModel.finishedClick(handle: "h-a") == .openThenRead)
        t.check("a finished row with nowhere to jump is cleared by the click itself",
                PanelModel.finishedClick(handle: "") == .read)

        t.check("nothing to report means no badge at all",
                PanelModel.badge(needsYou: 0, unreadFinishes: 0) == "")
        t.check("the badge counts both kinds of attention",
                PanelModel.badge(needsYou: 2, unreadFinishes: 3) == "5")
        t.check("a runaway count is capped rather than widening the badge",
                PanelModel.badge(needsYou: 0, unreadFinishes: 140) == "99+")

        // Read marks must not outlive the events they acknowledge.
        let marks: Set<String> = ["a#T1", "a#T2", "gone#T9"]
        t.check("marks for events that aged out are dropped",
                ReadMarks.compact(marks, keeping: fourTurns) == ["a#T1", "a#T2"])
        t.check("marks survive a round trip through disk",
                ReadMarks.decode(ReadMarks.encode(marks)) == marks)
        t.check("a corrupt marks file reads as nothing acknowledged",
                ReadMarks.decode(Data("{{{".utf8)).isEmpty)

        // ---- Snooze: postponing one item, not silencing a session ----
        let blocked = panelSess("s", .waiting, project: "api", ago: 120)
        let snoozed = [blocked.sessionId: Snooze.mark(for: blocked, minutes: 15, now: t0)]

        t.check("a postponed wait is quiet",
                Snooze.isSnoozed(blocked, marks: snoozed, now: t0.addingTimeInterval(60)))
        t.check("it comes back when the delay is up",
                !Snooze.isSnoozed(blocked, marks: snoozed, now: t0.addingTimeInterval(16 * 60)))
        t.check("a session with no mark is never quiet",
                !Snooze.isSnoozed(panelSess("other", .waiting, project: "x"),
                                  marks: snoozed, now: t0))

        // The rule that separates this from muting: postponing THIS approval
        // must not also postpone the next, different one.
        let newItem = panelSess("s", .waiting, project: "api", ago: 1)
        t.check("a different wait on the same session does not inherit the delay",
                !Snooze.isSnoozed(newItem, marks: snoozed, now: t0.addingTimeInterval(60)))

        t.check("a postponed row says how much longer",
                Snooze.remaining(blocked, marks: snoozed, now: t0.addingTimeInterval(60)) == "14m")
        t.check("a row that is not postponed says nothing rather than 0m",
                Snooze.remaining(newItem, marks: snoozed, now: t0).isEmpty)

        // Waking from sleep must not replay anything: expiry is judged against
        // now, so a mark that elapsed while asleep is simply already gone.
        t.check("a delay that elapsed during sleep is just over",
                Snooze.pruned(snoozed, keeping: [blocked], now: t0.addingTimeInterval(86_400))
                    .isEmpty)
        t.check("a mark for a departed session is dropped",
                Snooze.pruned(snoozed, keeping: [], now: t0).isEmpty)
        t.check("a mark whose item was resolved is dropped",
                Snooze.pruned(snoozed, keeping: [newItem], now: t0).isEmpty)
        t.check("a live mark survives pruning",
                Snooze.pruned(snoozed, keeping: [blocked], now: t0).count == 1)

        // Aggregation: postponed means quiet, NOT gone. Muting is what makes a
        // session disappear; these two must not blur into each other.
        let quietened = StateAggregator.aggregate([blocked], now: t0.addingTimeInterval(60),
                                                  snoozed: snoozed, isLive: { _, _ in true })
        t.check("a postponed wait stops driving the mood",
                quietened.mood == .idle && quietened.waitingProject == nil)
        t.check("but the session is still listed — postponed is not hidden",
                quietened.sessions.map(\.sessionId) == ["s"])
        let unquietened = StateAggregator.aggregate([blocked], now: t0.addingTimeInterval(16 * 60),
                                                    snoozed: snoozed, isLive: { _, _ in true })
        t.check("once the delay is up it drives the mood again",
                unquietened.mood == .urgent)

        // The shortcut lands on the most neglected item, postponed ones skipped.
        let jumpable = panelSess("j", .waiting, project: "api", ago: 500,
                                 terminal: TerminalRef(kind: "orca", handle: "h-j"))
        t.check("the shortcut goes to the longest-ignored wait",
                PanelModel.jumpTarget([blocked, jumpable], snoozed: [:], now: t0)?
                    .sessionId == "j")
        t.check("a postponed wait is skipped over",
                PanelModel.jumpTarget([blocked, jumpable],
                                      snoozed: [jumpable.sessionId:
                                        Snooze.mark(for: jumpable, minutes: 15, now: t0)],
                                      now: t0)?.sessionId == "s")
        t.check("nothing waiting means no target rather than a wrong one",
                PanelModel.jumpTarget([panelSess("r", .busy, project: "x")],
                                      snoozed: [:], now: t0) == nil)
        // A target we cannot address is still the target: sending the user to a
        // different session and letting them think that was the blocked one is
        // worse than saying we cannot get there.
        t.check("an unreachable wait is still reported as the target",
                PanelModel.jumpTarget([blocked], snoozed: [:], now: t0)?.sessionId == "s")

        t.check("marks survive a round trip through disk",
                Snooze.decode(Snooze.encode(snoozed)) == snoozed)
        t.check("a corrupt snooze file reads as nothing postponed",
                Snooze.decode(Data("]]".utf8)).isEmpty)

        // ---- ActivitySummary: what is running, without keeping secrets ----
        t.check("a plain command keeps its first words",
                ActivitySummary.safeCommand("npm test") == "npm test"
                && ActivitySummary.safeCommand("git status") == "git status")
        t.check("the program's path is reduced to its name",
                ActivitySummary.safeCommand("/usr/local/bin/swift build") == "swift build")
        // The rule that matters: this string is written to disk and kept for a
        // day, so it stops at the first word that could be carrying a value.
        t.check("a flag stops the summary before its value",
                ActivitySummary.safeCommand("curl -H Authorization:Bearer_abc123 https://x")
                    == "curl …")
        t.check("an assignment stops it too",
                ActivitySummary.safeCommand("env API_KEY=sk-live-9999 ./deploy") == "env …")
        t.check("a quoted argument stops it",
                ActivitySummary.safeCommand("psql -c \"select * from users\"") == "psql …")
        t.check("a pipe stops it",
                ActivitySummary.safeCommand("cat secrets.env | grep TOKEN")
                    == "cat secrets.env …")
        // A long path is kept as its last component rather than thrown away:
        // "cd …" is safe and useless, "cd claude-pet" is safe and tells you
        // which directory without saying where it lives.
        t.check("a long path is reduced to its last component, not dropped",
                ActivitySummary.safeCommand("cd /Users/me/Documents/Code_Projects/claude-pet")
                    == "cd claude-pet")
        t.check("but a long path carrying something odd is still stopped",
                ActivitySummary.safeCommand("cd /a/b/c?token=abc123def456ghi789jkl") == "cd …")
        t.check("an empty command summarises to nothing",
                ActivitySummary.safeCommand("   ").isEmpty)
        // Not a denylist: a secret nobody thought to name is still withheld.
        t.check("an unnamed secret is withheld as well",
                !ActivitySummary.safeCommand("./upload --to s3 hunter2_xyz").contains("hunter2"))

        t.check("a file tool names its file, not its path",
                ActivitySummary.target(toolName: "Edit",
                                       toolInput: ["file_path": "/a/b/PetLayout.swift"])
                    == "PetLayout.swift")
        t.check("a fetch names its host, not the query string",
                ActivitySummary.target(toolName: "WebFetch",
                                       toolInput: ["url": "https://api.example.com/x?token=abc"])
                    == "api.example.com")
        t.check("an unknown tool carries no argument at all",
                ActivitySummary.target(toolName: "SomethingNew",
                                       toolInput: ["secret": "x"]).isEmpty)
        t.check("a tool with no target still names itself",
                ActivitySummary.phrase(toolName: "Task", target: "") == "Task")
        t.check("reading tools read, editing tools type",
                ActivitySummary.motion(forTool: "Read") == .reading
                && ActivitySummary.motion(forTool: "Grep") == .reading
                && ActivitySummary.motion(forTool: "Edit") == .writing
                && ActivitySummary.motion(forTool: "Write") == .writing)
        // Anything unrecognised waits rather than pretending to know: an
        // unknown tool's behaviour is exactly what we cannot guess.
        t.check("an unknown tool waits rather than being guessed at",
                ActivitySummary.motion(forTool: "Bash") == .awaiting
                && ActivitySummary.motion(forTool: "mcp__something__new") == .awaiting
                && ActivitySummary.motion(forTool: "") == .awaiting)
        t.check("parallel calls are counted rather than listed",
                ActivitySummary.concurrent(3) == "3 tools running"
                && ActivitySummary.concurrent(1).isEmpty)

        // ---- SessionLabels: naming and pinning, per session not per folder ----
        let twinA = panelSess("t1", .idle, project: "daily_work",
                              terminal: TerminalRef(kind: "orca", handle: "h1"))
        let twinB = panelSess("t2", .idle, project: "daily_work",
                              terminal: TerminalRef(kind: "orca", handle: "h2"))
        var prefs: [String: SessionLabels.Prefs] = [
            "t1": SessionLabels.Prefs(alias: "email reply", pinned: true),
        ]
        t.check("the user's own name wins over everything",
                SessionLabels.displayName(for: twinA, prefs: prefs, title: "some tab")
                    == "email reply")
        t.check("the tab title is next",
                SessionLabels.displayName(for: twinB, prefs: prefs, title: "regression triage")
                    == "regression triage")
        t.check("a useless tab title falls through to the project",
                SessionLabels.displayName(for: twinB, prefs: prefs, title: "Terminal 1")
                    == "daily_work")
        // Two sessions in one folder are two things. Keying by path would give
        // both of them the same name and pin both when one was pinned.
        t.check("naming one twin does not name the other",
                SessionLabels.displayName(for: twinB, prefs: prefs) == "daily_work")
        t.check("pinning one twin does not pin the other",
                SessionLabels.isPinned(twinA, prefs: prefs)
                && !SessionLabels.isPinned(twinB, prefs: prefs))

        t.check("a pinned session rises within its group",
                SessionLabels.ordered([twinB, twinA], prefs: prefs).map(\.sessionId)
                    == ["t1", "t2"])
        t.check("order is otherwise left exactly as handed in",
                SessionLabels.ordered([twinB, twinA], prefs: [:]).map(\.sessionId)
                    == ["t2", "t1"])

        t.check("an alias is kept to one line and a sane length",
                SessionLabels.sanitiseAlias("two\nlines") == "two lines"
                && SessionLabels.sanitiseAlias(String(repeating: "x", count: 99)).count
                    == SessionLabels.maxAliasLength)
        prefs["gone"] = SessionLabels.Prefs(alias: "x")
        t.check("preferences for departed sessions are dropped",
                SessionLabels.pruned(prefs, keeping: [twinA, twinB]).keys.sorted() == ["t1"])
        t.check("preferences survive a round trip",
                SessionLabels.decode(SessionLabels.encode(prefs))["t1"]?.alias == "email reply")
        t.check("a corrupt preferences file reads as no preferences",
                SessionLabels.decode(Data("nope".utf8)).isEmpty)

        // Branch names come from reading .git/HEAD, not from running git: a hook
        // fires on every event and cannot afford a subprocess.
        t.check("a branch is read straight out of HEAD",
                GitLabel.branch(fromHEAD: "ref: refs/heads/main\n") == "main")
        t.check("a slashed branch keeps its whole name",
                GitLabel.branch(fromHEAD: "ref: refs/heads/feat/claude-pet\n")
                    == "feat/claude-pet")
        t.check("a detached HEAD shows a short sha",
                GitLabel.branch(fromHEAD: "9d6c0c8f1234567890abcdef\n") == "9d6c0c8")
        t.check("garbage in HEAD yields no branch rather than nonsense",
                GitLabel.branch(fromHEAD: "not a ref at all").isEmpty)
        t.check("the default branch is not worth a badge",
                !GitLabel.isWorthShowing("main") && !GitLabel.isWorthShowing("master")
                && GitLabel.isWorthShowing("feat/x"))

        // ---- HealthReport: five states, because a tick and a cross are not
        // enough to tell "never turned on" from "turned on and broken" ----
        t.check("a missing Claude Code is the one thing worth alarming about",
                HealthReport.claudeCode(version: "", path: "").status == .needsAttention)
        t.check("a found one reports version and path",
                HealthReport.claudeCode(version: "2.1.0", path: "/usr/bin/claude").status == .ok)

        t.check("no hooks is not set up, not broken",
                HealthReport.hooks(installed: 0, expected: 8, binaryExists: true).status
                    == .notConfigured)
        t.check("a partial install does need attention",
                HealthReport.hooks(installed: 5, expected: 8, binaryExists: true).status
                    == .needsAttention)
        t.check("hooks pointing at a missing binary need attention",
                HealthReport.hooks(installed: 8, expected: 8, binaryExists: false).status
                    == .needsAttention)
        t.check("a full install is fine",
                HealthReport.hooks(installed: 8, expected: 8, binaryExists: true).status == .ok)

        // Nothing arriving is never reported as "stuck": whether silence is a
        // problem depends on whether anything should have been talking.
        t.check("silence with nothing running is simply not set up yet",
                HealthReport.recentEvents(lastAt: nil, liveSessions: 0, now: t0).status
                    == .notConfigured)
        t.check("silence WITH sessions running is unknown, not broken",
                HealthReport.recentEvents(lastAt: nil, liveSessions: 2, now: t0).status
                    == .unknown)
        t.check("and it explains the usual cause rather than blaming the install",
                HealthReport.recentEvents(lastAt: nil, liveSessions: 2, now: t0).detail
                    .contains("started after installing"))
        t.check("recent traffic is fine",
                HealthReport.recentEvents(lastAt: t0.addingTimeInterval(-30),
                                          liveSessions: 1, now: t0).status == .ok)

        t.check("processes we have not heard from are explained, not alarmed about",
                HealthReport.sessions(running: 3, known: 1).status == .unknown)
        t.check("an unreadable state file is skipped, not called broken",
                HealthReport.stateFiles(writable: true, count: 9, corrupt: 1).status == .unknown)
        t.check("an unwritable directory does need attention",
                HealthReport.stateFiles(writable: false, count: 0, corrupt: 0).status
                    == .needsAttention)
        t.check("no addressable terminal is unsupported, not a fault",
                HealthReport.terminals(kinds: [], lastFailure: "").status == .unsupported)
        t.check("a failed jump needs attention and says why",
                HealthReport.terminals(kinds: ["orca"], lastFailure: "permission denied").detail
                    .contains("permission denied"))
        t.check("no quota source is not set up",
                HealthReport.usage(source: "", capturedAt: nil, now: t0, stale: false).status
                    == .notConfigured)
        t.check("a stale reading is unknown rather than reported as current",
                HealthReport.usage(source: "claude-hud", capturedAt: t0.addingTimeInterval(-9000),
                                   now: t0, stale: true).status == .unknown)

        // The summary is meant to be pasted into an issue, so it must not carry
        // the user's home directory.
        let home = NSHomeDirectory()
        t.check("a home directory is collapsed in the pasteable summary",
                !HealthReport.summary([
                    HealthReport.claudeCode(version: "2.1.0", path: home + "/bin/claude")
                ]).contains(home))
        t.check("and the path is still recognisable afterwards",
                HealthReport.summary([
                    HealthReport.claudeCode(version: "2.1.0", path: home + "/bin/claude")
                ]).contains("~/bin/claude"))

        // ---- Usage sources: never blend two, never guess a rolled-over window ----
        func usageSnap(_ source: String, capturedAgo: TimeInterval, fiveIn: TimeInterval = 3600,
                  weekIn: TimeInterval = 86_400, five: Int = 40) -> UsageSnapshot {
            UsageSnapshot(planName: "max", fiveHourPercent: five, sevenDayPercent: 55,
                          fiveHourResetAt: t0.addingTimeInterval(fiveIn),
                          sevenDayResetAt: t0.addingTimeInterval(weekIn),
                          capturedAt: t0.addingTimeInterval(-capturedAgo), source: source)
        }
        let fresh1 = usageSnap("claude-hud", capturedAgo: 60)
        let fresh2 = usageSnap("statusline", capturedAgo: 120)
        t.check("between two usable readings the better source wins",
                UsageSources.pick([fresh1, fresh2], now: t0)?.source == "statusline")
        // Freshness beats rank: a stale reading from a better source is still
        // describing a window that may have rolled over.
        let staleBetter = usageSnap("statusline", capturedAgo: 9000)
        t.check("a stale reading does not outrank a fresh one",
                UsageSources.pick([fresh1, staleBetter], now: t0)?.source == "claude-hud")
        t.check("with nothing usable the newest is still handed back, to be labelled old",
                UsageSources.pick([staleBetter], now: t0)?.source == "statusline")
        // The statusline payload's shape is NOT verified against a live
        // payload — see StatuslineUsage — so the parser accepts several
        // spellings and, crucially, returns nil rather than a wrong number.
        let sl = Data(#"{"rate_limits":{"five_hour":{"used_pct":31,"resets_at":"2026-09-17T12:00:00Z"},"seven_day":{"used_pct":58,"resets_at":"2026-09-21T00:00:00Z"}}}"#.utf8)
        t.check("a statusline payload is captured and labelled with its source",
                StatuslineUsage.parse(sl, now: t0)?.fiveHourPercent == 31
                && StatuslineUsage.parse(sl, now: t0)?.source == "statusline")
        t.check("camelCase spellings are accepted too",
                StatuslineUsage.parse(
                    Data(#"{"rate_limits":{"fiveHour":{"usedPct":10,"resetsAt":"2026-09-17T12:00:00Z"},"sevenDay":{"usedPct":20,"resetsAt":"2026-09-21T00:00:00Z"}}}"#.utf8),
                    now: t0)?.fiveHourPercent == 10)
        t.check("an unrecognised shape yields nothing rather than a wrong number",
                StatuslineUsage.parse(Data(#"{"rate_limits":{"mystery":{"x":1}}}"#.utf8), now: t0) == nil
                && StatuslineUsage.parse(Data("not json".utf8), now: t0) == nil
                && StatuslineUsage.parse(Data("{}".utf8), now: t0) == nil)
        t.check("a captured reading survives a round trip through its cache file",
                StatuslineUsage.decode(StatuslineUsage.encode(StatuslineUsage.parse(sl, now: t0)!))?
                    .sevenDayPercent == 58)

        t.check("no sources at all means no reading",
                UsageSources.pick([], now: t0) == nil)

        // The rule that stops a wrong number being shown confidently.
        let rolled = usageSnap("claude-hud", capturedAgo: 60, fiveIn: -60)
        t.check("a window that has rolled over is spotted",
                rolled.fiveHourWindowRolledOver(now: t0)
                && !rolled.sevenDayWindowRolledOver(now: t0))
        let rowsAfterRollover = Chatter.quotaRows(usage: rolled, now: t0)
        t.check("its meter is dropped rather than shown at the old number",
                rowsAfterRollover.map(\.label) == ["week"])
        // Not replaced with 0% either: the user may have spent plenty of the new
        // window already, and inventing a number is the failure being avoided.
        t.check("and it is not replaced by a made-up zero",
                !rowsAfterRollover.contains { $0.percent == 0 })
        t.check("a live window is still reported",
                Chatter.quotaRows(usage: fresh1, now: t0).map(\.label) == ["5h", "week"])

        // ---- ActivityLog: what already ran, and what it is allowed to claim ----
        func act(_ tool: String, _ target: String, ago: TimeInterval, ms: Int = 1200,
                 result: ActivityEntry.Result = .ok) -> ActivityEntry {
            ActivityEntry(tool: tool, target: target, finishedAt: t0.addingTimeInterval(-ago),
                          durationMs: ms, result: result)
        }
        t.check("a call reads as what it did and how long it took",
                act("Bash", "npm test", ago: 0, ms: 2900).line() == "Bash npm test · 2.9s")
        t.check("a sub-second call is not rounded to 0.0s",
                act("Read", "x.swift", ago: 0, ms: 57).line() == "Read x.swift · 57ms")
        t.check("only an interruption is called out",
                act("Bash", "x", ago: 0, result: .interrupted).line().contains("interrupted")
                && !act("Bash", "x", ago: 0, result: .unknown).line().contains("interrupted"))

        let log = [act("Bash", "a", ago: 10), act("Read", "b", ago: 5),
                   act("Edit", "c", ago: 25 * 3600)]
        t.check("the newest call leads and anything past a day is gone",
                ActivityLog.recent(log, now: t0).map(\.target) == ["b", "a"])
        t.check("the list is capped",
                ActivityLog.recent(Array(repeating: act("Bash", "x", ago: 1), count: 50),
                                   now: t0).count == ActivityLog.shown)

        t.check("entries survive a round trip",
                ActivityLog.decode(String(data: ActivityLog.encode(log[0]), encoding: .utf8)!)
                    == [log[0]])
        // A hook can be killed mid-write, so a torn last line is normal.
        let torn = String(data: ActivityLog.encode(log[0]), encoding: .utf8)! + "{\"tool\":\"Ba"
        t.check("a half-written last line costs only that line",
                ActivityLog.decode(torn).count == 1)
        t.check("a log of pure garbage reads as empty, not as a crash",
                ActivityLog.decode("nonsense\nmore nonsense").isEmpty)

        // One chatty session must not push every other session's history out.
        t.check("the budget is shared out, not first-come",
                ActivityLog.perSessionBudget(sessionCount: 10) == 200
                && ActivityLog.perSessionBudget(sessionCount: 0) == ActivityLog.totalCap)
        t.check("a busy machine still leaves each session a readable amount",
                ActivityLog.perSessionBudget(sessionCount: 500) == ActivityLog.shown)

        // ---- SessionDetail: what hovering a row is actually for ----
        let hovered = SessionState(
            sessionId: "h", project: "multica", cwd: NSHomeDirectory() + "/Documents/multica",
            state: .busy, tool: "Bash", detail: "", since: t0.addingTimeInterval(-720),
            updatedAt: t0.addingTimeInterval(-3))
        let hoverInsight = SessionInsight(sessionId: "h", sessionName: "email reply",
                                     modelName: "Opus 5", contextPercent: 43,
                                     worktree: "feat-x", capturedAt: t0)
        let hoverLast = ActivityEntry(tool: "Bash", target: "npm test",
                                 finishedAt: t0.addingTimeInterval(-3),
                                 durationMs: 2900, result: .ok)
        let hoverDetail = SessionDetail.detail(session: hovered, insight: hoverInsight,
                                               lastActivity: hoverLast, now: t0)
        t.check("the home directory is collapsed, not spelled out",
                hoverDetail.path == "~/Documents/multica")
        t.check("the worktree is its own field, not glued into the path",
                hoverDetail.worktree == "feat-x")
        t.check("context arrives as a number the page can draw a bar with",
                hoverDetail.contextPercent == 43 && hoverDetail.model == "Opus 5")
        t.check("the turn's own age is reported", hoverDetail.turn == "12m")
        t.check("and what it last did",
                hoverDetail.last == "Bash npm test · 2.9s" && !hoverDetail.lastBad)

        // Without a statusline wired up there is simply less to report — never
        // an empty field pretending to be a value.
        let hoverBare = SessionDetail.detail(session: hovered, insight: nil,
                                             lastActivity: nil, now: t0)
        t.check("no statusline means no context and no model, not zero",
                hoverBare.contextPercent == nil && hoverBare.model.isEmpty)
        t.check("but there is still something worth showing",
                !hoverBare.isEmpty && !hoverBare.path.isEmpty)
        // A stale reading is withheld: the statusline only runs while Claude
        // Code is drawing, so a quiet session's number is from whenever it last
        // was not quiet.
        let staleInsight = SessionInsight(sessionId: "h", contextPercent: 90,
                                          capturedAt: t0.addingTimeInterval(-9000))
        t.check("a stale context reading is withheld rather than shown as current",
                SessionDetail.detail(session: hovered, insight: staleInsight,
                                     lastActivity: nil, now: t0).contextPercent == nil)
        // "quiet" only appears once the session has actually gone quiet.
        let hoverFreshTurn = SessionState(
            sessionId: "h", project: "p", cwd: "", state: .busy, tool: "", detail: "",
            since: t0.addingTimeInterval(-5), updatedAt: t0)
        t.check("a session that just moved is not described as quiet",
                SessionDetail.detail(session: hoverFreshTurn, insight: nil,
                                     lastActivity: nil, now: t0).quiet.isEmpty)
        t.check("an interrupted last call is marked as such",
                SessionDetail.detail(
                    session: hovered, insight: nil,
                    lastActivity: ActivityEntry(tool: "Bash", target: "x", finishedAt: t0,
                                                durationMs: 10, result: .interrupted),
                    now: t0).lastBad)

        // The statusline payload's real shape, from Claude Code's own docs.
        let hoverPayload = Data(#"{"session_id":"s1","session_name":"email reply","model":{"display_name":"Opus 5"},"workspace":{"git_worktree":"feat-x"},"context_window":{"used_percentage":42.7},"rate_limits":{"five_hour":{"used_percentage":31,"resets_at":1789650000}}}"#.utf8)
        let hoverParsed = SessionInsights.parse(hoverPayload, now: t0)
        t.check("context percent is read and rounded", hoverParsed?.contextPercent == 43)
        t.check("the session's own name and model come through",
                hoverParsed?.sessionName == "email reply" && hoverParsed?.modelName == "Opus 5")
        // null used_percentage means "no messages yet", which is not 0%.
        t.check("no messages yet reads as unknown, not as empty",
                SessionInsights.parse(Data(#"{"session_id":"s","context_window":{"used_percentage":null}}"#.utf8),
                                      now: t0)?.contextPercent == nil)
        t.check("a payload with no session id yields nothing",
                SessionInsights.parse(Data(#"{"context_window":{"used_percentage":5}}"#.utf8), now: t0) == nil)
        t.check("an insight survives a round trip",
                SessionInsights.decode(SessionInsights.encode(hoverInsight)) == hoverInsight)
        // Each rate-limit window is independently optional per the docs.
        t.check("one window alone is still a usable reading",
                StatuslineUsage.parse(hoverPayload, now: t0)?.fiveHourPercent == 31)

        // ---- QuotaAlarm: crossing a line, not sitting above one ----
        func quotaAt(five: Int, week: Int, fiveIn: TimeInterval = 3600,
                   weekIn: TimeInterval = 4 * 86400) -> UsageSnapshot {
            UsageSnapshot(planName: "max", fiveHourPercent: five, sevenDayPercent: week,
                          fiveHourResetAt: t0.addingTimeInterval(fiveIn),
                          sevenDayResetAt: t0.addingTimeInterval(weekIn),
                          capturedAt: t0, source: "statusline")
        }

        let belowAll = QuotaAlarm.evaluate(usage: quotaAt(five: 40, week: 30),
                                        alreadySaid: [], now: t0)
        t.check("below every threshold it says nothing", belowAll.speak == nil)

        let firstEighty = QuotaAlarm.evaluate(usage: quotaAt(five: 82, week: 30),
                                              alreadySaid: [], now: t0)
        t.check("crossing 80% on the five-hour window is worth one line",
                firstEighty.speak?.window == .fiveHour && firstEighty.speak?.threshold == 80)
        // The whole point: having said it, sitting above it says nothing more.
        let stillEighty = QuotaAlarm.evaluate(usage: quotaAt(five: 88, week: 30),
                                              alreadySaid: firstEighty.markSaid, now: t0)
        t.check("staying above the same threshold is not news again",
                stillEighty.speak == nil)
        let ninetyFive = QuotaAlarm.evaluate(usage: quotaAt(five: 96, week: 30),
                                             alreadySaid: firstEighty.markSaid, now: t0)
        t.check("but the next threshold up is",
                ninetyFive.speak?.threshold == 95)

        // Leapfrogging: 70 -> 96 is one warning, and 80 must not resurface later.
        let leap = QuotaAlarm.evaluate(usage: quotaAt(five: 96, week: 30),
                                       alreadySaid: [], now: t0)
        t.check("a jump past two thresholds says the higher one once",
                leap.speak?.threshold == 95 && leap.markSaid.count == 2)
        t.check("and the skipped threshold never surfaces afterwards",
                QuotaAlarm.evaluate(usage: quotaAt(five: 96, week: 30),
                                    alreadySaid: leap.markSaid, now: t0).speak == nil)

        // The weekly window warns earlier — running it out costs days, not hours.
        let weekEarly = QuotaAlarm.evaluate(usage: quotaAt(five: 40, week: 68),
                                            alreadySaid: [], now: t0)
        t.check("weekly warns at 65% where five-hour would say nothing",
                weekEarly.speak?.window == .sevenDay && weekEarly.speak?.threshold == 65)
        t.check("and it names itself as the weekly one",
                weekEarly.speak?.text.contains("weekly") == true)

        // A reset rearms everything, because the reset instant is in the key.
        let eightySaid = firstEighty.markSaid
        let afterReset = QuotaAlarm.evaluate(
            usage: quotaAt(five: 82, week: 30, fiveIn: 6 * 3600), alreadySaid: eightySaid, now: t0)
        t.check("a window that has reset warns again",
                afterReset.speak?.threshold == 80)

        // A window whose reset has already passed is not a window.
        t.check("a rolled-over window raises nothing",
                QuotaAlarm.evaluate(usage: quotaAt(five: 99, week: 10, fiveIn: -60),
                                    alreadySaid: [], now: t0).speak == nil)
        t.check("a stale reading raises nothing either",
                QuotaAlarm.evaluate(
                    usage: UsageSnapshot(planName: "", fiveHourPercent: 99, sevenDayPercent: 99,
                                         fiveHourResetAt: t0.addingTimeInterval(3600),
                                         sevenDayResetAt: t0.addingTimeInterval(86400),
                                         capturedAt: t0.addingTimeInterval(-9000)),
                    alreadySaid: [], now: t0).speak == nil)
        t.check("no reading at all raises nothing",
                QuotaAlarm.evaluate(usage: nil, alreadySaid: [], now: t0).speak == nil)

        // Keys for periods that have ended cannot match again, so they go.
        let oldKey = QuotaAlarm.key(window: .fiveHour,
                                    resetAt: t0.addingTimeInterval(-3600), threshold: 80)
        let liveKey = QuotaAlarm.key(window: .fiveHour,
                                     resetAt: t0.addingTimeInterval(3600), threshold: 80)
        t.check("keys for finished periods are pruned away",
                QuotaAlarm.pruned([oldKey, liveKey], now: t0) == [liveKey])

        // ---- Background work: a turn ending is not the work ending ----
        let bgRaw: [[String: Any]] = [
            ["id": "1", "type": "subagent", "status": "running",
             "description": "Audit CORE-16919 against the merge gate",
             "agent_type": "merge-gate-audit-agent"],
            ["id": "2", "type": "shell", "status": "running",
             "description": "dev server", "command": "npm run dev"],
            ["id": "3", "type": "workflow", "status": "pending",
             "description": "spec review", "name": "spec"],
            ["id": "4", "type": "monitor", "status": "running",
             "description": "watching CI", "server": "ci", "tool": "watch"],
        ]
        let bgTasks = BackgroundWork.parse(bgRaw)
        t.check("every in-flight task is read", bgTasks.count == 4)
        let bgWaking = BackgroundWork.waking(bgTasks)
        t.check("only agents and workflows hold the turn open",
                bgWaking.map(\.type) == ["subagent", "workflow"])
        // The label is a structural name. The description is free text the user
        // was working on and the command is a shell line; neither may leak into
        // a bubble the pet shows on screen.
        t.check("an agent is named by its type",
                bgWaking.first?.label == "merge-gate-audit-agent")
        t.check("a workflow is named by its workflow name",
                bgWaking.last?.label == "spec")
        t.check("no label carries the free-text description",
                bgTasks.allSatisfy { !$0.label.contains(" ") })
        t.check("a task with no type at all is dropped",
                BackgroundWork.parse([["id": "x", "status": "running"]]).isEmpty)
        t.check("an absent background_tasks reads as nothing in flight",
                BackgroundWork.parse(nil).isEmpty)
        t.check("one agent is named", BackgroundWork.phrase(["auditor"]) == "waiting for auditor")
        t.check("several are counted",
                BackgroundWork.phrase(["a", "b"]) == "waiting for 2 background agents")
        t.check("none says nothing at all", BackgroundWork.phrase([]).isEmpty)

        // ---- One figure, several sessions: which phase does the pet show ----
        func phased(_ phase: String, running: [RunningTool] = []) -> SessionState {
            SessionState(sessionId: "p" + phase, project: "p", cwd: "/tmp", state: .busy,
                         tool: "", detail: "", since: t1, updatedAt: t0,
                         running: running, phase: phase)
        }
        let busyTool = RunningTool(id: "r", tool: "Bash", target: "swift build", since: t0)
        t.check("waiting on an agent is shown when that is all that is happening",
                StateAggregator.phase([phased("awaiting-agent")]) == "awaiting-agent")
        // The regression this guards: drawing the pet sitting and watching while
        // another session is typing tells the user about the quieter of the two.
        t.check("a session with a tool in flight outranks one waiting on an agent",
                StateAggregator.phase([phased("awaiting-agent"),
                                       phased("", running: [busyTool])]).isEmpty)
        t.check("compaction wins outright, brief and rare as it is",
                StateAggregator.phase([phased("awaiting-agent"),
                                       phased("compacting", running: [busyTool])]) == "compacting")
        t.check("no phase at all is the ordinary case",
                StateAggregator.phase([phased("")]).isEmpty)

        // ---- Skins: five pictures for eleven states ----
        t.check("an unknown skin name falls back to the one that always draws",
                PetSkin.named("weasel") == .robot && PetSkin.named(nil) == .robot)
        t.check("a known one is kept", PetSkin.named("cat") == .cat)

        func look(_ mood: String, phase: String = "", flash: String = "",
                  wanted: Bool = false, blockedOn: String = "") -> CatSkin.Look {
            CatSkin.look(mood: mood, phase: phase, flash: flash, wanted: wanted,
                         blockedOn: blockedOn)
        }
        // The cost of taking the lamp away, written down as a test rather than
        // left as a surprise: the three busy states are one picture and say
        // exactly the same thing. Anyone who makes them differ again has to
        // come here and say how.
        t.check("every busy state draws the same picture",
                [look("busy"), look("busy", phase: "compacting"),
                 look("busy", phase: "awaiting-agent")].allSatisfy { $0.pose == .working })
        t.check("...and with no lamp, nothing tells the three apart",
                look("busy") == look("busy", phase: "compacting")
                    && look("busy") == look("busy", phase: "awaiting-agent"))

        t.check("wanting approval and wanting an answer share the one picture",
                look("waiting").pose == .waiting
                    && look("waiting", blockedOn: "rm -rf build/").pose == .waiting)
        // The bug this replaced: one texture with a question mark painted into
        // it served both, so the cat held up a paw under a QUESTION MARK while
        // asking permission to run `rm -rf`. A question mark says "I am
        // unsure"; approval says "you decide".
        t.check("...and the glyph is what tells them apart",
                look("waiting").mark == .question
                    && look("waiting", blockedOn: "rm -rf build/").mark == .warn)
        t.check("a session that wants nothing shows no glyph",
                look("busy").mark == .none && look("idle").mark == .none)
        // urgent already has an alarm painted into its own texture; a second
        // glyph beside it would be two warnings for one thing.
        t.check("being ignored does not add a second warning",
                look("urgent", blockedOn: "rm -rf build/").mark == .none)
        t.check("an interrupted tool warns over a cat that is still working",
                look("busy", flash: "trouble").mark == .warn
                    && look("busy", flash: "trouble").pose == .working)
        // A finished turn has no picture, so the renderer bobs the idle one.
        // Nothing else may replace the pose: an interrupted tool happens while
        // the session carries on, and swapping the picture would say it stopped.
        t.check("a finished turn gets the bob", look("idle", flash: "done").pose == .finished)
        t.check("and nothing else does",
                CatSkin.flashPose("done") == .finished && CatSkin.flashPose("trouble") == nil)
        t.check("being ignored has its own", look("urgent").pose == .urgent)

        // The kit's two resting pictures, earning their keep.
        t.check("a desk with something unread stays awake", look("idle", wanted: true).pose == .idle)
        t.check("a desk with nothing on it sleeps", look("idle").pose == .sleeping)

        // The two states with NO picture of their own, now that the lamp is not
        // there to carry them: a finished turn has to reach the bob and an
        // interrupted tool has to reach the glyph, or the cat stops reporting
        // the one thing this project exists for.
        t.check("a finished turn survives without a lamp",
                look("idle", flash: "done").pose == .finished)
        t.check("an interrupted tool survives without a lamp",
                look("busy", flash: "trouble").mark == .warn)
        t.check("a transient outranks the state it happens during",
                look("busy", phase: "compacting", flash: "done").pose == .finished)

        // Hit regions: two shapes, two answers. A cat clickable in the robot's
        // rectangle is a cat with a dead head and a live patch of desk.
        let catHead = CGPoint(x: 400, y: 152)      // high in the cat, above the robot's box
        t.check("the cat is clickable where the cat is",
                PetLayout.isOpaque(at: catHead, panel: nil, bubble: nil, skin: .cat))
        t.check("...and the robot is not, because nothing is drawn there",
                !PetLayout.isOpaque(at: catHead, panel: nil, bubble: nil, skin: .robot))
        t.check("the robot's antenna is still its own box",
                PetLayout.isOpaque(at: CGPoint(x: 390, y: 154), panel: nil, bubble: nil,
                                   skin: .robot))
        t.check("both skins are clickable where both are drawn",
                PetLayout.isOpaque(at: PetLayout.petCenter, panel: nil, bubble: nil, skin: .cat)
                    && PetLayout.isOpaque(at: PetLayout.petCenter, panel: nil, bubble: nil,
                                          skin: .robot))
        t.check("the cat's box moves with a mirrored layout too",
                PetLayout.isOpaque(at: CGPoint(x: PetLayout.catBodyBox.midX - 320,
                                               y: PetLayout.catBodyBox.midY),
                                   panel: nil, bubble: nil, mirrored: true, skin: .cat))

        // Resting the pointer and clicking have to ask the same question. The
        // quota readout asked the robot's rectangle whatever was drawn, so the
        // cat's lower quarter was clickable and hoverless at the same time.
        let catPaws = CGPoint(x: 400, y: 240)      // low in the cat, below the robot's desk
        t.check("resting on the cat's paws counts as resting on the pet",
                PetLayout.isOnPet(catPaws, skin: .cat))
        t.check("...and on the robot the same point is not the pet at all",
                !PetLayout.isOnPet(catPaws, skin: .robot))
        t.check("the middle of the figure is the pet in either skin",
                PetLayout.isOnPet(PetLayout.petCenter, skin: .cat)
                    && PetLayout.isOnPet(PetLayout.petCenter, skin: .robot))
        // Same translation the hit region uses: the pet moved, so the question
        // "is the pointer on it" has to move with it.
        t.check("a mirrored layout moves what counts as the pet",
                PetLayout.isOnPet(CGPoint(x: PetLayout.petCenter.x - 320,
                                          y: PetLayout.petCenter.y),
                                  skin: .cat, mirrored: true)
                    && !PetLayout.isOnPet(PetLayout.petCenter, skin: .cat, mirrored: true))

        t.finish()
    }
}
