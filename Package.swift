// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

let usePrecompiled = true

let swiftLintPlugins: [Target.PluginUsage] = []
let swiftLintDependency: [Package.Dependency] = []

let strictConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let coreTarget: Target = usePrecompiled
    ? .binaryTarget(name: "ExhaustCore", url: "https://github.com/nesevis/exhaust/releases/download/v0.10.0/ExhaustCore.xcframework.zip", checksum: "5a448830ffda12658dff08fb30b9bd4470b0daa3a98ff89f6fd8a6f183853679")
    : .target(
        name: "ExhaustCore",
        dependencies: [],
        swiftSettings: strictConcurrencySettings + [
            .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
        ],
        plugins: swiftLintPlugins
    )

let package = Package(
    name: "Exhaust",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .macCatalyst(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Exhaust",
            targets: ["Exhaust"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark", from: "0.1.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.5.0"),
    ] + swiftLintDependency,
    targets: [
        coreTarget,
        .target(
            name: "ExhaustObjCSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Exhaust",
            dependencies: [
                "ExhaustCore",
                "ExhaustMacros",
                "ExhaustObjCSupport",
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            swiftSettings: strictConcurrencySettings + (usePrecompiled
                ? [.unsafeFlags(["-Xfrontend", "-experimental-package-interface-load"])]
                : []),
            plugins: swiftLintPlugins
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
        .target(
            name: "ExhaustTestSupport",
            dependencies: ["ExhaustCore"],
            swiftSettings: strictConcurrencySettings,
            plugins: swiftLintPlugins
        ),
        .testTarget(
            name: "ExhaustTests",
            dependencies: ["Exhaust", "ExhaustCore", "ExhaustTestSupport"],
            swiftSettings: strictConcurrencySettings,
            plugins: swiftLintPlugins
        ),
        .testTarget(
            name: "ExhaustMacrosTests",
            dependencies: [
                "Exhaust",
                "ExhaustMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
            ]
        ),
        .executableTarget(
            name: "ExhaustBenchmarks",
            dependencies: [
                "Exhaust",
                "ExhaustCore",
                .product(name: "Benchmark", package: "swift-benchmark"),
            ],
            swiftSettings: strictConcurrencySettings + [
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
            ],
            plugins: swiftLintPlugins
        ),
    ]
)

if usePrecompiled == false {
    package.products.append(
        .library(name: "ExhaustCore", targets: ["ExhaustCore"])
    )
    package.targets.append(
        .testTarget(
            name: "ExhaustCoreTests",
            dependencies: ["ExhaustCore", "ExhaustTestSupport"],
            swiftSettings: strictConcurrencySettings,
            plugins: swiftLintPlugins
        )
    )
}
