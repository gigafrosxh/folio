// swift-tools-version: 6.0
// AST-based cognitive complexity for Folio's Swift sources (#156). Separate package, so the app never depends on SwiftSyntax.
import PackageDescription

let package = Package(
    name: "ComplexityCheck",
    platforms: [.macOS("15.2")],
    products: [.executable(name: "complexity-check", targets: ["complexity-check"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(
            name: "ComplexityCore",
            dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"), .product(name: "SwiftParser", package: "swift-syntax")]
        ),
        .executableTarget(name: "complexity-check", dependencies: ["ComplexityCore"]),
        .testTarget(name: "ComplexityCoreTests", dependencies: ["ComplexityCore"]),
    ]
)
