import Foundation

/// What a session row is allowed to SAY, as opposed to what the hook sent.
///
/// Claude Code's `Notification` hook fires with a fixed English sentence —
/// "Claude is waiting for your input" — and the panel used to print it verbatim
/// on the second line of every blocked row. With three sessions blocked that is
/// the same sentence three times, under three rows whose first line already says
/// they are waiting: the most repeated text in the panel carried the least
/// information in it.
///
/// So the row's second line is reserved for something the first line does not
/// already show, and boilerplate is dropped rather than echoed. The raw text is
/// untouched on `SessionState.detail` — the health window and any future
/// debugging still see exactly what arrived.
///
/// Matching on English copy is fragile, which is why nothing STRUCTURAL depends
/// on it: `PermissionSummary`'s note about `contains("waiting for your input")`
/// stands, and waiting is still decided from the structured `PermissionRequest`
/// event. The only thing at stake here is whether one line of text is hidden. If
/// Anthropic rewords the notification tomorrow, the sentence comes back on the
/// second line — today's behaviour — and nothing breaks.
public enum SessionCopy {
    /// Notification sentences that tell the row nothing it is not already
    /// showing. Compared case-insensitively against whitespace-collapsed text.
    static let boilerplate: [String] = [
        "claude is waiting for your input",
        "claude needs your permission to use",
        "claude is waiting for you",
    ]

    /// Collapses runs of whitespace so a wrapped or re-indented hook message
    /// still matches.
    static func normalise(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Is this notification text pure boilerplate?
    ///
    /// Prefix rather than equality for the permission sentence: it ends with the
    /// tool's name, which `waitingOn` already reports in a more useful form.
    public static func isBoilerplate(_ detail: String) -> Bool {
        let text = normalise(detail)
        guard !text.isEmpty else { return false }
        return boilerplate.contains { text == $0 || text.hasPrefix($0) }
    }

    /// The second line of a session row: one fact the first line does not carry,
    /// or nothing at all.
    ///
    /// A blocked session's most useful second line is WHAT it wants approved —
    /// `waitingOn` is the structured summary of that, already clamped and
    /// stripped of full paths by `PermissionSummary`. A session blocked on an
    /// answer rather than a permission has no such summary, and its hook text is
    /// the boilerplate above, so it correctly ends up with no second line: the
    /// branch and the session title still get theirs.
    ///
    /// - Parameters:
    ///   - state: the session's activity.
    ///   - detail: the raw `Notification` message.
    ///   - waitingOn: `PermissionSummary.describe` output, empty when the
    ///     session is not blocked on a permission.
    public static func note(state: SessionActivity, detail: String,
                            waitingOn: String) -> String {
        if state == .waiting, !waitingOn.isEmpty { return waitingOn }
        return isBoilerplate(detail) ? "" : detail
    }

    /// Has this blocked session been waiting long enough to be called out?
    ///
    /// Deliberately the SAME threshold the pet's own alarm uses, so the panel
    /// and the figure never disagree about which session is the urgent one.
    public static func isUrgent(waitedFor seconds: TimeInterval) -> Bool {
        seconds > StateAggregator.urgentAfter
    }
}
