# Changelog

All notable changes to Exhaust are recorded here, starting from 1.0.0. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Exhaust follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Replay seeds are covered by semantic versioning: a seed recorded under one release reproduces the same run under every later release with the same major version. A change that breaks an existing seed is a major release and is listed under **Replay** in its entry.

## [Unreleased]

## [1.4.1] - 2026-09-21

### Fixed

- `@Exhaustable` now derives generators for nested recursive types such as `Outer.Foo<Bar>`.

## [1.4.0] - 2026-09-21

### Added

- The experimental `@Exhaustable` macro derives `Type.gen()` for enums, structs, final classes, and generic or recursive forms. Budget, domain, and payload-override settings control generated values, while the lightweight `Exhaustable` product keeps generator runtime code out of application targets.
- `#exhaust` and `#execute` accept `.deadline(_:)`. `ExhaustReport.hasExceededDeadline` distinguishes an expired deadline from a completed budget.
- `#examine` accepts `.skipReflection` for generators that discard information, while retaining generation, replay, coverage, and filter checks.

### Changed

- Counterexamples now reduce size-controlled collections and recursive generators more effectively, including generators built with `.unfold`.
- `#exhaust` continues into random sampling unless screening covered every possible value. This prevents false passes for optionals, `oneOf`, recursive generators, and other generators whose shape varies with earlier choices.
- Unseeded `#example` arrays generate every value at size 50. Seeded arrays retain the sampling size ramp.
- Date generators expand from the range midpoint as size increases, and dictionary generators draw key-value pairs together.
- Generation, replay, and reduction allocate less.
- `#explore(…, time:)` no longer emits an experimental-use warning.

### Fixed

- Reflection now honours `resize` when validating values and rejects values from choices with no branches.
- Multi-argument `#gen` counterexamples now replay to the reported value when one input generator chooses its range from an earlier generated value.
- Reduction no longer overflows when integer ranges reach `UInt64.max`.

### Replay

- Seeds that use date or dictionary generators take a different path because those generators now use the distributions described above.

## [1.3.0] - 2026-09-15

### Added

- The reducer can now pivot picks inside bind inners and re-search the dependent subtree, reducing counterexamples that previously stopped one wrapper above their minimum.
- `#explore(…, time:)` has new graph-informed mutation operators for value reseeding, small-domain enumeration, element transplants, typed crossover, and sequence edits.
- Fuzzer diagnostics now record mutation-arm traces, failure lineage, parent provenance, and producer information for each concrete failure.
- New benchmark and probe targets cover IFC workloads, mutation-arm gates, witness shapes, and fuzz hot paths.
- Float16 emulation supports x86 platforms.

### Changed

- `#explore(…, time:)` now restricts mutation arms per parent, gates arms by eligibility and admissibility, and adapts fresh random draws based on corpus admission.
- Fuzzer mutation is more structure-aware: reseeding targets only `chooseBits` and pick sites, handles sequence elements independently, and keeps blind band operations behind a flag.
- Generator and materialiser hot paths allocate less through map/isomorph fusion, cached node identifiers, reduced weighted-pick duplication, cheaper swarm rewrites, deferred draw-probability calculation, and less corpus hit-list copying.
- Floating-point generation and reduction share more logic.

### Fixed

- Reduction through `.lazy` generators now steps over the unit entry before exact zip decoding, so value probes run instead of being rejected during materialisation.
- Branch promotion across recursion depths now reads active branch layouts and supports mutual recursion.
- Bind-inner reduction scopes are dispatched after release even when every value is already at its target.
- Value reseeding and typed crossover now materialise through the correct tree shape.
- Lockstep and sequence-based mutators handle edge cases in their valid delta and donor-span bounds.
- Failure-lineage writes are concurrency-safe.
- Fresh-rate attribution reports the correct producer.

## [1.2.1] - 2026-09-09

### Added

- `FuzzReport.Attempts.mutationArmAttempts`, `mutationArmPassed`, `mutationArmFailed`, and `mutationArmDiscarded` tally every mutation operator's attempts by outcome, and `FuzzReport.mutationArmSummary` renders them in the reduction phase's per-encoder form. The line appears in the `explore-time-summary.txt` attachment, so an operator the bandit stopped picking is visible rather than inferred.
- `bind(cachingBy:)` chains a dependent generator keyed by a `Hashable` property of the output, building it once per distinct key, for outputs that are not themselves `Hashable`.

