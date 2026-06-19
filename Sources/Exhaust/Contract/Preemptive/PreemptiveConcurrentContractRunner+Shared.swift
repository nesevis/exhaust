// Shared types, reduction algorithm, and pipeline for the synchronous and async preemptive contract runners.
import ExhaustCore

/// Namespace for machinery shared by ``PreemptiveChecker`` (synchronous) and ``AsyncPreemptiveChecker``.
///
/// The two checkers differ only in how a single probe runs (direct GCD execution versus async bridged through a drain loop), so the outcome shape, single-pass reducer, and pipeline live here and are parameterised by each checker's `execute`.
enum Preemptive {
    /// Number of times each reduction probe re-executes the concurrent schedule to probabilistically confirm the race still reproduces.
    static let confirmationRepetitions = 10

    /// Default command limit for `.threads` contracts. Lower than the cooperative runner's estimated/40 cap because each probe repeats `confirmationRepetitions` times.
    static let defaultCommandLimit = 8

    /// Outcome of one preemptive concurrent execution.
    ///
    /// `timedOut` distinguishes a hang (a wedged lane or a drain-loop idle bailout) from a genuine pass or property failure, so the runner reports the hang as a timeout rather than dressing it up as a confirmed race. A timed-out run always has `passed == false`.
    ///
    /// On failure, `laneResponses` carries the per-lane observed responses for linearizability confirmation. On pass or timeout, `laneResponses` is `nil` because responses are only worth preserving when the oracle flags a potential violation. The inner type is erased to `Any` so `Outcome` stays non-generic across the reduction pipeline. Callers cast to `[[ObservedResponse<Command>]]` when consuming.
    struct Outcome {
        let passed: Bool
        let timedOut: Bool
        let laneResponses: Any?
        let concurrentSpec: Any?
    }

    /// Result of a preemptive reduction pass.
    struct ReductionResult<Command> {
        let output: [(ScheduleMarker, Command)]
        let tree: ChoiceTree
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Runs a single reduction pass with the given encoder set and property function.
    static func reduceSinglePass<Command>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        encoders: Set<EncoderName>,
        maxStalls: Int,
        deadlineNanoseconds: UInt64,
        rematerialize: Bool,
        repetitions: Int,
        tuning: SchedulerTuning = .init(),
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

        var currentOutput = output
        var currentTree = tree
        var stats = ReductionStats()

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(
                maxStalls: maxStalls,
                wallClockDeadlineNanoseconds: deadlineNanoseconds,
                enabledEncoders: encoders,
                tuning: tuning
            ),
            property: property
        ) {
            stats.merge(result.stats)
            if case let .reduced(sequence, reduced) = result.outcome {
                currentOutput = reduced
                if rematerialize,
                   case let .success(_, freshTree, _) = Materializer.materialize(
                       generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                   )
                {
                    currentTree = freshTree
                }
            }
        }

        return ReductionResult(output: currentOutput, tree: currentTree, propertyInvocations: propertyInvocations, stats: stats)
    }
}

// MARK: - Backend

/// The per-probe operations that differ between the synchronous and async preemptive runners.
///
/// Everything else (phase ordering, smoke, SCA coverage, sampling, reduction, and failure assembly) is shared in ``__ExhaustRuntime/runPreemptivePipeline(backend:config:)``. The synchronous backend runs commands directly on GCD threads; the async backend bridges each probe through a drain loop.
///
/// Conformers are captured into the `@Sendable` property closure handed to the SCA coverage and reduction passes, so they must be `Sendable`. Both checkers store only an `Int?` timeout, so this is unconditional.
protocol PreemptiveBackend<Spec>: Sendable {
    associatedtype Spec: ContractSpecBase

    /// Builds the skip-identifier closure used to prune precondition-failing commands before reduction. The two backends construct it differently (a static identifier versus a `specInit`-seeded async bridge).
    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>

    /// Runs one tagged command sequence concurrently and reports whether invariants and the oracle held.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome

