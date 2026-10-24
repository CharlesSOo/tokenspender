// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Munch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MunchCore"),
        .executableTarget(name: "Munch", dependencies: ["MunchCore"]),
        .testTarget(
            name: "MunchCoreTests",
            dependencies: ["MunchCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
