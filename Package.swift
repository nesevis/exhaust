// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

let usePrecompiled = ProcessInfo.processInfo.environment["EXHAUST_RELEASE"] != nil


let coreTarget: Target = usePrecompiled
    ? .binaryTarget(name: "ExhaustCore", path: "Frameworks/ExhaustCore.xcframework")
    : .target(
        name: "ExhaustCore",
        dependencies: [],
        swiftSettings: [
            .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release))
        ],
        plugins: [
            .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
        ]
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
        .library(
            name: "ExhaustCore",
            targets: ["ExhaustCore"]
        ),
    ],
    traits: [
        .trait(name: "CasePathable", description: "Adds PartialPath conformance for AnyCasePath from swift-case-paths"),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark", from: "0.1.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.57.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.6"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.0.0"),
    ],
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
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ]
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
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ]
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
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ],
        ),
    ]
)

if usePrecompiled == false {
    package.targets.append(
        .testTarget(
            name: "ExhaustCoreTests",
            dependencies: ["ExhaustCore"],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
            ]
        )
    )
}
