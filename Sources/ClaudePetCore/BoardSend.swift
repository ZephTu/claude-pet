import Foundation

/// The pure parts of typing a board message into a session's terminal (BoardBridge.send).
public enum BoardSend {
    /// The message as it is typed: one line, with nothing that a terminal would act on.
    ///
    /// Lines are joined with spaces (a newline would submit early). Every other C0 control
    /// character except tab, and DEL, is removed: typed into the tab, ESC would start an escape
    /// sequence — even end the bracketed paste the text is wrapped in — and ^C, ^D, ^U… would
    /// act as keys in Claude Code's input.
    public static func typeable(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(String.UnicodeScalarView(flat.unicodeScalars.filter { s in
            s == "\t" || (s.value >= 0x20 && s.value != 0x7F)
        }))
    }

    /// Orca's `terminal send --json` receipt for an agent prompt lists the stages it has seen:
    /// `input_accepted`, then `turn_started`. True when there is such a receipt and it stops short
    /// of a turn (typed, but not shown to have gone in — `--wait-submit` timing out still exits
    /// 0). False for anything else: an older Orca without receipts, or output that isn't JSON.
    public static func orcaTurnUnproven(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        func receipt(_ v: Any) -> [String: Any]? {
            if let d = v as? [String: Any] {
                if d["stages"] is [String] { return d }
                for x in d.values { if let r = receipt(x) { return r } }
            } else if let a = v as? [Any] {
                for x in a { if let r = receipt(x) { return r } }
            }
            return nil
        }
        guard let r = receipt(root), let stages = r["stages"] as? [String] else { return false }
        if let provider = r["provider"] as? String, provider == "old-host" || provider == "unsupported" { return false }
        return !stages.contains("turn_started")
    }

    /// Does typing this text start a turn the board can watch for? A slash command runs inside
    /// Claude Code and a `!` line runs in its shell mode; neither submits a prompt, so the
    /// pet's `lastPromptAt` would never move and waiting for it would only report a false error.
    public static func startsTurn(_ text: String) -> Bool {
        !(text.hasPrefix("/") || text.hasPrefix("!"))
    }

    /// How long iTerm2 waits between the text and its Return: long enough for Claude Code to
    /// have taken the whole text in, so the Return is a key of its own. 0.3 s, plus about 1 s
    /// per 20,000 characters, at most 1.5 s.
    public static func returnDelay(characters: Int) -> Double {
        min(1.5, 0.3 + Double(max(0, characters)) / 20_000)
    }

    /// `returnDelay` as an AppleScript number (always with a dot, whatever the locale).
    public static func returnDelayLiteral(characters: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), returnDelay(characters: characters))
    }

    /// The AppleScript expression for `literal` (already passed through
    /// `IdleTab.appleScriptLiteral`) wrapped in bracketed-paste markers, ESC[200~ … ESC[201~.
    /// Claude Code then takes the text as one paste, and the key after the end marker as a key —
    /// a Return there submits instead of becoming a newline in the input. ESC is built with
    /// `character id 27` outside the literal, so neither the literal's escaping nor `typeable`
    /// (which runs on the user's text before this) can remove the markers.
    public static func bracketedPaste(literal: String) -> String {
        #"(character id 27) & "[200~" & "\#(literal)" & (character id 27) & "[201~""#
    }

    /// Must the board refuse to type into a session in this state? A session waiting on a
    /// permission prompt or a question menu takes typed keys as the answer: the Return would
    /// pick the highlighted option ("Yes") for something the user has not seen.
    public static func refuses(state: SessionActivity?) -> Bool {
        state == .waiting
    }

    /// May the board press Esc in this session's terminal? Only mid-turn: there Esc interrupts
    /// the turn (on a prompt it declines it, as in the terminal). Between turns it would do
    /// nothing useful, and a second one opens Claude Code's rewind menu, out of the board's sight.
    /// `claudeStatus` is Claude Code's own status for the session (`ClaudeSessionStatus`), which
    /// turns "idle" the moment a turn ends — an Esc included — while the pet's record stays
    /// "busy" until it notices. Nil when it can't be read: the pet's state decides alone, and
    /// `quiet` (StateAggregator.isQuiet — no Stop hook comes after an Esc) rules out a turn that
    /// already ended. Not `waiting`: an Esc there would decline a prompt the user never saw.
    public static func mayInterrupt(state: SessionActivity?, claudeStatus: String? = nil, quiet: Bool = false) -> Bool {
        state == .busy && !quiet && claudeStatus != "idle"
    }

    /// Slash commands that open a menu in the terminal when given no argument. Typed from the
    /// board, the session would sit in that menu where the board can't see it, so the board
    /// sends them only with an argument (`/model opus`, which switches without a menu).
    public static let menuWithoutArgument: Set<String> = ["/model"]

    /// Would typing this open a terminal menu the board can't answer?
    public static func opensMenu(_ text: String) -> Bool {
        menuWithoutArgument.contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
