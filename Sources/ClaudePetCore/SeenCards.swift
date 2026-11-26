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

    /// `stored` with `changes` applied. A record is a patch: its fields replace the card's (the
    /// others stay), so two boards writing different fields of one card don't undo each other;
    /// null (NSNull) removes the card's record. What is out of bounds is left out, not fixed up:
    /// a long id, a patch that isn't an object or holds anything UserDefaults can't keep (a null
    /// inside it would make saving the store throw), a record past the size limit, a new card
    /// past the most cards.
    public static func merge(_ stored: [String: Any], _ changes: [String: Any]) -> [String: Any] {
        var out = stored
        for (id, record) in changes {
            guard !id.isEmpty, id.count <= maxIDLength else { continue }
            if record is NSNull { out[id] = nil; continue }
            guard let patch = record as? [String: Any] else { continue }
            var merged = out[id] as? [String: Any] ?? [:]
            for (k, v) in patch { merged[k] = v }
            guard PropertyListSerialization.propertyList(merged, isValidFor: .binary),
                  JSONSerialization.isValidJSONObject(merged),
                  let data = try? JSONSerialization.data(withJSONObject: merged),
                  data.count <= maxRecordBytes else { continue }
            guard out[id] != nil || out.count < maxCards else { continue }
            out[id] = merged
        }
        return out
    }
}
