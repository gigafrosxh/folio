// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("15.2")],
    products: [
        .executable(name: "Folio", targets: ["Folio"]),
        .library(name: "FolioCore", targets: ["FolioCore"]),
    ],
    targets: [
        // Platform-independent core: file format, note model, tags, syntax tokens, code execution.
        .target(
            name: "FolioCore",
            path: "Sources/FolioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI/AppKit app.
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioCore"],
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FolioCoreTests",
            dependencies: ["FolioCore"],
            path: "Tests/FolioCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
