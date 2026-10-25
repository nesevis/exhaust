// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ExploreCommandConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "exhaust", path: "../..")],
    targets: [
        .target(name: "Parser"),
        .testTarget(
            name: "ParserTests",
            dependencies: ["Parser", .product(name: "Exhaust", package: "exhaust")]
        ),
        // Also links Parser, but deliberately has no Exhaust dependency. The overlay supplies
        // the runtime transitively during fuzz builds so this bundle can still link.
        .testTarget(name: "BaselineTests", dependencies: ["Parser"]),
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
