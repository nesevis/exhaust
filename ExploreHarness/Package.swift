// swift-tools-version: 6.4
// Validation harness for `#explore(time:)`. A separate package so coverage instrumentation never touches Exhaust's own manifest, where `.unsafeFlags` would disqualify it as a tagged dependency. CI builds it through `swift package explore`, the path a real user follows; local runs, Xcode, and ExploreBenchmark use the manifest flags below.

import PackageDescription

/// Coverage instrumentation for the fixture only, debug-only.
///
/// `-sanitize=undefined` is the lightest base sanitizer the frontend requires before it accepts `-sanitize-coverage`; `edge,trace-pc-guard,pc-table` is the `trace-pc-guard` recorder the suite recipe uses, which keeps each run's coverage in its own context so the instrumented suites here can run concurrently without serialization; `trace-cmp` additionally exposes comparison operands for injection. Debug-only keeps release builds clean.
///
/// `EXHAUST_HARNESS_COMMAND_COVERAGE=1` removes them so `swift package explore` can supply its own recorder: one build cannot mix two recorders.
let coverageFlags: [SwiftSetting] = switch Context.environment["EXHAUST_HARNESS_COMMAND_COVERAGE"] {
    case "1":
        []
    default:
        [
            .unsafeFlags(
                [
                    "-sanitize=undefined",
                    "-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp",
                ],
                .when(configuration: .debug)
            ),
        ]
}

let package = Package(
    name: "ExploreHarness",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The deliberately buggy SUT and the only instrumented target. Depends on Exhaust only for the
        // generator factory; the parser itself is plain Swift.
        .target(
            name: "ExploreFixture",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
            ],
            swiftSettings: coverageFlags
        ),
        // The deliberately buggy bounded queue SUT for #explore(Spec.self, time:) validation.
        .target(
            name: "SpecFixture",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
            ],
            swiftSettings: coverageFlags
        ),
        // Uninstrumented shared home for the spec-path fixture specs. Both SpecTests and ExploreBenchmark import it, so the benchmark measures the exact spec the tests validate — access-level-mirroring @StateMachine synthesis (public specs get public members) is what makes the cross-module sharing possible.
        .target(
            name: "MatrixSpecs",
            dependencies: [
                "SpecFixture",
                .product(name: "Exhaust", package: "Exhaust"),
            ]
        ),
        .target(name: "HarnessTestSupport"),
        // Uninstrumented: the test module measures the fixture's coverage, not its own.
        .testTarget(
            name: "ExploreTests",
            dependencies: [
                "HarnessTestSupport",
                "ExploreFixture",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
            ]
        ),
        // Uninstrumented: validates #explore(Spec.self, time:) against the BoundedQueue fixture.
        .testTarget(
            name: "SpecTests",
            dependencies: [
                "HarnessTestSupport",
                "SpecFixture",
                "MatrixSpecs",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
            ]
        ),
        // Spawned as a child process by the trap test: runs a fuzz run that traps, so the parent can inspect the breadcrumb and progress log the dead process left behind.
        .executableTarget(
            name: "ExploreTrapProbe",
            dependencies: [
                "ExploreFixture",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
            ]
        ),
        // Spawned as a child process by the spec trap test: runs a spec fuzz under time: that traps.
        .executableTarget(
            name: "SpecTrapProbe",
            dependencies: [
                "SpecFixture",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
            ],
            swiftSettings: coverageFlags
        ),
        // Uninstrumented benchmark driver: loops seeds against one fixture under one experiment arm and emits one JSONL record per run to stdout. Arms are configured through the EXHAUST_FUZZ_EXPERIMENT environment variable set by the invoking command; see README.md.
        .executableTarget(
            name: "ExploreBenchmark",
            dependencies: [
                "ExploreFixture",
                "SpecFixture",
                "MatrixSpecs",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
