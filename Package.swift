// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Exhaust",
    platforms: [
        .macOS(.v10_15),
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
        .package(path: "../See5") // Local C50 package
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Exhaust",
            dependencies: [
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "See5", package: "See5")
            ]
        ),
        .testTarget(
            name: "ExhaustTests",
            dependencies: ["Exhaust"]
        ),
    ]
)
