// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chronicle",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Chronicle", targets: ["Chronicle"]),
        .executable(name: "chronicle", targets: ["ChronicleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.3.0"),
        .package(url: "https://github.com/JohnSundell/Splash.git", from: "0.16.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Chronicle",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "Splash"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Chronicle",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Foundation-only CLI; ships for macOS + Linux. Reads
        // ~/.claude/projects/ directly (no GRDB, no SQLite indexer)
        // so it is portable and trivially packageable as a single
        // static binary on Linux.
        .executableTarget(
            name: "ChronicleCLI",
            path: "ChronicleCLI",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ChronicleTests",
            dependencies: ["Chronicle"],
            path: "ChronicleTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
