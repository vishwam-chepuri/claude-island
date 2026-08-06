// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic. No AppKit, no SwiftUI — this is what makes the tests
        // headless and what lets --replay run the whole pipeline with no UI.
        .target(name: "ClaudeIslandCore"),

        .executableTarget(
            name: "ClaudeIslandApp",
            dependencies: ["ClaudeIslandCore"]
        ),

        // Hook client. Deliberately depends on nothing — not even
        // ClaudeIslandCore — so it links no Foundation and starts fast.
        .executableTarget(name: "claude-island-notify"),

        // Not a .testTarget: Apple's Command Line Tools ship swift-testing's
        // module and macro plugin but not lib_TestingInterop.dylib, so an
        // .xctest bundle compiles and then fails to dlopen, and XCTest is
        // Xcode-only. Since the project takes no third-party dependencies, the
        // suites run through a small in-repo harness instead.
        //   swift run ClaudeIslandTests [name-filter]
        .executableTarget(
            name: "ClaudeIslandTests",
            dependencies: ["ClaudeIslandCore"],
            path: "Tests/ClaudeIslandCoreTests"
        ),
    ]
)
