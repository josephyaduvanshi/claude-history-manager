// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chronicle",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Chronicle", targets: ["Chronicle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.3.0"),
        .package(url: "https://github.com/JohnSundell/Splash.git", from: "0.16.0"),
    ],
    targets: [
        .executableTarget(
            name: "Chronicle",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "Splash"),
            ],
            path: "Chronicle",
            resources: [
                .process("Resources"),
            ],
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
