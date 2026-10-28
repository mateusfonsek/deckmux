// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Deckmux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Bonsplit at the revision cmux pins (d67d1b1), vendored with a small
        // patch for per-tab color (Packages/Bonsplit/DECKMUX.md).
        .package(path: "Packages/Bonsplit"),
        // Code tab colors: highlight.js in JavaScriptCore. Highlightr 2.3.0
        // (MIT), vendored with a patch for the app bundle and the themes
        // (Packages/Highlightr/DECKMUX.md).
        .package(path: "Packages/Highlightr"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .target(name: "GhosttyObjC", path: "Sources/GhosttyObjC"),
        // Tasks of the Hoje board, shared by the app and the CLI.
        .target(name: "DeckmuxTasks", path: "Sources/DeckmuxTasks", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Pure logic of the code tab (git status, decorations, diff); Foundation only.
        .target(name: "DeckmuxCode", path: "Sources/DeckmuxCode", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckmuxCodeTests", dependencies: ["DeckmuxCode"], path: "Tests/DeckmuxCodeTests"),
        // The task manager's reading of processes (libproc), CPU and attribution; Foundation and Darwin only.
        .target(name: "DeckmuxTop", path: "Sources/DeckmuxTop", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckmuxTopTests", dependencies: ["DeckmuxTop"], path: "Tests/DeckmuxTopTests"),
        // The Janelinha's pure logic (pulse, usage JSON, subagents, transcript paths); Foundation only.
        .target(name: "DeckmuxMonitor", path: "Sources/DeckmuxMonitor", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckmuxMonitorTests", dependencies: ["DeckmuxMonitor"], path: "Tests/DeckmuxMonitorTests"),
        // A sidebar item's own name and tag (color, icon, text); Foundation only.
        .target(name: "DeckmuxChat", path: "Sources/DeckmuxChat", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeckmuxChatTests", dependencies: ["DeckmuxChat"], path: "Tests/DeckmuxChatTests"),
        // `deckmux hook <event>` and `deckmux task …`, bundled as Contents/Resources/bin/deckmux.
        .executableTarget(name: "DeckmuxCLI", dependencies: ["DeckmuxTasks"], path: "Sources/DeckmuxCLI",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Deckmux",
            dependencies: [
                "GhosttyKit",
                "GhosttyObjC",
                "DeckmuxTasks",
                "DeckmuxCode",
                "DeckmuxTop",
                "DeckmuxMonitor",
                "DeckmuxChat",
                .product(name: "Bonsplit", package: "Bonsplit"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources/Deckmux",
            exclude: ["Vendor/Ghostty/LICENSE", "Vendor/Ghostty/README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
