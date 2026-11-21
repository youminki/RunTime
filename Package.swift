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
        .target(name: "HostsCore"),
        .target(name: "PortsCore"),
        .target(name: "ReportCore"),
        // Rectangle(MIT)의 창 배치 코드를 옮겨 왔다. 저작권 고지는 Sources/WindowKit/LICENSE
        .target(name: "WindowKit", exclude: ["LICENSE"], resources: [.copy("Icons")]),
        // Pesty(MIT)의 클립보드 기록 코드를 옮겨 왔다. 저작권 고지는 Sources/ClipKit/LICENSE
        .target(name: "ClipKit", exclude: ["LICENSE", "RunTime/ko.lproj"]),
        .executableTarget(
            name: "RunTime",
            dependencies: ["UsageCore", "GameCore", "SearchCore", "WorkLogCore", "DesignSyncCore", "HostsCore", "PortsCore", "ReportCore", "WindowKit", "ClipKit"],
            resources: [.copy("Assets")]
        ),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name: "WorkLogCoreTests", dependencies: ["WorkLogCore"]),
        .testTarget(name: "DesignSyncCoreTests", dependencies: ["DesignSyncCore"]),
        .testTarget(name: "HostsCoreTests", dependencies: ["HostsCore"]),
        .testTarget(name: "PortsCoreTests", dependencies: ["PortsCore"]),
        .testTarget(name: "ReportCoreTests", dependencies: ["ReportCore"]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit"]),
        .testTarget(name: "ClipKitTests", dependencies: ["ClipKit"]),
    ]
)
