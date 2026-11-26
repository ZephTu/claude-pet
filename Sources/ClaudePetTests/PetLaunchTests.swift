import ClaudePetCore
import Foundation

/// Arguments and the one-pet lock: what decides whether a launch starts a pet.
enum PetLaunchTests {
    static func run(_ t: Harness) {
        print("\n-- launch (arguments, one pet at a time)")

        t.check("no arguments starts the pet", PetLaunch.decide(["ClaudePet"]) == .start)
        t.check("--demo starts the pet", PetLaunch.decide(["ClaudePet", "--demo"]) == .start)
        t.check("--help and -h print the usage",
                PetLaunch.decide(["ClaudePet", "--help"]) == .help && PetLaunch.decide(["ClaudePet", "-h"]) == .help)
        t.check("an unknown flag does not start a pet",
                PetLaunch.decide(["ClaudePet", "--hepl"]) == .unknown(["--hepl"]))
        t.check("a stray word does not either", PetLaunch.decide(["ClaudePet", "board"]) == .unknown(["board"]))
        // A development mode missing its argument falls through to here and must not become a pet.
        t.check("a development mode missing its argument is unknown",
                PetLaunch.decide(["ClaudePet", "--render-board"]) == .unknown(["--render-board"]))
        t.check("AppKit's -Key value pairs and -psn_ pass",
                PetLaunch.decide(["ClaudePet", "-AppleLanguages", "(zh)", "-psn_0_12345", "--demo"]) == .start)

        let dir = FileManager.default.temporaryDirectory.appending(path: "petlaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PetLaunch.lockURL(petHome: dir)
        let first = PetLaunch.acquireLock(at: url)
        t.check("the first pet takes the lock (creating the folder)", first != nil)
        t.check("it records its pid", PetLaunch.holder(at: url) == getpid())
        let started = Date()
        t.check("a second pet does not", PetLaunch.acquireLock(at: url, wait: 0.3) == nil)
        t.check("…after waiting for the first to go", Date().timeIntervalSince(started) >= 0.3)
        if let first { close(first) }
        let again = PetLaunch.acquireLock(at: url)
        t.check("once the first pet is gone, the next one starts", again != nil)
        if let again { close(again) }
    }
}