### Fixed

- `#explore(…, time:)` dropped every failure and corpus admission that came from a fresh draw of a generator with a size-scaled length (a default `.array()`, a string) unless the draw was made at size 100. The exact-rebuild parity check compared the length's size-derived valid range, which differs between the draw and the rebuild, so the failure was held without a cluster, `.failFast` never fired, and the corpus could only be seeded by mutation children. Introduced in 1.2.0 with exact materialisation.

## [1.2.0] - 2026-09-07

### Added

- `#exhaust` properties that use `#expect` or `#require` for assertions fail the run when assertions fired inside the property but the pipeline found no counterexample, naming the unobserved assertion and its location. An assertion reached through a function call, a stored closure, or a nested closure is absorbed by the suppression scope but invisible to the detection rewrite, so without this diagnostic a failing assertion silently disappears.
- `FuzzTermination.uncontainedAsyncWork`: a `.tasks` spec run whose timed-out async work outlives cancellation stops early rather than measuring later attempts against escaped coverage.
- `FuzzReport.SymbolLocation` exposes the demangled symbol, module, file, and line of a discriminating edge as fields rather than a composed string.
- `FuzzReport.Attempts.duplicatesSkipped` and `FuzzReport.Attempts.DuplicateSkips` report how many candidates each producer skipped as recent duplicates.
- `FuzzReport.Attempts.operandEnergyRetirements` and related counters report comparand-substitution energy bookkeeping.

### Changed

- `FuzzReport` now groups its metrics into `Attempts`, `Invocations`, `Coverage`, and `Timing` nested types. `TimingBreakdown` is now `Timing`.
- `FuzzReport.FaultCluster.discriminatingEdges` carries `SymbolLocation` instead of a formatted string, folds duplicate source locations within one function, and drops compiler-generated symbols. `necessaryEdgeCount` and `nearMissEdgeIndices` are removed.
- `#explore(…, time:)` deduplicates candidates by Zobrist hash before invoking the property, so a mutation that reproduces a recently evaluated sequence skips it. Per-arm skip counts appear in the summary.
- `#explore(…, time:)` retires comparand-substitution sources whose barren draws exhaust an energy allowance that scales with the tag group's slot count, so a source that stops yielding stops drawing budget.
- `#explore(…, time:)` locks the counter-mode comparison ring so concurrent `trace-pc-guard` runs in one process do not corrupt each other's operand records.
- `#explore(…, time:)` prefers exact materialisation for every candidate, falling back to guided only when exact cannot build the sequence.
- `#explore(…, time:)` drives screening rows through the same evaluate path as sampling and mutation, so attempt accounting, the duplicate check, and the breadcrumb apply uniformly.
- The sync-async bridge cancels timed-out work and drains briefly to distinguish quiesced (stopped) from escaped (still running). `BoundedAwaitOutcome` replaces the bare optional.
- `#explore(Spec.self, time:)` keeps an async sequential spec's continuations on the coverage-bound lane, so `trace-pc-guard` sees the work on platforms at or above macOS 15.
### Fixed

- Symbol demangling under contention no longer exhausts threads; the demangler is called outside the lock.
- A precedence bug in the materialiser applied the wrong handler to certain edge case sequences.
- Async cleanup in the fuzz loop could skip finalisation, leaving attempt counts and corpus state inconsistent across resumes.
- Attempt indices now carry across crash-recovery resumes, so `FaultCluster.firstSeenAttempt` reflects the original discovery rather than restarting from zero.
- The operand energy table enforces its non-zero key invariant, preventing a zero key from silently evicting live entries.

## [1.1.0] - 2026-09-03

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

[Unreleased]: https://github.com/nesevis/exhaust/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/nesevis/exhaust/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/nesevis/exhaust/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/nesevis/exhaust/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/nesevis/exhaust/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/nesevis/exhaust/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/nesevis/exhaust/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/nesevis/exhaust/releases/tag/v1.0.0
