import ClaudePetCore
import Foundation

/// Stop and background messages only act on a process that is surely the session, and only
/// interrupt a session that is surely between turns.
enum SessionControlTests {
    static func run(_ t: Harness) {
        print("\n-- session control (Stop, messages to background sessions)")
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        let fileB = Data(#"{"pid":42,"sessionId":"\#(b)","status":"idle"}"#.utf8)

        t.check("after /clear the process is the new session",
                SessionControl.processIsSession(b, sessionsFile: fileB, arguments: "claude --resume \(a)"))
        t.check("…and no longer the old one",
                !SessionControl.processIsSession(a, sessionsFile: fileB, arguments: "claude --resume \(a)"))
        t.check("a reused pid's file names its new owner, so the old record can't stop it",
                !SessionControl.processIsSession(a, sessionsFile: fileB, arguments: "claude"))
        t.check("without the file, a command line naming another session says no",
                !SessionControl.processIsSession(a, sessionsFile: nil, arguments: "claude --session-id \(b)"))
        t.check("without the file, a command line naming this session says yes",
                SessionControl.processIsSession(a, sessionsFile: nil, arguments: "claude --resume \(a)"))
        t.check("without the file or session flags, the pet's record decides",
                SessionControl.processIsSession(a, sessionsFile: nil, arguments: "claude"))
        t.check("an unreadable file is no file",
                SessionControl.processIsSession(a, sessionsFile: Data("{".utf8), arguments: nil))

        let out = #"[{"sessionId":"\#(a)","status":"Waiting"},{"sessionId":"\#(b)","status":"idle"}]"#
        t.check("a listed session's status is read (lowercased)",
                SessionControl.listing(exitStatus: 0, output: out, session: a) == .running(status: "waiting"))
        t.check("an unlisted session is absent",
                SessionControl.listing(exitStatus: 0, output: "[]", session: a) == .absent)
        t.check("a failed claude agents is unknown, not absent",
                SessionControl.listing(exitStatus: 1, output: "", session: a) == .unknown
                && SessionControl.listing(exitStatus: 0, output: "error: oops", session: a) == .unknown)
        t.check("only idle is between turns",
                SessionControl.betweenTurns("idle") && !SessionControl.betweenTurns("waiting")
                && !SessionControl.betweenTurns("busy") && !SessionControl.betweenTurns(""))
    }
}
