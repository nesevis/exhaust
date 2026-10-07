// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "exhaust-macros",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .macCatalyst(.v15),
        .tvOS(.v15),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "ExhaustMacroPlugin",
            targets: ["ExhaustMacroPlugin"]
        ),
    ],
    dependencies: [
        // Keep snapshot-testing on the same Custom Dump version as the runtime.
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.7.3"),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            "601.0.1" ..< "604.0.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-macro-testing",
            from: "0.5.0"
        ),
    ],
    targets: [
        .target(
            name: "ExhaustMacroPlugin",
            dependencies: ["ExhaustMacros"],
            swiftSettings: strictConcurrencySettings
        ),
        .macro(
            name: "ExhaustMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "ExhaustMacrosTests",
            dependencies: [
                "ExhaustMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
    ]
)
