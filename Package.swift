// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-ai-usage-bar",
    platforms: [.macOS(.v13)],
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
    ]
)
