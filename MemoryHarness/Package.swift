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

// Treat compiler warnings as errors for libraries, executables, tests, and macros in all configurations.
// Manifest settings apply to local builds and CI without changing third-party dependency settings.
for target in package.targets {
    switch target.type {
        case .regular, .executable, .test, .macro:
            target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
            target.cSettings = (target.cSettings ?? []) + [.treatAllWarnings(as: .error)]
        default:
            break
    }
}
