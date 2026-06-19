// Shared types, reduction algorithm, and pipeline for the synchronous and async preemptive contract runners.
import ExhaustCore

/// Namespace for machinery shared by ``PreemptiveChecker`` (synchronous) and ``AsyncPreemptiveChecker``.
///
/// The two checkers differ only in how a single probe runs (direct GCD execution versus async bridged through a drain loop), so the outcome shape, single-pass reducer, and pipeline live here and are parameterised by each checker's `execute`.
enum Preemptive {
    /// Number of times each reduction probe re-executes the concurrent schedule to probabilistically confirm the race still reproduces. Runs once per candidate inside the reduction loop, so this is kept small.
    static let confirmationRepetitions = 25

    /// Number of times the terminal ``confirmRealFailure`` re-executes the reported schedule to reproduce the race for evidence and final confirmation. This runs at most once per reported failure (not per reduction probe), so it can afford far more attempts than ``confirmationRepetitions``: catching a timing-fragile race here is what attaches the actual-state line and witness to the report. For a race that reproduces with probability `p` per run, the chance of catching it scales as `1 - (1 - p)^n`.
    static let finalConfirmationRepetitions = 50

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
                // Rebuild the tree from the reduced sequence so the next pass starts from a consistent (output, tree) pair, using the rematerialized value and tree together. Exact replay is sufficient: structural deletion runs first on the pruned tree (see reduceConfirmedFailure), before any rematerialize here, so no pass has to compute removal spans against this tree.
                if rematerialize,
                   case let .success(value, tree, _) = Materializer.materialize(
                       generator,
                       prefix: sequence,
                       mode: .exact
                   )
                {
                    currentOutput = value
                    currentTree = tree
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
        // Classifies one execution against linearizability — the single decision shared by the sampling/coverage property, the reduction probe, and failure confirmation. Returns the failing outcome (and any response-level witness) for a genuine violation: a non-linearizable execution, or an oracle failure with no lane responses (invariant/exception/timeout, real by construction). Returns nil when the execution passed the oracle or was confirmed linearizable (a false positive to skip). The prefix is taken from `taggedCommands` itself so the lane responses fed to the checker match the schedule being classified.
        let classifyFailure: @Sendable ([(ScheduleMarker, Spec.Command)], Preemptive.Outcome) -> (outcome: Preemptive.Outcome, witness: ResponseWitness?)? = { taggedCommands, outcome in
            if outcome.passed {
                return nil
            }
            guard let laneResponses = outcome.laneResponses, let concurrentSpec = outcome.concurrentSpec else {
                return (outcome, nil)
            }
            let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
            guard case let .notLinearizable(witness) = backend.checkLinearizability(
                prefix: prefixCommands,
                laneResponses: laneResponses,
                concurrentSpec: concurrentSpec
            ) else {
                return nil
            }
            return (outcome, witness)
        }

        // Linearizability-integrated property used by SCA coverage and sampling: returns false only for a genuine non-linearizable (or no-lane-response) failure, so passing and merely-linearizable executions are transparently skipped. Records the failing outcome for evidence rendering.
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let outcome = backend.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            guard let failure = classifyFailure(taggedCommands, outcome) else {
                return true
            }
            lastFailingOutcome.value = failure.outcome
            return false
        }

        /// Confirms whether `input` is a genuine failure by re-executing it up to ``Preemptive/finalConfirmationRepetitions`` times and accepting the first reproduction classified non-linearizable.
        /// Preemptive execution is non-deterministic, so a single re-execution can draw a passing (or merely linearizable) interleaving and miss the race. This is the terminal confirmation (once per reported failure, not per reduction probe), so it uses the larger repetition budget: a timing-fragile race that the 10-rep reduction loop could not re-trigger often still reproduces here, attaching the actual-state line and witness to the report.
        /// Returns the confirming execution's outcome (so its lane responses and final state render coherently with the verdict) and the response-level witness, or `nil` when no run reproduced a genuine violation.
        func confirmRealFailure(_ input: [(ScheduleMarker, Spec.Command)]) -> (outcome: Preemptive.Outcome, witness: ResponseWitness?)? {
            for _ in 0 ..< Preemptive.finalConfirmationRepetitions {
                if let confirmed = classifyFailure(input, backend.execute(input)) {
                    return confirmed
                }
            }
            return nil
        }

