// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "QuotaTrackerCore"),
        .executableTarget(name: "QuotaTracker", dependencies: ["QuotaTrackerCore"]),
        .testTarget(
            name: "QuotaTrackerCoreTests",
            dependencies: ["QuotaTrackerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
