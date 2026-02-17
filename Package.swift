// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Exhaust",
    platforms: [
        .macOS(.v26),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Exhaust",
            targets: ["Exhaust"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
        .package(url: "https://github.com/google/swift-benchmark", from: "0.1.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.59.1")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Exhaust",
            dependencies: [
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "Algorithms", package: "swift-algorithms")
            ],
            swiftSettings: [
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "ExhaustTests",
            dependencies: ["Exhaust"]
        ),
        .executableTarget(
            name: "ExhaustBenchmarks",
            dependencies: [
                "Exhaust",
                .product(name: "Benchmark", package: "swift-benchmark")
            ],
            swiftSettings: [
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
            ]
        ),
    ]
)
