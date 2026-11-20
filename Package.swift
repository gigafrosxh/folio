// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("15.2"), .iOS("18.0")],
    products: [
        .executable(name: "Folio", targets: ["Folio"]),
        .executable(name: "FolioWidgets", targets: ["FolioWidgets"]),
        .executable(name: "FolioShare", targets: ["FolioShare"]),
        .library(name: "FolioCore", targets: ["FolioCore"]),
    ],
    targets: [
        .target(name: "FolioTerminal", path: "Sources/FolioTerminal", publicHeadersPath: "include"),
        // Platform-independent core: file format, note model, tags, syntax tokens, code execution.
        .target(
            name: "FolioCore",
            dependencies: ["FolioTerminal"],
            path: "Sources/FolioCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The SwiftUI/AppKit app.
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioCore", "FolioWidgetData"],
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Widgets (#78–#84): the snapshot model shared with the app, the views, and the extension
        // executable that scripts/build-app.sh packs into Folio.app/Contents/PlugIns/FolioWidgets.appex.
        .target(name: "FolioWidgetData", path: "Sources/FolioWidgetData"),
        .target(name: "FolioWidgetUI", dependencies: ["FolioWidgetData"], path: "Sources/FolioWidgetUI"),
        .executableTarget(
            name: "FolioWidgets",
            dependencies: ["FolioWidgetData", "FolioWidgetUI"],
            path: "Sources/FolioWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            // Like Xcode for app extensions: start in NSExtensionMain, which then runs the @main WidgetBundle.
            // With Swift's own entry point the extension crashed at launch (#123).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        // Folio for iPad (#214): iPadOS only; on macOS the target is an empty placeholder. Built by scripts/build-ipad.sh.
        .executableTarget(
            name: "FolioPad",
            dependencies: ["FolioCore"],
            path: "Sources/FolioPad",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Safari share menu (#50): an app extension, packed by scripts/build-app.sh like the widgets.
        .executableTarget(
            name: "FolioShare",
            dependencies: ["FolioCore"],
            path: "Sources/FolioShare",
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        // Benchmarks on synthetic libraries (#219): scripts/benchmark.sh.
        .executableTarget(
            name: "folio-bench",
            dependencies: ["FolioCore"],
            path: "Sources/folio-bench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line inspector for .folio files.
        .executableTarget(
            name: "folio-dump",
            dependencies: ["FolioCore"],
            path: "Sources/folio-dump",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FolioCoreTests",
            dependencies: ["FolioCore"],
            path: "Tests/FolioCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Editor model tests (block operations, undo); runs the app module without its UI.
        .testTarget(
            name: "FolioAppTests",
            dependencies: ["Folio", "FolioWidgetData", "FolioWidgetUI"],
            path: "Tests/FolioAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
