// Shared types, reduction algorithm, and pipeline for the synchronous and async preemptive contract runners.
import ExhaustCore

/// Namespace for machinery shared by ``PreemptiveChecker`` (synchronous) and ``AsyncPreemptiveChecker``.
///
/// The two checkers differ only in how a single probe runs — direct GCD execution versus async bridged through a drain loop — so the outcome shape and the three-pass reducer live here and are parameterised by each checker's `execute`.
enum Preemptive {
    /// Outcome of one preemptive concurrent execution.
    ///
    /// `timedOut` distinguishes a hang (a wedged lane or a drain-loop idle bailout) from a genuine pass or property failure, so the runner reports the hang as a timeout rather than dressing it up as a confirmed race. A timed-out run always has `passed == false`.
    struct Outcome {
        let passed: Bool
        let timedOut: Bool
    }

    /// Result of the three-pass preemptive reducer.
    struct ReductionResult<Command> {
        let output: [(ScheduleMarker, Command)]
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Reduces a counterexample in three passes, each targeting a different encoder set. The only thing that varies between the two checkers is `execute`.
    ///
    /// The three-pass structure is deliberate: preemptive evaluation is non-deterministic (GCD thread preemption), so each probe requires multiple repetitions to confirm. Phased reduction ensures the most impactful transformations run first before budget is spent on fine-tuning.
    ///
    /// **Pass 1 — Lane Collapse.** Drives lane markers to zero, moving commands into the sequential prefix. Prefix commands execute deterministically (no scheduling noise), so a longer prefix produces counterexamples that are easier to reproduce and reason about. Running lane collapse first also reduces the repetition cost of later passes — fewer concurrent commands means less non-deterministic scheduling per evaluation. (The cooperative runner skips this pre-pass because its schedule is choice-encoded and fully deterministic.)
    ///
    /// **Pass 2 — Structural.** Deletion, migration, and substitution. Removes unnecessary commands and simplifies arguments, operating on the already-collapsed trace so deletions target only commands genuinely needed for the failure.
    ///
    /// **Pass 3 — Value Minimization.** All remaining encoders. Simplifies command arguments toward their semantic simplest form. Runs with a tighter budget (1 stall, 5s) since the structural shape is already minimal.
    static func reduce<Command>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        repetitions: Int,
        execute: ([(ScheduleMarker, Command)]) -> Outcome
    ) -> ReductionResult<Command> {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if execute(taggedCommands).passed == false {
                    return false
                }
            }
            return true
        }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let valueMinimization = Set(EncoderName.allCases).subtracting(structural).subtracting([.laneCollapse])

        var currentOutput = output
        var currentTree = tree
        var aggregateStats = ReductionStats()

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10_000_000_000, enabledEncoders: [.laneCollapse]),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(sequence, reduced) = result.outcome {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 30_000_000_000, enabledEncoders: structural),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(sequence, reduced) = result.outcome {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 5_000_000_000, enabledEncoders: valueMinimization),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(_, reduced) = result.outcome {
                currentOutput = reduced
            }
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations, stats: aggregateStats)
    }
}

// MARK: - Backend

/// The per-probe operations that differ between the synchronous and async preemptive runners.
///
/// Everything else — phase ordering, smoke, SCA coverage, sampling, reduction, and failure assembly — is shared in ``__ExhaustRuntime/runPreemptivePipeline(backend:config:)``. The synchronous backend runs commands directly on GCD threads; the async backend bridges each probe through a drain loop.
///
/// Conformers are captured into the `@Sendable` property closure handed to the SCA coverage and reduction passes, so they must be `Sendable`. Both checkers store only an `Int?` timeout, so this is unconditional.
protocol PreemptiveBackend<Spec>: Sendable {
    associatedtype Spec: ContractSpecBase

    /// Builds the skip-identifier closure used to prune precondition-failing commands before reduction. The two backends construct it differently (a static identifier versus a `specInit`-seeded async bridge).
    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>

    /// Runs one tagged command sequence concurrently and reports whether invariants and the oracle held.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome

    /// Runs a command sequence sequentially on a fresh spec for the smoke phase, capturing the trace, whether it failed, and the resulting oracle state for the report.
    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String)

    /// Replays the reduced commands sequentially on a fresh spec to capture the expected (race-free) oracle state for a failure result.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> ContractResult<Spec>
}

// MARK: - Pipeline

