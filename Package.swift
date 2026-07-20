// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

/// True when the manifest is being compiled on an Apple host. XCFrameworks are an Apple-only distribution format, so the release workflow rewrites `usePrecompiled` below into an expression gated on this constant: Apple hosts consume the prebuilt ExhaustCore binary, Linux hosts build ExhaustCore from source off the same release tag.
let isDarwinHost: Bool = {
    #if canImport(Darwin)
        return true
    #else
        return false
    #endif
}()

let usePrecompiled = ProcessInfo.processInfo.environment["EXHAUST_RELEASE"] != nil

let swiftLintPlugins: [Target.PluginUsage] = []
let swiftLintDependency: [Package.Dependency] = []

let strictConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("StrictConcurrency"),
]

let coreTarget: Target = usePrecompiled
    ? .binaryTarget(name: "ExhaustCore", path: "Frameworks/ExhaustCore.xcframework")
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
        // Consumed by the MetaFuzzHarness package (the self-fuzzing harness); not part of the supported public API.
        .library(
            name: "ExhaustMetaFuzz",
            targets: ["ExhaustMetaFuzz"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark", from: "0.1.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.1" ..< "603.0.0"),
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
                .target(
                    name: "ExhaustObjCSupport",
                    condition: .when(platforms: [.macOS, .iOS, .macCatalyst, .tvOS, .watchOS, .visionOS])
                ),
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
        // The self-fuzzing support: recipe language, oracle roster, freeze codec, and the shared core generators. Deliberately free of Swift Testing so plain executables (MetaFuzzProbe) can link it; ExhaustTestSupport re-exports it for the in-tree test targets.
        .target(
            name: "ExhaustMetaFuzz",
            dependencies: ["ExhaustCore"],
            swiftSettings: strictConcurrencySettings,
            plugins: swiftLintPlugins
        ),
        .target(
            name: "ExhaustTestSupport",
            dependencies: ["ExhaustCore", "ExhaustMetaFuzz"],
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
        // Calibration probe for the meta-test node budget; see MetaGeneratorPropertyTests.metaRecipeNodeBudget.
        .executableTarget(
            name: "ExhaustStackProbe",
            dependencies: ["ExhaustCore"],
            swiftSettings: strictConcurrencySettings
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
