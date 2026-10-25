// swift-tools-version: 6.4
// Consumer-side smoke test for the ExhaustCore xcframework. A separate package, deliberately NOT named `exhaust`, so its target sits outside the `exhaust` package boundary and compiles against ExhaustCore's public `.swiftinterface` exactly as a real consumer does. The in-package test targets never take that path: they load the package interface, so layout and visibility mistakes at the public boundary (a `package` type stored in a public struct, a missing metadata export) reach consumers only. Run through `Scripts/verify-xcframework.sh` with `EXHAUST_RELEASE=1`.

import PackageDescription

let package = Package(
    name: "ArtifactSmoke",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "ArtifactSmoke",
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