extension __ExhaustRuntime {
    /// Runs the shared preemptive pipeline — smoke, SCA coverage, then random sampling with three-pass reduction — over a backend that supplies per-probe execution, the smoke trace, and oracle replay.
    ///
    /// Rendered failure messages are returned as deferred issues rather than reported inline, so each entry point can report them in a context where Swift Testing task-locals are available (the pipeline itself runs on a GCD thread). The fully-populated ``ExhaustReport`` is returned for the entry point to deliver to `onReport`.
    static func runPreemptivePipeline<Backend: PreemptiveBackend>(
        backend: Backend,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String] = []
    ) -> (result: ContractResult<Backend.Spec>?, deferredIssues: [String], report: ExhaustReport) {
        typealias Spec = Backend.Spec
        let runStopwatch = Stopwatch()
        var report = ExhaustReport()
        report.seed = config.seed
        var deferredIssues: [String] = []

        func finalizeReport() {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
        }

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? 8
        let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let samplingBudget = config.budget.samplingBudget
        let coverageBudget = config.budget.coverageBudget
        var coverageInvocations = 0
        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)

        let identifySkips = backend.makeIdentifySkips()
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let outcome = backend.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            return outcome.passed
        }

        // Regression seeds: replay each through the same pipeline with the appropriate replay config.
        if config.coverageReplayRow == nil, config.seed == nil {
            for encodedSeed in regressionSeeds {
                let samplingSeed = CrockfordBase32.decodeWithIteration(encodedSeed)
                let coverageRow = CrockfordBase32.decodeCoverageRow(encodedSeed)
                guard samplingSeed != nil || coverageRow != nil else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                var replayConfig = config
                if let coverageRow {
                    replayConfig.coverageReplayRow = coverageRow
                    let needed = UInt64(coverageRow) + 1
                    if replayConfig.budget.coverageBudget < needed {
                        replayConfig.budget = .custom(
                            coverage: needed,
                            sampling: replayConfig.budget.samplingBudget
                        )
                    }
                } else if let (seed, iteration) = samplingSeed {
                    replayConfig.seed = seed
                    replayConfig.replayIteration = iteration
                }

                let (replayResult, replayIssues, _) = runPreemptivePipeline(
                    backend: backend,
                    config: replayConfig
                )
                deferredIssues.append(contentsOf: replayIssues)

                if let replayResult {
                    finalizeReport()
                    return (replayResult, deferredIssues, report)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes — consider removing it.")
                }
            }
        }

        // Phase 0: Smoke test — deterministically seeded so U-prefixed replay seeds reproduce the same command sequence.
        if config.seed == nil, config.replayIteration == nil {
            let smokeGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
            var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, seed: 0, maxRuns: coverageBudget)
            var smokeRow = 0
            do { while let (commands, _) = try smokeIterator.next() {
                if let coverageReplayRow = config.coverageReplayRow, smokeRow < coverageReplayRow {
                    smokeRow += 1
                    continue
                }
                let smoke = backend.runSmoke(commands)
                if smoke.failed {
                    let result = ContractResult<Spec>(
                        commands: commands,
                        trace: smoke.trace,
                        systemUnderTest: smoke.systemUnderTest,
                        seed: nil,
                        replaySeed: CrockfordBase32.encodeCoverageRow(smokeRow),
                        discoveryMethod: .smokeTest
                    )
                    if config.suppressIssueReporting == false {
                        let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                        let message = renderFailure(result, failureInfo: failureInfo, failureDescription: smoke.failureDescription)
                        deferredIssues.append(message)
                    }
                    finalizeReport()
                    return (result, deferredIssues, report)
                }
                smokeRow += 1
                if config.coverageReplayRow != nil { break }
            } } catch {
                deferredIssues.append("Generator failed during smoke test: \(error)")
            }
        }

        // Phase 1: Coverage
        if config.shouldRunCoverage {
            if let scaResult = runConcurrentSCACoverage(
                seqGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                concurrencyLevel: config.concurrencyLevel,
                idleTimeout: config.idleTimeout,
                skipToRow: config.coverageReplayRow,
                property: property,
                identifySkips: identifySkips,
                lastRunTimedOut: lastRunTimedOut,
                invocationCounter: invocationCounter
            ) {
                if let stats = scaResult.reductionStats {
                    report.applyReductionStats(stats)
                }
                report.reductionInvocations = scaResult.reductionInvocations

                let scaReplaySeed = CrockfordBase32.encodeCoverageRow(Int(scaResult.iteration) - 1)
                let result = backend.buildResult(
                    reduced: scaResult.finalInput,
                    seed: nil,
                    replaySeed: scaReplaySeed,
                    discoveryMethod: .coverage
                )
                report.setConcurrentInvocations(
                    totalInvocations: invocationCounter.value,
                    coverageThroughReduction: invocationCounter.value,
                    reduction: scaResult.reductionInvocations,
                    discoveredDuringCoverage: true
                )

                if config.suppressIssueReporting == false {
                    deferredIssues.append(makePreemptiveFailureMessage(
                        scaResult.finalInput,
                        trace: result.trace,
                        specName: "\(Spec.self)",
                        discoveryMethod: .coverage,
                        seed: nil,
                        iteration: Int(scaResult.iteration),
                        budget: coverageBudget,
                        sequencesTested: invocationCounter.value,
                        reductionInvocations: scaResult.reductionInvocations,
                        originalCount: scaResult.originalCount,
                        replaySeed: scaReplaySeed,
                        timedOut: scaResult.timedOut,
                        oracleState: result.systemUnderTest as Any
                    ))
                }

                finalizeReport()
                return (result, deferredIssues, report)
            }
        }
        coverageInvocations = invocationCounter.value

        // Phase 2: Sampling
        if config.coverageReplayRow == nil {
            let startIndex = config.replayIteration.map { UInt64($0 - 1) } ?? 0
            let maxRuns = config.replayIteration.map { UInt64($0) } ?? samplingBudget
            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: config.seed,
                maxRuns: maxRuns,
                initialRunIndex: startIndex
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do { while let (taggedCommands, tree) = try interpreter.next() {
                samplingIteration += 1
                let absoluteIteration = Int(startIndex) + samplingIteration
                let outcome = backend.execute(taggedCommands)
                if outcome.passed == false {
                    // Reduction stays correct on a timeout — the reducer only ever returns a failing schedule — but on a hang every probe waits out the idle bound (idleTimeout × repetitions) and a timing-dependent timeout often will not reproduce, so it is slow and usually fruitless. Skip it and report the original schedule.
                    let reduced: [(ScheduleMarker, Spec.Command)]
                    let reductionInvocations: Int
                    if outcome.timedOut {
                        reduced = taggedCommands
                        reductionInvocations = 0
                    } else {
                        let reductionResult = Preemptive.reduce(
                            generator: sequenceGen,
                            tree: tree,
                            output: taggedCommands,
                            repetitions: 10,
                            execute: backend.execute
                        )
                        reduced = reductionResult.output
                        reductionInvocations = reductionResult.propertyInvocations
                        report.applyReductionStats(reductionResult.stats)
                    }

                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    let samplingReplaySeed = CrockfordBase32.encode(seed: actualSeed, iteration: absoluteIteration)
                    let result = backend.buildResult(
                        reduced: reduced,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )

                    report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: reductionInvocations)

                    if config.suppressIssueReporting == false {
                        deferredIssues.append(makePreemptiveFailureMessage(
                            reduced,
                            trace: result.trace,
                            specName: "\(Spec.self)",
                            discoveryMethod: discoveryMethod,
                            seed: actualSeed,
                            iteration: absoluteIteration,
                            budget: samplingBudget,
                            sequencesTested: samplingIteration,
                            reductionInvocations: reductionInvocations,
                            originalCount: taggedCommands.count,
                            replaySeed: samplingReplaySeed,
                            timedOut: outcome.timedOut,
                            oracleState: result.systemUnderTest as Any
                        ))
                    }

                    finalizeReport()
                    return (result, deferredIssues, report)
                }
            } } catch {
                deferredIssues.append("Generator failed during sampling: \(error)")
            }
        }

        report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: 0)
        finalizeReport()
        return (nil, deferredIssues, report)
    }

    /// Assembles the rendered failure message shared by the coverage and sampling phases.
    ///
    /// The two phases differ only in their discovery metadata (seed, iteration, budget, counts, replay seed). Everything else — the preemptive flag, the timeout-diagnostic gate, and the expected-state line built from the sequential oracle replay — is identical, so it lives here rather than being spelled out at each call site.
    private static func makePreemptiveFailureMessage(
        _ input: [(ScheduleMarker, some CustomStringConvertible)],
        trace: [TraceStep],
        specName: String,
        discoveryMethod: ContractDiscoveryMethod,
        seed: UInt64?,
        iteration: Int,
        budget: UInt64,
        sequencesTested: Int,
        reductionInvocations: Int,
        originalCount: Int,
        replaySeed: String,
        timedOut: Bool,
        oracleState: Any
    ) -> String {
        var failureContext = FailureContext()
        failureContext.isPreemptive = true
        failureContext.specName = specName
        failureContext.discoveryMethod = discoveryMethod
        failureContext.seed = seed
        failureContext.iteration = iteration
        failureContext.budget = budget
        failureContext.sequencesTested = sequencesTested
        failureContext.reductionInvocations = reductionInvocations
        failureContext.originalCount = originalCount
        failureContext.replaySeed = replaySeed
        // When set, the renderer emits the timeout diagnostic and ignores the expected-state line below.
        failureContext.timedOut = timedOut
        failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(oracleState)"
        return renderFailure(input, trace: trace, context: failureContext)
    }
}
