// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-ai-usage-bar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "MacAIUsageBar",
            dependencies: ["UsageCore"]
        ),
        .executableTarget(
            name: "usage-probe",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
    ]
)