    /// Runs a command sequence sequentially on a fresh spec for the smoke phase, capturing the trace, whether it failed, and the resulting oracle state for the report.
    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?)

    /// Checks whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
    ///
    /// Called after lane-collapse reduction on oracle-flagged failures. If any valid interleaving produces matching responses and passes the oracle, the execution is linearizable and the failure was a false positive.
    ///
    /// - Parameters:
    ///   - prefix: The sequential prefix commands.
    ///   - laneResponses: The type-erased per-lane observed responses from `Outcome.laneResponses`. Callers cast internally.
    ///   - concurrentSpec: The concurrent spec instance after execution, kept alive for oracle calls.
    /// - Returns: The linearizability verdict with closest-ordering information on failure.
    func checkLinearizability(
        prefix: [Spec.Command],
        laneResponses: Any,
        concurrentSpec: Any
    ) -> LinearizabilityResult

    /// Replays the reduced commands sequentially on a fresh spec to capture the expected (race-free) oracle state for a failure result.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> (result: ContractResult<Spec>, failureDescription: String?)
}

// MARK: - Pipeline

extension __ExhaustRuntime {
    /// Runs the shared preemptive pipeline (smoke, SCA coverage, then random sampling with reduction) over a backend that supplies per-probe execution, the smoke trace, and oracle replay.
    ///
    /// The pipeline uses two levels of correctness checking. The fixed-ordering oracle is the fast entry filter: it compares the concurrent SUT's final state against one sequential replay (array order), which is cheap but can false-positive when GCD picks a valid but different ordering. Linearizability is the authority: it tries all valid orderings, comparing both per-command responses and final state via the oracle. The oracle is never bypassed. It runs inside each linearizability check as the state comparator.
    ///
    /// Sampling and lane-collapse use the oracle as their property function (fast, over-reports). Once a candidate survives lane-collapse, linearizability confirms it. Structural reduction uses linearizability as its property function, so commands whose return values carry response-level evidence are not stripped.
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
        let commandLimit = config.commandLimit ?? Preemptive.defaultCommandLimit
        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            finalizeReport()
            return (nil, deferredIssues, report)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let samplingBudget = config.budget.samplingBudget
        let coverageBudget = config.budget.coverageBudget
        var coverageInvocations = 0
        // Single-threaded: the reducer and SCA row loop call the property sequentially on the pipeline GCD thread.
        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)

        let identifySkips = backend.makeIdentifySkips()
        let lastFailingOutcome = UnsafeSendableBox<Preemptive.Outcome?>(nil)
        // Linearizability-integrated property: executes, checks the oracle (fast filter), then checks linearizability on oracle failures. Returns `true` for passing or linearizable executions — only genuinely non-linearizable failures return `false`. Used by both SCA coverage and sampling so false positives are transparently skipped everywhere.
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let outcome = backend.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            if outcome.passed {
                return true
            }
            guard let laneResponses = outcome.laneResponses, let concurrentSpec = outcome.concurrentSpec else {
                lastFailingOutcome.value = outcome
                return false
            }
            let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
            let linearizability = backend.checkLinearizability(
                prefix: prefixCommands,
                laneResponses: laneResponses,
                concurrentSpec: concurrentSpec
            )
            if case .linearizable = linearizability {
                return true
            }
            lastFailingOutcome.value = outcome
            return false
        }

        /// Confirms whether `input` is a genuine failure by re-executing it and running the linearizability check on the result.
        /// Preemptive execution is non-deterministic, so a single re-execution can draw a passing (or merely linearizable) interleaving and miss the race; re-run up to confirmationRepetitions times and accept the first reproduction that is confirmed non-linearizable. The prefix is derived from `input` itself, so the lane responses fed to the checker always match the schedule being confirmed (a stale prefix would replay promoted commands twice and corrupt the verdict).
        /// Returns whether a real failure was confirmed and, when it was, the concurrent spec for failure-state rendering. Oracle failures lacking lane responses (invariant or exception failures) are real by construction and reported directly.
        func confirmRealFailure(_ input: [(ScheduleMarker, Spec.Command)]) -> (isReal: Bool, spec: Any?) {
            let prefixCommands = input.filter(\.0.isPrefix).map(\.1)
            for _ in 0 ..< Preemptive.confirmationRepetitions {
                let outcome = backend.execute(input)
                if outcome.passed {
                    continue
                }
                guard let laneResponses = outcome.laneResponses, let concurrentSpec = outcome.concurrentSpec else {
                    return (true, outcome.concurrentSpec)
                }
                let linearizability = backend.checkLinearizability(
                    prefix: prefixCommands,
                    laneResponses: laneResponses,
                    concurrentSpec: concurrentSpec
                )
                if case .notLinearizable = linearizability {
                    return (true, concurrentSpec)
                }
            }
            return (false, nil)
        }

        func extractEvidence(from outcome: Preemptive.Outcome?) -> (laneResponseValues: [UInt8: [String?]], note: String?)? {
            guard let outcome,
                  let typedResponses = outcome.laneResponses as? [[ObservedResponse<Spec.Command>]]
            else { return nil }
            var values: [UInt8: [String?]] = [:]
            for laneArray in typedResponses {
                for response in laneArray {
                    values[response.lane, default: []].append(response.outcome.displayValue)
                }
            }
            return (values, nil)
        }

        // Regression seeds: replay each through the same pipeline with the appropriate replay config.
        if config.coverageReplayRow == nil, config.seed == nil {
            for encodedSeed in regressionSeeds {
                guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                var replayConfig = config
                switch decoded {
                    case let .coverage(row: row):
                        replayConfig.coverageReplayRow = row
                        let needed = UInt64(row) + 1
                        if replayConfig.budget.coverageBudget < needed {
                            replayConfig.budget = .custom(
                                coverage: needed,
                                sampling: replayConfig.budget.samplingBudget
                            )
                        }
                    case let .sampling(seed, iteration):
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
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        // Phase 0: Smoke test. Run the first deterministic command sequence sequentially.
        // If the spec is broken without concurrency, fail fast before investing in concurrent probing.
        do {
            let smokeGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
            var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, seed: 0, maxRuns: 1)
            if let (commands, _) = try smokeIterator.next() {
                let smoke = backend.runSmoke(commands)
                if smoke.failed {
                    let result = ContractResult<Spec>(
                        commands: commands,
                        trace: smoke.trace,
                        systemUnderTest: smoke.systemUnderTest,
                        seed: nil,
                        replaySeed: ReplaySeed.Resolved.sampling(seed: 0, iteration: 1).encoded,
                        discoveryMethod: .smokeTest
                    )
                    if config.suppressIssueReporting == false {
                        let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                        let message = renderFailure(result, failureInfo: failureInfo, failureDescription: smoke.failureDescription)
                        deferredIssues.append(message)
                    }
                    report.replaySeed = result.replaySeed
                    report.setInvocations(coverage: 0, randomSampling: 1, reduction: 0)
                    finalizeReport()
                    return (result, deferredIssues, report)
                }
            }
        } catch {
            deferredIssues.append("Generator failed during smoke test: \(error)")
        }

        // Phase 1: Coverage — the property integrates linearizability so the row loop skips false positives and only stops on genuine violations.
        if config.shouldRunCoverage {
            let effectiveCoverageBudget: UInt64 = if let row = config.coverageReplayRow {
                max(coverageBudget, UInt64(row) + 1)
            } else {
                coverageBudget
            }
            let scaRowResult = runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: effectiveCoverageBudget,
                skipToRow: config.coverageReplayRow,
                logEventPrefix: "concurrent_sca_coverage",
                property: property
            )
            if case let .failure(taggedCommands, tree, coverageIterations) = scaRowResult {
                let originalOutcome = lastFailingOutcome.value
                let originalCount = taggedCommands.count
                var originalEvidence = extractEvidence(from: originalOutcome)

                let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
                let laneCollapseResult = Preemptive.reduceSinglePass(
                    generator: sequenceGen,
                    tree: tree,
                    output: taggedCommands,
                    encoders: [.laneCollapse],
                    maxStalls: 2,
                    deadlineNanoseconds: 10_000_000_000,
                    rematerialize: true,
                    repetitions: Preemptive.confirmationRepetitions,
                    tuning: noRelax,
                    execute: backend.execute
                )
                report.applyReductionStats(laneCollapseResult.stats)
                var reductionInvocations = laneCollapseResult.propertyInvocations

                let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
                var coverageLastFailingOutcome: Preemptive.Outcome?
                let linearizableExecute: ([(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome = { probeCommands in
                    let probeOutcome = backend.execute(probeCommands)
                    if probeOutcome.passed {
                        return probeOutcome
                    }
                    guard let probeLaneResponses = probeOutcome.laneResponses,
                          let probeConcurrentSpec = probeOutcome.concurrentSpec
                    else {
                        coverageLastFailingOutcome = probeOutcome
                        return probeOutcome
                    }
                    let probePrefixCommands = probeCommands.filter(\.0.isPrefix).map(\.1)
                    let probeLinearizability = backend.checkLinearizability(
                        prefix: probePrefixCommands,
                        laneResponses: probeLaneResponses,
                        concurrentSpec: probeConcurrentSpec
                    )
                    if case .linearizable = probeLinearizability {
                        return Preemptive.Outcome(passed: true, timedOut: false, laneResponses: nil, concurrentSpec: nil)
                    }
                    coverageLastFailingOutcome = probeOutcome
                    return probeOutcome
                }
                let structuralResult = Preemptive.reduceSinglePass(
                    generator: sequenceGen,
                    tree: laneCollapseResult.tree,
                    output: laneCollapseResult.output,
                    encoders: structural,
                    maxStalls: 2,
                    deadlineNanoseconds: 15_000_000_000,
                    rematerialize: true,
                    repetitions: Preemptive.confirmationRepetitions,
                    tuning: noRelax,
                    execute: linearizableExecute
                )
                report.applyReductionStats(structuralResult.stats)
                reductionInvocations += structuralResult.propertyInvocations

                let reduced: [(ScheduleMarker, Spec.Command)] = if confirmRealFailure(structuralResult.output).isReal {
                    structuralResult.output
                } else {
                    taggedCommands.filter(\.0.isPrefix) + taggedCommands.filter { $0.0.isPrefix == false }
                }
                let scaReplaySeed = ReplaySeed.Resolved.encodeCoverageIteration(coverageIterations)
                let (result, failureDescription) = backend.buildResult(
                    reduced: reduced,
                    seed: nil,
                    replaySeed: scaReplaySeed,
                    discoveryMethod: .coverage
                )
                report.setConcurrentInvocations(
                    totalInvocations: invocationCounter.value,
                    coverageThroughReduction: invocationCounter.value,
                    reduction: reductionInvocations,
                    discoveredDuringCoverage: true
                )

                if config.suppressIssueReporting == false {
                    let evidence = extractEvidence(from: coverageLastFailingOutcome) ?? originalEvidence
                    deferredIssues.append(makePreemptiveFailureMessage(
                        reduced,
                        specName: "\(Spec.self)",
                        discoveryMethod: .coverage,
                        seed: nil,
                        iteration: coverageIterations,
                        budget: coverageBudget,
                        sequencesTested: invocationCounter.value,
                        reductionInvocations: reductionInvocations,
                        originalCount: originalCount,
                        replaySeed: scaReplaySeed,
                        timedOut: false,
                        expectedDescription: failureDescription,
                        actualDescription: (coverageLastFailingOutcome?.concurrentSpec as? Spec)?.failureDescription()
                            ?? (originalOutcome?.concurrentSpec as? Spec)?.failureDescription(),
                        laneResponseValues: evidence?.laneResponseValues,
                        linearizabilityNote: evidence?.note
                    ))
                }

                finalizeReport()
                return (result, deferredIssues, report)
            }
        }
        coverageInvocations = invocationCounter.value

        // Phase 2: Sampling
        if config.coverageReplayRow == nil {
            let (startIndex, maxRuns) = samplingReplayWindow(
                replayIteration: config.replayIteration,
                samplingBudget: samplingBudget
            )
            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: config.seed,
                maxRuns: maxRuns,
                initialRunIndex: startIndex
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do {
                while let (taggedCommands, tree) = try interpreter.next() {
                    samplingIteration += 1
                    let absoluteIteration = Int(startIndex) + samplingIteration
                    if property(taggedCommands) {
                        continue
                    }

                    // The property returned false — either a confirmed non-linearizable execution or a timeout/exception (no lane responses). The outcome is in lastFailingOutcome.
                    if lastRunTimedOut.value {
                        let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                        let samplingReplaySeed = ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded
                        let reportedInput = taggedCommands.filter(\.0.isPrefix) + taggedCommands.filter { $0.0.isPrefix == false }
                        let (result, failureDescription) = backend.buildResult(
                            reduced: reportedInput,
                            seed: actualSeed,
                            replaySeed: samplingReplaySeed,
                            discoveryMethod: discoveryMethod
                        )
                        report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: 0)
                        if config.suppressIssueReporting == false {
                            deferredIssues.append(makePreemptiveFailureMessage(
                                reportedInput,
                                specName: "\(Spec.self)",
                                discoveryMethod: discoveryMethod,
                                seed: actualSeed,
                                iteration: absoluteIteration,
                                budget: samplingBudget,
                                sequencesTested: coverageInvocations + samplingIteration,
                                reductionInvocations: 0,
                                originalCount: taggedCommands.count,
                                replaySeed: samplingReplaySeed,
                                timedOut: true,
                                expectedDescription: failureDescription,
                                actualDescription: nil
                            ))
                        }
                        finalizeReport()
                        return (result, deferredIssues, report)
                    }

                    let originalEvidence = extractEvidence(from: lastFailingOutcome.value)

                    // Confirmed non-linearizable. Lane-collapse (oracle property) grows the deterministic prefix; structural reduction then runs with linearizability as its property so the final counterexample stays genuine.
                    let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
                    let laneCollapseResult = Preemptive.reduceSinglePass(
                        generator: sequenceGen,
                        tree: tree,
                        output: taggedCommands,
                        encoders: [.laneCollapse],
                        maxStalls: 2,
                        deadlineNanoseconds: 10_000_000_000,
                        rematerialize: true,
                        repetitions: Preemptive.confirmationRepetitions,
                        tuning: noRelax,
                        execute: backend.execute
                    )
                    report.applyReductionStats(laneCollapseResult.stats)
                    var reductionInvocations = laneCollapseResult.propertyInvocations

                    // Confirmed non-linearizable. Structural reduction uses linearizability as its property function: a probe passes (the command is unnecessary) only if the reduced sequence is linearizable. Without this, the reducer would strip commands whose return values carry response-level evidence (the oracle doesn't need them, but linearizability does).
                    let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
                    var reductionLastFailingOutcome: Preemptive.Outcome?
                    let linearizableExecute: ([(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome = { probeCommands in
                        let probeOutcome = backend.execute(probeCommands)
                        if probeOutcome.passed {
                            return probeOutcome
                        }
                        guard let probeLaneResponses = probeOutcome.laneResponses,
                              let probeConcurrentSpec = probeOutcome.concurrentSpec
                        else {
                            reductionLastFailingOutcome = probeOutcome
                            return probeOutcome
                        }
                        let probePrefixCommands = probeCommands.filter(\.0.isPrefix).map(\.1)
                        let probeLinearizability = backend.checkLinearizability(
                            prefix: probePrefixCommands,
                            laneResponses: probeLaneResponses,
                            concurrentSpec: probeConcurrentSpec
                        )
                        if case .linearizable = probeLinearizability {
                            return Preemptive.Outcome(passed: true, timedOut: false, laneResponses: nil, concurrentSpec: nil)
                        }
                        reductionLastFailingOutcome = probeOutcome
                        return probeOutcome
                    }
                    let structuralResult = Preemptive.reduceSinglePass(
                        generator: sequenceGen,
                        tree: laneCollapseResult.tree,
                        output: laneCollapseResult.output,
                        encoders: structural,
                        maxStalls: 2,
                        deadlineNanoseconds: 15_000_000_000,
                        rematerialize: true,
                        repetitions: Preemptive.confirmationRepetitions,
                        tuning: noRelax,
                        execute: linearizableExecute
                    )
                    report.applyReductionStats(structuralResult.stats)
                    reductionInvocations += structuralResult.propertyInvocations

                    // Only report a schedule that is itself confirmed non-linearizable. Lane-collapse uses the oracle as its property, so it can promote a race-essential command into the prefix and leave a concurrent tail that is actually linearizable. Structural reduction can likewise over-reduce on a noisy probe. Re-confirm the reduced candidate, and fall back to the original sampled schedule (which the pre-filter already confirmed non-linearizable) when reduction dissolved the violation.
                    // ``GraphLaneCollapseEncoder`` already canonicalizes its output prefix-first (stablePartitionByPrefix), and the structural pass preserves that order, so the reduced schedule needs no reordering. The fallback is the raw sampled schedule in generation order (prefix interleaved with lanes); canonicalize only that, so every reported schedule presents prefix-first.
                    let reduced: [(ScheduleMarker, Spec.Command)] = if confirmRealFailure(structuralResult.output).isReal {
                        structuralResult.output
                    } else {
                        taggedCommands.filter(\.0.isPrefix) + taggedCommands.filter { $0.0.isPrefix == false }
                    }
                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    let samplingReplaySeed = ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded
                    let (result, failureDescription) = backend.buildResult(
                        reduced: reduced,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )

                    report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: reductionInvocations)

                    if config.suppressIssueReporting == false {
                        let evidence = extractEvidence(from: reductionLastFailingOutcome) ?? originalEvidence
                        deferredIssues.append(makePreemptiveFailureMessage(
                            reduced,
                            specName: "\(Spec.self)",
                            discoveryMethod: discoveryMethod,
                            seed: actualSeed,
                            iteration: absoluteIteration,
                            budget: samplingBudget,
                            sequencesTested: coverageInvocations + samplingIteration,
                            reductionInvocations: reductionInvocations,
                            originalCount: taggedCommands.count,
                            replaySeed: samplingReplaySeed,
                            timedOut: false,
                            expectedDescription: failureDescription,
                            actualDescription: (reductionLastFailingOutcome?.concurrentSpec as? Spec)?.failureDescription()
                                ?? (lastFailingOutcome.value?.concurrentSpec as? Spec)?.failureDescription(),
                            laneResponseValues: evidence?.laneResponseValues,
                            linearizabilityNote: evidence?.note
                        ))
                    }

                    finalizeReport()
                    return (result, deferredIssues, report)
                }
            } catch {
                deferredIssues.append("Generator failed during sampling: \(error)")
            }
        }

        report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: 0)
        finalizeReport()
        return (nil, deferredIssues, report)
    }

    /// Assembles the rendered failure message shared by the coverage and sampling phases.
    ///
    /// The two phases differ only in their discovery metadata (seed, iteration, budget, counts, replay seed). Everything else (the preemptive flag, the timeout-diagnostic gate, and the expected-state line built from the sequential oracle replay) is identical, so it lives here rather than being spelled out at each call site.
    private static func makePreemptiveFailureMessage(
        _ input: [(ScheduleMarker, some CustomStringConvertible)],
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
        expectedDescription: String?,
        actualDescription: String?,
        laneResponseValues: [UInt8: [String?]]? = nil,
        linearizabilityNote: String? = nil
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
        failureContext.timedOut = timedOut
        failureContext.oracleDescription = expectedDescription.map { "Expected state (from sequential replay):\n  \($0)" }
        failureContext.failureDescription = actualDescription.map { "Actual state (from concurrent execution):\n  \($0)" }
        failureContext.laneResponseValues = laneResponseValues
        failureContext.linearizabilityNote = linearizabilityNote
        let trace = __ExhaustRuntime.buildPreemptiveTrace(input, laneResponseValues: laneResponseValues)
        return renderFailure(input, trace: trace, context: failureContext)
    }
}
