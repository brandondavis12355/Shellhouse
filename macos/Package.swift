// swift-tools-version: 5.9
import PackageDescription

// The Shellhouse Mac app's Swift package. The .app target itself is generated
// from project.yml by XcodeGen and depends on these libraries.
let package = Package(
    name: "Shellhouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        // SwiftUI views the Xcode app target imports. Kept as a library, not
        // an app target: a SwiftPM target cannot carry entitlements or an
        // Info.plist, and this app needs both. The .app itself is an Xcode
        // project that depends on this package.
        .library(name: "AgentUI", targets: ["AgentUI"]),
    ],
    targets: [
        .target(name: "AgentCore"),
        .target(name: "AgentUI", dependencies: ["AgentCore"]),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
    ]
)
