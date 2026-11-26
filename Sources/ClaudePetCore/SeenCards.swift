import Foundation

/// What each task's card looked like when it was last opened on a board — the Mac's or any
/// phone's — so every board can mark what has changed on it since. One record for all of them:
/// a card read on the phone is read on the Mac too.
///
/// The page decides what a record holds (board.js, cardSnap); the app only keeps them, within
/// bounds a phone can't push it past.
public enum SeenCards {
    /// A task id the store accepts: hq's ids are short ("T-126").
    public static let maxIDLength = 40
    /// One card's record, as JSON.
    public static let maxRecordBytes = 4096
    /// Records kept at most. The page drops the ones whose task has left the board.
    public static let maxCards = 2000

    /// `stored` with `changes` applied: a record replaces the task's, null (NSNull) removes it.
    /// What is out of bounds — a long id, a record that isn't an object or is too big, past the
    /// most cards — is left out, not fixed up.
    public static func merge(_ stored: [String: Any], _ changes: [String: Any]) -> [String: Any] {
        var out = stored
        for (id, record) in changes {
            guard !id.isEmpty, id.count <= maxIDLength else { continue }
            if record is NSNull { out[id] = nil; continue }
            guard let dict = record as? [String: Any], JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  data.count <= maxRecordBytes else { continue }
            guard out[id] != nil || out.count < maxCards else { continue }
            out[id] = dict
        }
        return out
    }
}
