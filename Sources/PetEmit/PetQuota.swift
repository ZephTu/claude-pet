import ClaudePetCore
import Foundation

/// The quota reading for a shell that is not the Mac app (the Windows spike): what the Mac's
/// sampleUsage does, run on the watcher's tick. Up to three sources (claude-hud's old cache,
/// claude-hud's `externalUsageWritePath` snapshot, `pet-emit --statusline`), never blended,
/// picked by UsageSources; which one is newest is learned by watching (UsageRecency) and kept in
/// `usage-seen.json` across restarts. The Mac app does not use it.
struct PetQuota {
    private var recency: UsageRecency
    private var last: UsageSnapshot?
    private let petHome = HookEmit.baseDirectory
    private var seenURL: URL { petHome.appending(path: "usage-seen.json") }
    private var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    init(now: Date = Date()) {
        let saved = (try? Data(contentsOf: HookEmit.baseDirectory.appending(path: "usage-seen.json")))
        recency = saved.flatMap { UsageRecency(saved: $0, now: now) } ?? UsageRecency()
    }

    mutating func sample(now: Date) -> UsageSnapshot? {
        var candidates: [UsageSnapshot] = []
        if let hud = (try? Data(contentsOf: UsageReader.cacheURL(claudeHome: claudeHome))).flatMap(UsageReader.parse) {
            candidates.append(hud)
        }
        if let saved = (try? Data(contentsOf: UsageReader.snapshotURL(petHome: petHome))).flatMap(UsageReader.parseSnapshot) {
            candidates.append(saved)
        }
        if let line = (try? Data(contentsOf: StatuslineUsage.cacheURL(petHome: petHome))).flatMap(StatuslineUsage.decode) {
            candidates.append(line)
        }
        let picked = UsageSources.pick(candidates, now: now)
        // Nothing readable this time (a file mid-write): keep what was known.
        var snapshot = picked ?? recency.current() ?? last
        if let picked, picked.percentagesUsable(now: now) {
            if recency.observe(picked, now: now), let data = recency.saved() {
                try? data.write(to: seenURL, options: .atomic)
            }
            snapshot = recency.current() ?? picked
        }
        last = snapshot
        return snapshot
    }
}
