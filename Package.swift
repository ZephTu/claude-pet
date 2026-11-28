// swift-tools-version: 6.0
import PackageDescription

// Windows only: pet-emit --jump selects a Windows Terminal tab through UI Automation, whose
// headers Swift's WinSDK module does not cover, hence a small C target. The Mac build has none
// of it.
#if os(Windows)
let petEmitDependencies: [Target.Dependency] = ["ClaudePetCore", "PetUIA"]
let windowsTargets: [Target] = [.target(name: "PetUIA")]
#else
let petEmitDependencies: [Target.Dependency] = ["ClaudePetCore"]
let windowsTargets: [Target] = []
#endif

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudePetCore"),
        .executableTarget(
            name: "ClaudePet",
            dependencies: ["ClaudePetCore"],
            resources: [.copy("../../Resources/pet")]
        ),
        .executableTarget(name: "PetEmit", dependencies: petEmitDependencies),
        .executableTarget(name: "ClaudePetTests", dependencies: ["ClaudePetCore"]),
    ] + windowsTargets
)
