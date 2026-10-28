import Foundation

/// LOCAL PATCH: what `<petHome>/config.json` explicitly says.
///
/// This type only reads and writes the file; it holds no defaults. A switch
/// the file says nothing usable about — no file, an unreadable file, a missing
/// key, a value that is not a JSON boolean — comes back as nil, and what nil
/// means is decided by pet-emit, which owns the defaults (EmitDefaults). The
/// file only overrides them.
///
/// pet-emit — a separate process Claude Code starts for every event — only
/// ever reads the file; the app is the only writer.
public struct PetConfig: Equatable, Sendable {
    /// Record each finished tool call under `activity/` (what the row hover
    /// shows as the last tool call). nil: the file does not say.
    public var recordActivity: Bool?

    public init(recordActivity: Bool? = nil) {
        self.recordActivity = recordActivity
    }

    public static let fileName = "config.json"
    public static let recordActivityKey = "recordActivity"

    public static func url(petHome: URL) -> URL { petHome.appending(path: fileName) }

    /// Never throws and never writes: the hook calls this on every finished
    /// tool call.
    public static func load(petHome: URL) -> PetConfig {
        guard let object = readObject(petHome: petHome) else { return PetConfig() }
        return PetConfig(recordActivity: boolValue(object[recordActivityKey]))
    }

    /// Only a JSON boolean counts — not `1`, not `"true"`.
    static func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// A config is a few bytes; anything bigger is not one.
    public static let maxBytes = 64 * 1024

    /// The file as a JSON object; nil when it is missing, not an object, or not
    /// a small regular file. The type and size checks keep a hook from blocking
    /// on a FIFO or reading a device that was put in its place.
    static func readObject(petHome: URL) -> [String: Any]? {
        let target = url(petHome: petHome).resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxBytes,
              let data = try? Data(contentsOf: target)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// App side. Sets one switch and keeps everything else in the file, keys the
    /// user added by hand included. A file that cannot be read is moved aside to
    /// `config.json.invalid-<time>` rather than overwritten; earlier set-aside
    /// copies are never replaced.
    @discardableResult
    public static func set(_ key: String, to value: Any, petHome: URL) -> Bool {
        var object = existingOrSetAside(petHome: petHome)
        object[key] = value
        return write(object, petHome: petHome)
    }

    /// App side. Writes an explicit choice; turning recording off also deletes
    /// what was already recorded, so that "off" leaves nothing of this kind on
    /// disk.
    public static func setRecordActivity(_ on: Bool, petHome: URL) {
        set(recordActivityKey, to: on, petHome: petHome)
        if !on { clearActivity(petHome: petHome) }
    }

    /// Deletes the recorded activity. The app calls it while recording is in
    /// effect off: a hook that read the old value just before recording was
    /// turned off can still append one entry after the toggle.
    public static func clearActivity(petHome: URL) {
        try? FileManager.default.removeItem(at: petHome.appending(path: "activity"))
    }

    private static func existingOrSetAside(petHome: URL) -> [String: Any] {
        let fm = FileManager.default
        let path = url(petHome: petHome)
        guard fm.fileExists(atPath: path.path) else { return [:] }
        if let object = readObject(petHome: petHome) { return object }
        try? fm.moveItem(at: path, to: asideURL(petHome: petHome))
        return [:]
    }

    /// A fresh name every time, so an earlier set-aside copy is never replaced.
    static func asideURL(petHome: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = fileName + ".invalid-" + formatter.string(from: Date())
        var candidate = petHome.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = petHome.appending(path: base + "-\(n)")
            n += 1
        }
        return candidate
    }

    /// Atomic (write-then-rename), so the hook never reads half a file. Written
    /// through a symlink to its target, so a config kept elsewhere (dotfiles)
    /// stays linked instead of being replaced by a copy.
    @discardableResult
    private static func write(_ object: [String: Any], petHome: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        try? FileManager.default.createDirectory(at: petHome, withIntermediateDirectories: true)
        let target = url(petHome: petHome).resolvingSymlinksInPath()
        return (try? data.write(to: target, options: .atomic)) != nil
    }
}
