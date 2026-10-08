// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cheapshot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "cheapshot"),
        .testTarget(name: "cheapshotTests", dependencies: ["cheapshot"]),
    ]
)
