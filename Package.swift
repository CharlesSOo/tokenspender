// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tokenspender",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TokenSpenderCore"),
        .executableTarget(name: "TokenSpender", dependencies: ["TokenSpenderCore"]),
        .testTarget(
            name: "TokenSpenderCoreTests",
            dependencies: ["TokenSpenderCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
