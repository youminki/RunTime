// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RunTime",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "GameCore"),
        .target(name: "SearchCore"),
        .target(name: "WorkLogCore"),
        .target(name: "DesignSyncCore"),
        .executableTarget(
            name: "RunTime",
            dependencies: ["UsageCore", "GameCore", "SearchCore", "WorkLogCore", "DesignSyncCore"],
            resources: [.copy("Assets")]
        ),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name: "WorkLogCoreTests", dependencies: ["WorkLogCore"]),
        .testTarget(name: "DesignSyncCoreTests", dependencies: ["DesignSyncCore"]),
    ]
)
