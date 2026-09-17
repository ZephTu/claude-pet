import Foundation

/// Adds and removes the pet's hooks in ~/.claude/settings.json.
///
/// That file drives every Claude Code session on the machine, so the rules here
/// are strict and deliberate:
///
///  - Pet hooks go into a NEW group appended to each event's array. No existing
///    group is ever reopened, so nothing the user already configured can be
///    disturbed by a bug in this code.
///  - A backup is written before the file is touched, and the result is parsed
///    back before it replaces the original. Anything wrong restores the backup.
///  - The write is atomic (temp file + rename), so a crash mid-write leaves the
///    original file untouched rather than truncated.
///  - Adding is idempotent: running it twice adds nothing the second time.
enum SettingsPatch {
    static let hookCommand = "$HOME/.claude/pet/pet-emit"
    /// The shell version shipped before the Swift rewrite. Uninstall and the
    /// idempotency check must recognise it too, or upgrading leaves a hook
    /// pointing at a script that is no longer there.
    static let legacyHookCommand = "$HOME/.claude/pet/pet-emit.sh"

    private static func isPetCommand(_ command: String?) -> Bool {
        command == hookCommand || command == legacyHookCommand
    }
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Notification", "PermissionRequest", "Stop", "SessionEnd",
        // Context compaction takes a while and produces no other events, so
        // without this the session looks like it stopped doing anything.
        "PreCompact",
    ]

    /// Returns a process exit code: 0 on success, 1 on failure.
    static func run(path: String, adding: Bool) -> Int32 {
        let url = URL(fileURLWithPath: path)

        var settings: [String: Any]
        if FileManager.default.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: url) else {
                report("cannot read \(path)")
                return 1
            }
            guard
                let parsed = try? JSONSerialization.jsonObject(with: data),
                let object = parsed as? [String: Any]
            else {
                report("\(path) is not a JSON object — left untouched")
                return 1
            }
            settings = object
        } else if adding {
            // A fresh Claude Code install may have no settings file yet.
            settings = [:]
        } else {
            report("no \(path) — nothing to remove")
            return 0
        }

        // Back up before touching anything, but only when there is a file to back up.
        var backup: URL?
        if FileManager.default.fileExists(atPath: path) {
            // Never overwrite an existing backup. The name carries a
            // seconds-resolution timestamp, so an install followed immediately
            // by an uninstall used to land on the same name — and the code
            // deleted the older file to make room, which threw away a backup of
            // the user's ORIGINAL settings and kept one of our own edit.
            let base = path + ".bak-claudepet-" + timestamp()
            var destination = URL(fileURLWithPath: base)
            var attempt = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = URL(fileURLWithPath: base + "-\(attempt)")
                attempt += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                backup = destination
                report("backed up -> \(destination.path)")
            } catch {
                report("backup failed, aborting: \(error.localizedDescription)")
                return 1
            }
        }

        let changed: [String]
        if adding {
            changed = addHooks(to: &settings)
        } else {
            changed = removeHooks(from: &settings)
        }

        guard
            let output = try? JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            report("could not serialise — original left untouched")
            return 1
        }

        // Parse the bytes we are about to install. If they are not valid JSON we
        // never write them, so there is nothing to roll back.
        guard (try? JSONSerialization.jsonObject(with: output)) != nil else {
            report("generated content is not valid JSON — original left untouched")
            return 1
        }

        guard atomicWrite(output, to: url) else {
            report("write failed")
            if let backup { restore(backup, to: url) }
            return 1
        }

        // Read it back from disk as the final check.
        guard
            let verify = try? Data(contentsOf: url),
            (try? JSONSerialization.jsonObject(with: verify)) != nil
        else {
            report("post-write check failed, rolling back")
            if let backup { restore(backup, to: url) }
            return 1
        }

        if changed.isEmpty {
            report(adding ? "(all hooks already present — no change)" : "(no pet hooks found — no change)")
        } else {
            report((adding ? "installed: " : "removed: ") + changed.joined(separator: ", "))
        }
        return 0
    }

    // MARK: - Mutation

    /// Appends one new group per event, skipping events that already carry the
    /// current command and rewriting ones that still carry the legacy shell
    /// command. Returns the events actually changed.
    ///
    /// The rewrite matters: an install over a previous shell-based install must
    /// not see the legacy entry, call it "already there", and leave the user
    /// with hooks pointing at a script that no longer exists.
    private static func addHooks(to settings: inout [String: Any]) -> [String] {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var touched: [String] = []

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []

            if groups.contains(where: { groupContains($0, command: hookCommand) }) {
                continue  // already current
            }

            if groups.contains(where: { groupContains($0, command: legacyHookCommand) }) {
                groups = groups.map { upgradeLegacy($0) }
                hooks[event] = groups
                touched.append(event)
                continue
            }

            groups.append(["hooks": [["type": "command", "command": hookCommand, "timeout": 5]]])
            hooks[event] = groups
            touched.append(event)
        }

        settings["hooks"] = hooks
        return touched
    }

    /// Replaces the legacy command in place, leaving every other field of the
    /// entry and every sibling entry untouched.
    private static func upgradeLegacy(_ group: [String: Any]) -> [String: Any] {
        guard let entries = group["hooks"] as? [[String: Any]] else { return group }
        var rebuilt = group
        rebuilt["hooks"] = entries.map { entry -> [String: Any] in
            guard (entry["command"] as? String) == legacyHookCommand else { return entry }
            var updated = entry
            updated["command"] = hookCommand
            return updated
        }
        return rebuilt
    }

    private static func groupContains(_ group: [String: Any], command: String) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains { ($0["command"] as? String) == command }
    }

    /// Strips the pet's hook entries, dropping a group only when the pet's entry
    /// was the sole reason it existed. A group the user configured — even an
    /// empty one — is left exactly as it was.
    private static func removeHooks(from settings: inout [String: Any]) -> [String] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var touched: [String] = []

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            var removedHere = false

            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)  // a group with no hooks array is the user's business
                    continue
                }
                let remaining = entries.filter { !isPetCommand($0["command"] as? String) }
                if remaining.count == entries.count {
                    kept.append(group)
                    continue
                }
                removedHere = true
                if remaining.isEmpty && entries.count == 1 {
                    continue  // the group existed only for the pet
                }
                var rebuilt = group
                rebuilt["hooks"] = remaining
                kept.append(rebuilt)
            }

            if removedHere { touched.append(event) }
            if kept.isEmpty && !groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return touched.sorted()
    }

    private static func groupContainsPetHook(_ group: [String: Any]) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains { isPetCommand($0["command"] as? String) }
    }

    // MARK: - IO

    /// Temp file plus rename: a crash mid-write cannot truncate the original.
    private static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let tmp = URL(fileURLWithPath: url.path + ".tmp")
        guard (try? data.write(to: tmp)) != nil else { return false }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil { return true }
        // replaceItemAt fails when the destination does not exist yet.
        if (try? FileManager.default.moveItem(at: tmp, to: url)) != nil { return true }
        try? FileManager.default.removeItem(at: tmp)
        return false
    }

    private static func restore(_ backup: URL, to url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: backup, to: url)
        report("restored from backup")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func report(_ line: String) {
        print(line)
    }
}
