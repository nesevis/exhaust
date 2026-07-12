// swift-tools-version: 6.3
// Validation harness for `#explore(time:)`. A separate package so the coverage `.unsafeFlags` live in a consumer's manifest — exactly the integration path a real user follows — and never touch Exhaust's own manifest, where they would disqualify it as a tagged dependency.

import PackageDescription

/// Coverage instrumentation for the fixture only, debug-only.
///
/// `-sanitize=undefined` is the lightest base sanitiser the frontend requires before it accepts `-sanitize-coverage`; `edge,inline-8bit-counters,pc-table` is libFuzzer's default and what the live loop plus the report both read. Debug-only keeps release builds clean.
let coverageFlags: [SwiftSetting] = [
    .unsafeFlags(
        [
            "-sanitize=undefined",
            "-sanitize-coverage=edge,inline-8bit-counters,pc-table",
        ],
        .when(configuration: .debug)
    ),
]

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
        // The deliberately buggy bounded queue SUT for #execute(time:) validation.
        .target(
            name: "ExecuteFixture",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
            ],
            swiftSettings: coverageFlags
        ),
        // Uninstrumented shared home for the spec-path fixture specs. Both ExecuteTests and ExploreBenchmark import it, so the benchmark measures the exact spec the tests validate — access-level-mirroring @StateMachine synthesis (public specs get public members) is what makes the cross-module sharing possible.
        .target(
            name: "MatrixSpecs",
            dependencies: [
                "ExecuteFixture",
                .product(name: "Exhaust", package: "Exhaust"),
            ]
        ),
        // Uninstrumented: the test module measures the fixture's coverage, not its own.
        .testTarget(
            name: "ExploreTests",
            dependencies: [
                "ExploreFixture",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
            ]
        ),
        // Uninstrumented: validates #execute(time:) against the BoundedQueue fixture.
        .testTarget(
            name: "ExecuteTests",
            dependencies: [
                "ExecuteFixture",
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
        // Spawned as a child process by the execute trap test: runs a spec fuzz under time: that traps.
        .executableTarget(
            name: "ExecuteTrapProbe",
            dependencies: [
                "ExecuteFixture",
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
                "ExecuteFixture",
                "MatrixSpecs",
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
