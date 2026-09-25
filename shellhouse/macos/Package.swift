// swift-tools-version: 5.9
import PackageDescription

// Apple Silicon only: Virtualization.framework's Linux VM support on Intel
// Macs is too limited for this use case. macOS 13+ for save/restore VM state.
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
        .executable(name: "SandboxHelper", targets: ["SandboxHelper"]),
        .executable(name: "aic", targets: ["AgentCLI"]),
    ],
    dependencies: [
        // SQLite with migrations — the Python build's biggest missing piece.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Holds the virtualization entitlement. The app process does not.
        .executableTarget(
            name: "SandboxHelper",
            dependencies: ["AgentCore"]
        ),
        .target(
            name: "AgentUI",
            dependencies: ["AgentCore"],
            path: "Sources/AgentApp"
        ),
        // Headless driver, so the runtime can be exercised and evaluated
        // before any UI exists.
        .executableTarget(
            name: "AgentCLI",
            dependencies: ["AgentCore"]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
    ]
)
