// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeMeterCore"),
        .executableTarget(name: "ClaudeMeter", dependencies: ["ClaudeMeterCore"]),
        .testTarget(name: "ClaudeMeterCoreTests", dependencies: ["ClaudeMeterCore"]),
    ]
)