        /// Reduction property in ``Preemptive/Outcome`` form: a probe "passes" when its execution is linearizable, so structural reduction keeps only commands whose removal would dissolve a genuine response-level violation. (A bare oracle property would strip commands whose return values carry the response-level evidence.)
        func linearizableExecute(_ probeCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome {
            let probeOutcome = backend.execute(probeCommands)
            guard classifyFailure(probeCommands, probeOutcome) == nil else {
                return probeOutcome
            }
            return probeOutcome.passed
                ? probeOutcome
                : Preemptive.Outcome(passed: true, timedOut: false, laneResponses: nil, concurrentSpec: nil)
        }

        /// Per-lane observed return values for failure annotation, keyed by ``ScheduleMarker/rawValue`` in per-lane execution order.
        func laneResponseValues(from outcome: Preemptive.Outcome?) -> [UInt8: [String?]]? {
            guard let outcome,
                  let typedResponses = outcome.laneResponses as? [[ObservedResponse<Spec.Command>]]
            else { return nil }
            var values: [UInt8: [String?]] = [:]
            for laneArray in typedResponses {
                for response in laneArray {
                    values[response.lane, default: []].append(response.outcome.displayValue)
                }
            }
            return values
        }

        /// Reduces a discovered failure to its reported form, shared by the coverage and sampling phases (which differ only in discovery metadata).
        ///
        /// Prunes skipped commands, grows the deterministic prefix (lane collapse, oracle property), simplifies structurally under the linearizability property, then re-confirms and canonicalizes prefix-first. Applies reduction stats to the report. Returns the reported schedule, its total reduction-probe count, the response witness, and the confirming execution's outcome (for evidence and actual-state rendering). `reportedOutcome` is nil when reduction dissolved the violation and the pruned schedule is reported as a fallback.
        func reduceConfirmedFailure(
            taggedCommands: [(ScheduleMarker, Spec.Command)],
            tree: ChoiceTree,
            pruneSeed: UInt64
        ) -> (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome?) {
            // Prune commands whose preconditions were not met: a skipped command is a no-op, so removing it up front keeps reduction on the minimal command set and the reported counterexample carries no skipped commands. The prune is reverted if removing the skips dissolves the violation.
            let (prunedCommands, prunedTree) = pruneSkippedCommands(
                value: taggedCommands,
                tree: tree,
                generator: sequenceGen,
                seed: pruneSeed,
                property: property,
                identifySkips: identifySkips,
                logEvent: "preemptive_skip_pruning"
            )

            // Single combined pass: deletion, lane collapse and value minimisation together, all under the linearizability property. The graph reducer emits removal candidates before lane-collapse candidates each cycle (CandidateSource.buildSources order) and re-runs across cycles, so deletions and prefix-growth interleave and can compound. Only deletion and lane collapse are enabled: substitution needs recursive/self-similar structure a flat command pick lacks, and migration restructures the concurrent set, suppressing the race for later deletion probes.
            // Running lane collapse under linearizableExecute (not the oracle) makes every accepted collapse self-validate as non-linearizable — so the combined output is already a confirmed counterexample, with no need for a separate collapse re-confirmation gate. Within one pass, lane collapse's reorder triggers a full graph rebuild before the next cycle's deletion candidates are built, so it does not reintroduce the cross-pass decode failure that previously forced the split.
            let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
            let combinedResult = Preemptive.reduceSinglePass(
                generator: sequenceGen,
                tree: prunedTree,
                output: prunedCommands,
                encoders: [.deletion, .laneCollapse, .valueSearch, .floatSearch],
                maxStalls: 2,
                deadlineNanoseconds: 15_000_000_000,
                rematerialize: true,
                repetitions: Preemptive.confirmationRepetitions,
                tuning: noRelax,
                execute: linearizableExecute
            )
            report.applyReductionStats(combinedResult.stats)

            // The combined output is already validated as non-linearizable by the pass (every accepted probe, deletion or collapse, kept it failing under linearizableExecute). Report it unconditionally — never discard the reduction. confirmRealFailure is evidence-only here: a reproducing run supplies coherent lane responses and actual state; a failure to reproduce leaves the evidence empty (the report shows expected-state only) rather than borrowing the original discovering run's, whose schedule no longer matches.
            let reportedOutcome = confirmRealFailure(combinedResult.output)
            // Present prefix-first. The runner runs all prefix commands sequentially before any lane (execute() partitions by marker, not array position), so reordering is execution-equivalent and makes the execution trace honest.
            let reduced = combinedResult.output.filter(\.0.isPrefix) + combinedResult.output.filter { $0.0.isPrefix == false }

            return (
                reduced,
                combinedResult.propertyInvocations,
                reportedOutcome?.witness,
                reportedOutcome?.outcome
            )
        }

        /// Builds the result, records invocation counts, renders the failure issue, and finalizes the report for a reduced failure. The coverage and sampling phases run this identical six-step sequence after ``reduceConfirmedFailure`` and differ only in discovery metadata, so it lives here rather than being spelled out at each phase.
        func assembleReducedFailure(
            reduction: (reduced: [(ScheduleMarker, Spec.Command)], reductionInvocations: Int, witness: ResponseWitness?, reportedOutcome: Preemptive.Outcome?),
            discoveryMethod: ContractDiscoveryMethod,
            seed: UInt64?,
            iteration: Int,
            budget: UInt64,
            sequencesTested: Int,
            originalCount: Int,
            replaySeed: String,
            coverageInvocations: Int,
            randomSamplingInvocations: Int
        ) -> (result: ContractResult<Spec>?, deferredIssues: [String], report: ExhaustReport) {
            let (result, failureDescription) = backend.buildResult(
                reduced: reduction.reduced,
                seed: seed,
                replaySeed: replaySeed,
                discoveryMethod: discoveryMethod
            )
            report.setInvocations(
                coverage: coverageInvocations,
                randomSampling: randomSamplingInvocations,
                reduction: reduction.reductionInvocations
            )
            if config.suppressIssueReporting == false {
                // Evidence comes only from the reported schedule's own confirming run; when it could not be reproduced, the report shows expected-state only rather than borrowing the original discovering run's (mismatched) evidence.
                deferredIssues.append(makePreemptiveFailureMessage(
                    reduction.reduced,
                    specName: "\(Spec.self)",
                    discoveryMethod: discoveryMethod,
                    seed: seed,
                    iteration: iteration,
                    budget: budget,
                    sequencesTested: sequencesTested,
                    reductionInvocations: reduction.reductionInvocations,
                    originalCount: originalCount,
                    replaySeed: replaySeed,
                    timedOut: false,
                    expectedDescription: failureDescription,
                    actualDescription: (reduction.reportedOutcome?.concurrentSpec as? Spec)?.failureDescription(),
                    laneResponseValues: laneResponseValues(from: reduction.reportedOutcome),
                    linearizabilityWitness: reduction.witness
                ))
            }
            finalizeReport()
            return (result, deferredIssues, report)
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
                let reduction = reduceConfirmedFailure(
                    taggedCommands: taggedCommands,
                    tree: tree,
                    pruneSeed: UInt64(coverageIterations)
                )
                // Reduction probes run through reduceSinglePass's own counter, not the shared invocationCounter, so the three buckets are already disjoint: coverage takes the shared counter, sampling is zero, reduction its own count. (setConcurrentInvocations assumes reduction flows through the shared counter, which would drive coverage negative here.)
                return assembleReducedFailure(
                    reduction: reduction,
                    discoveryMethod: .coverage,
                    seed: nil,
                    iteration: coverageIterations,
                    budget: coverageBudget,
                    sequencesTested: invocationCounter.value,
                    originalCount: taggedCommands.count,
                    replaySeed: ReplaySeed.Resolved.encodeCoverageIteration(coverageIterations),
                    coverageInvocations: invocationCounter.value,
                    randomSamplingInvocations: 0
                )
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

                    let reduction = reduceConfirmedFailure(
                        taggedCommands: taggedCommands,
                        tree: tree,
                        pruneSeed: UInt64(absoluteIteration)
                    )
                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    return assembleReducedFailure(
                        reduction: reduction,
                        discoveryMethod: discoveryMethod,
                        seed: actualSeed,
                        iteration: absoluteIteration,
                        budget: samplingBudget,
                        sequencesTested: coverageInvocations + samplingIteration,
                        originalCount: taggedCommands.count,
                        replaySeed: ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded,
                        coverageInvocations: coverageInvocations,
                        randomSamplingInvocations: samplingIteration
                    )
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
        linearizabilityWitness: ResponseWitness? = nil
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
        failureContext.linearizabilityWitness = linearizabilityWitness
        let trace = __ExhaustRuntime.buildPreemptiveTrace(
            input,
            laneResponseValues: laneResponseValues,
            linearizabilityWitness: linearizabilityWitness
        )
        return renderFailure(input, trace: trace, context: failureContext)
    }
}
