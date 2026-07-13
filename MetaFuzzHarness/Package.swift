// swift-tools-version: 6.3
// Self-fuzzing harness: runs `#explore(time:)` with ExhaustCore as the SUT, checking the oracle roster in ExhaustMetaFuzz. A separate package so fuzz runs stay out of the default `swift test` lane. This manifest carries NO coverage flags: instrumentation is whole-graph via `-Xswiftc` at the CI invocation, so ExhaustCore — a dependency this manifest cannot flag — gets counters without touching Exhaust's own manifest.

import PackageDescription

let package = Package(
    name: "MetaFuzzHarness",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The fuzz entry (gated on METAFUZZ_FUZZ=1 — it hard-fails without instrumentation), the frozen-regression replay suite (the always-on PR gate), and oracle smoke coverage.
        .testTarget(
            name: "MetaFuzzTests",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
                .product(name: "ExhaustMetaFuzz", package: "Exhaust"),
            ]
        ),
        // Standalone fuzz loop for the nightly wrapper: an executable survives traps as a child process the wrapper can relaunch, resumes from the progress log, and its main thread's 8 MB stack tolerates deeper recipes than the 512 KiB test threads.
        .executableTarget(
            name: "MetaFuzzProbe",
            dependencies: [
                .product(name: "Exhaust", package: "Exhaust"),
                .product(name: "ExhaustCore", package: "Exhaust"),
                .product(name: "ExhaustMetaFuzz", package: "Exhaust"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
