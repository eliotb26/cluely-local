// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cluely-local",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CluelyLocalCore"),
        .executableTarget(name: "cluely-local", dependencies: ["CluelyLocalCore"]),
        .testTarget(name: "CluelyLocalCoreTests", dependencies: ["CluelyLocalCore"]),
    ]
)
