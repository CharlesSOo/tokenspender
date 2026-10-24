// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tokenmeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TokenmeterCore"),
        .executableTarget(name: "Tokenmeter", dependencies: ["TokenmeterCore"]),
        .testTarget(
            name: "TokenmeterCoreTests",
            dependencies: ["TokenmeterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
