// swift-tools-version: 6.0
import PackageDescription

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
        .executableTarget(name: "PetEmit", dependencies: ["ClaudePetCore"]),
        .executableTarget(name: "ClaudePetTests", dependencies: ["ClaudePetCore"]),
    ]
)
