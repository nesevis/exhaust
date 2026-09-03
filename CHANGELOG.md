# Changelog

All notable changes to Exhaust are recorded here, starting from 1.0.0. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Exhaust follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Replay seeds are covered by semantic versioning: a seed recorded under one release reproduces the same run under every later release with the same major version. A change that breaks an existing seed is a major release and is listed under **Replay** in its entry.

## [Unreleased]

### Added

- `#explore(…, time:)` accepts `trace-pc-guard` instrumentation (`-sanitize-coverage=edge,trace-pc-guard,pc-table`) beside `inline-8bit-counters`. Runs under `trace-pc-guard` keep their edges and comparison operands in the run's own context, so instrumented tests in one process run concurrently without serialising on the process-global counter table. When a build carries both, the counters are used because they record on every executor.
- `FuzzTermination.coverageUnreachable`: a run whose property evaluated but never recorded an edge fails with a diagnostic that names the likely causes (release-mode inlining into an uninstrumented caller, property work on an executor the run did not bind) instead of passing green having searched nothing. Any faults found on the unseen path are still reported.
- `#explore(…, time:)` treats a property that throws `PropertySkip` or `XCTSkip` as a *discard* rather than a pass. Coverage-novel discards enter the corpus as mutation parents at one third of a valid input's weight (the FuzzChick discard queue), so a sparse precondition can be climbed by mutating near misses. `FuzzReport.discardedEvaluations` and a summary line report the share of skipped inputs.
- `.skipScreening` on `PropertyFuzzSettings` and `StateMachineFuzzSettings` starts the search directly at random sampling, for properties whose sparse preconditions discard nearly every boundary row and for strategy comparisons that must start from identical conditions.
- `FuzzReport.offLaneEdgeHits` and a matching summary line count edges that fired on threads the run did not own under `trace-pc-guard`, so property work that escapes to another executor is visible.
- `.lazy(_:)` on `ReflectiveGenerator` builds its generator once and reuses it, and `.bind(caching:)` builds one dependent generator per distinct bound value. The choice sequence is unchanged, so replay seeds and search trajectories carry over. `.bind(caching:)` keys an unbounded cache on the bound value, so it suits small value sets, not lengths or strings.
- `.anyNonNil(_:)` and `.anyNonNil(always:)` on `ReflectiveGenerator` try weighted arms one at a time until one produces a value: an arm returning `nil` is withdrawn and the next draw is made among the arms not yet tried, where `.oneOf` commits to its first draw. Use them for constrained generation where an arm can only discover that it does not apply by attempting its sub-generation, such as a typing rule whose premises must both be satisfiable. Failed attempts consume randomness but are not recorded, so reduction, mutation, and replay see an ordinary weighted choice. The `always:` form ends the run and records an issue at the call site when every arm produces `nil`; the unlabelled form records absence as a reflectable, mutation-reachable branch ordered after the real arms, so reduction prefers a value over `nil`.
- `#explore(…, time:)` places harvested comparison operands directly into a corpus parent's flattened choice sequence, overwriting value entries whose type tag can encode the operand and whose declared range contains it. Unlike the reflective injection paths this needs no reflective generator, so a plain `Gen` reaches a magic-constant gate the search would otherwise never guess. The number of positions written is drawn per attempt: one serves a constant gate, while writing the same operand across several positions of one tag group is the move that satisfies a precondition demanding independently drawn components agree. Writes never mix tags, and the sequence's length and structure are preserved, so the candidate rides the ordinary guided-materialisation path. Integer tags only. Comparisons against a compile-time constant now record that constant in both operand slots, so every draw from a constant-gate site yields the gate's value rather than the runtime operand, which had already come from an input.
- The coverage-guided fuzzing article gives one recipe for a fuzz test that lives in the wider test suite (`trace-pc-guard`, debug) and one for a dedicated fuzz target (release, flags on the library and the calling target, `-assert-config Debug`), and explains what each runtime diagnostic means.

### Changed

