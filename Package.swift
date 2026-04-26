// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

let usePrecompiled = true

#if os(macOS)
    let swiftLintPlugins: [Target.PluginUsage] = [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
    ]
    let swiftLintDependency: [Package.Dependency] = [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.57.1"),
    ]
#else
    let swiftLintPlugins: [Target.PluginUsage] = []
    let swiftLintDependency: [Package.Dependency] = []
#endif

let coreTarget: Target = usePrecompiled
    ? .binaryTarget(name: "ExhaustCore", url: "https://github.com/nesevis/exhaust/releases/download/v0.4.4/ExhaustCore.xcframework.zip", checksum: "ae430e88f29f21463d14f0e7ee44d14fc4b1a0b0f276e612e46e228200305e00")
    : .target(
        name: "ExhaustCore",
        dependencies: [],
        swiftSettings: [
            .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release))
        ],
        plugins: swiftLintPlugins
      )

let package = Package(
    name: "Exhaust",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .macCatalyst(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "Exhaust",
            targets: ["Exhaust"]
        ),
    ],
    traits: [
        .trait(name: "CasePathable", description: "Adds PartialPath conformance for AnyCasePath from swift-case-paths"),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark", from: "0.1.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.0.0"),
    ] + swiftLintDependency,
    targets: [
        coreTarget,
        .target(
            name: "Exhaust",
            dependencies: [
                "ExhaustCore",
                "ExhaustMacros",
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "CasePaths", package: "swift-case-paths", condition: .when(traits: ["CasePathable"])),
            ],
            swiftSettings: usePrecompiled
                ? [.unsafeFlags(["-Xfrontend", "-experimental-package-interface-load"])]
                : [],
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
            ]
        ),
        .testTarget(
            name: "ExhaustTests",
            dependencies: ["Exhaust", "ExhaustCore"],
            plugins: swiftLintPlugins
        ),
        .testTarget(
            name: "ExhaustMacrosTests",
            dependencies: [
                "Exhaust",
                "ExhaustMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "ExhaustBenchmarks",
            dependencies: [
                "Exhaust",
                "ExhaustCore",
                .product(name: "Benchmark", package: "swift-benchmark")
            ],
            swiftSettings: [
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
            ],
            plugins: swiftLintPlugins,
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
            dependencies: ["ExhaustCore"],
            plugins: swiftLintPlugins
        )
    )
}
