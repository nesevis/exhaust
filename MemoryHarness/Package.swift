// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MemoryHarness",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .testTarget(
            name: "MemoryProfileTests",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
            ]
        ),
    ]
)
