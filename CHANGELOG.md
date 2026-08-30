# Changelog

All notable changes to Exhaust are recorded here, starting from 1.0.0. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Exhaust follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Replay seeds are covered by semantic versioning: a seed recorded under one release reproduces the same run under every later release with the same major version. A change that breaks an existing seed is a major release and is listed under **Replay** in its entry.

## [Unreleased]

### Added

- `#explore(…, time:)` accepts `trace-pc-guard` instrumentation (`-sanitize-coverage=edge,trace-pc-guard,pc-table`) beside `inline-8bit-counters`. Runs under `trace-pc-guard` keep their edges and comparison operands in the run's own context, so instrumented tests in one process run concurrently without serialising on the process-global counter table. When a build carries both, the counters are used because they record on every executor.
- `FuzzTermination.coverageUnreachable`: a run whose property evaluated but never recorded an edge fails with a diagnostic that names the likely causes (release-mode inlining into an uninstrumented caller, property work on an executor the run did not bind) instead of passing green having searched nothing. Any faults found on the unseen path are still reported.
- `FuzzReport.offLaneEdgeHits` and a matching summary line count edges that fired on threads the run did not own under `trace-pc-guard`, so property work that escapes to another executor is visible.
- The coverage-guided fuzzing article gives one recipe for a fuzz test that lives in the wider test suite (`trace-pc-guard`, debug) and one for a dedicated fuzz target (release, flags on the library and the calling target, `-assert-config Debug`), and explains what each runtime diagnostic means.

### Changed

- `#explore(…, time:)` records coverage only while the property runs. Generation, materialisation, and reduction probes no longer contribute to an attempt's signature, which raises throughput by 1.1–1.5× on a per-target build and 3–4× on a whole-graph build with the same fault inventories.
- The uninstrumented C target `ExhaustTraceCmp` is now `ExhaustCoverageRuntime`, since it hosts the edge recorder as well as the comparison hooks. The `Exhaust` product is unchanged; only the xcframework build script and anyone depending on the target by name are affected.
- Documentation for `stopOnFirstFault` and the fault inventory describes the cluster count as a lower bound on distinct faults rather than a census.

### Fixed

- `#explore(…, time:)` corpus admission no longer walks every corpus entry per covered edge. Screening-heavy targets with few instrumented branches previously stalled in screening at debug optimisation levels (measured 57× slower on one fixture).
- Recording an attachment from a non-main thread under XCTest trapped the process; the attachment is now hopped to the main actor. Test-framework detection asks Swift Testing before falling back to XCTest.
- A `.threads` reservation larger than the lane limit deadlocked the lane gate; it is now clamped to the limit.

### Replay

- `#explore(…, time:)` seeds recorded before this change take a different search path, because corpus admission now keys on the property's coverage alone. The mode is experimental and outside the seed guarantee.

## [1.0.0] - 2026-08-26

### Added

- First stable release. The public API is covered by semantic versioning from this release on.
- `#explore(…, time:)` ships as experimental. It warns at every call site, and its settings and report shape sit outside the versioning contract.

### Replay

- Seeds recorded before 1.0.0 are not covered by the guarantee above.

[Unreleased]: https://github.com/nesevis/exhaust/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nesevis/exhaust/releases/tag/v1.0.0