- The `#explore(…, time:)` mutation phase draws from a larger operator inventory by default: structure-aware moves over the input's choice graph (sibling-span swap, shuffle, and move, plus a tandem lockstep shift) and pair operators that create structural agreement (copying one twin's span over the other, and splicing a matching region from a different corpus entry). Operator selection is scheduled by per-operator statistics rewarded on corpus admission, so unproductive operators fade instead of costing budget. Measured on a register-machine benchmark, the pair operators significantly accelerate faults that require two independently generated structures to agree; throughput is unchanged. `#explore(…, time:)` remains experimental and search behaviour may change in any release.
- The `#explore(…, time:)` terminal summary now lists each distinct failure with its counterexample, the time it was first seen, and one suspect function, followed by a plain answer to whether a longer run would find more. Throughput, testing overhead, edge counts, and the reachability estimate move to the `explore-time-summary.txt` attachment, available as `FuzzReport.renderedAttachmentSummary()`; the reachability estimate prints only once the run has seen repeat coverage. `FuzzReport.lastDiscovery` records the time of the run's last new edge or fault cluster.
- `#explore(…, time:)` records coverage only while the property runs. Generation, materialisation, and reduction probes no longer contribute to an attempt's signature, which raises throughput by 1.1–1.5× on a per-target build and 3–4× on a whole-graph build with the same fault inventories.
- The uninstrumented C target `ExhaustTraceCmp` is now `ExhaustCoverageRuntime`, since it hosts the edge recorder as well as the comparison hooks. The `Exhaust` product is unchanged; only the xcframework build script and anyone depending on the target by name are affected.
- Documentation for `stopOnFirstFault` and the fault inventory describes the cluster count as a lower bound on distinct faults rather than a census.
- `#explore(…, time:)` no longer ends a run early when coverage stops growing. The time-based plateau rule is replaced by `.stopWhenSaturated`, off by default, which ends the run once the estimated chance that the next attempt covers a new edge falls below 1 in 10,000 and returns the unused budget as `FuzzReport.Termination.coveragePlateau(unused:)`. Saturation is not fault exhaustion: on a sparse-precondition workload roughly a fifth of all detections arrived after the search stopped reaching new edges, so a run now spends the budget it was given unless asked otherwise.
- The `#explore(…, time:)` screening pass draws at most 1,000 covering-array rows, down from 10,000, and `EXHAUST_SCREENING_BUDGET` overrides the figure. The reduction was arrived at after a lot of benchmarking.
- The `#explore(…, time:)` loop evaluates a candidate without building a choice tree, rebuilding one only when the attempt fails or the corpus would admit it, and drains comparison records in bulk. Measured on a register-machine benchmark, throughput rose 23%, from 32.5k to 40.0k evaluations per second.
- The `#explore(…, time:)` mutation phase spends a share of its attempts on fresh generator draws rather than mutations of a corpus parent. The share climbs from 5% to 60% as attempts accumulate without a corpus admission and resets on the next admission, so a healthy corpus pays almost nothing and a starved one recovers the diversity it has lost. `EXHAUST_FRESH_CAP=0` disables it.
- `#explore(…, time:)` resets the corpus novelty baseline at the handover from screening to random sampling. Screening's boundary rows previously saturated the novelty map before the search began, so on some seeds nothing that followed could be admitted. `FuzzReport` still counts every edge covered across the whole run.
- Generation allocates less per value. `Gen.recursive` erases its layer table once at construction rather than on every depth draw, weighted pick selection walks branches without retaining the ones it passes, the batch sequence paths no longer reserve a buffer they do not use, and the value-and-choice-tree interpreter dispatches on a sequence's length shape without re-boxing it. `#gen` also expands multi-argument forms through fixed-arity zip overloads rather than a variadic pack, worth about 3%. Behaviour, draws, and recorded trees are unchanged.

### Fixed

- `#explore(…, time:)` corpus admission no longer walks every corpus entry per covered edge. Screening-heavy targets with few instrumented branches previously stalled in screening at debug optimisation levels (measured 57× slower on one fixture).
- Recording an attachment from a non-main thread under XCTest trapped the process; the attachment is now hopped to the main actor. Test-framework detection asks Swift Testing before falling back to XCTest.
- A `.threads` reservation larger than the lane limit deadlocked the lane gate; it is now clamped to the limit.

### Replay

- The `#explore(…, time:)` crash-recovery log records whether the property discarded each corpus entry. The format stays at version 2 and the field is optional, so a log written by 1.0.0 still resumes, with every entry read as not discarded.

- `#explore(…, time:)` seeds recorded before this change take a different search path, because corpus admission now keys on the property's coverage alone. The mode is experimental and outside the seed guarantee.

## [1.0.0] - 2026-08-26

### Added

- First stable release. The public API is covered by semantic versioning from this release on.
- `#explore(…, time:)` ships as experimental. It warns at every call site, and its settings and report shape sit outside the versioning contract.

### Replay

- Seeds recorded before 1.0.0 are not covered by the guarantee above.

[Unreleased]: https://github.com/nesevis/exhaust/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nesevis/exhaust/releases/tag/v1.0.0
