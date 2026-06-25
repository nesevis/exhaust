import ExhaustCore

// MARK: - Entry Point

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

        var report = ExhaustReport()
        report.seed = config.seed

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? PreemptiveReduction.defaultCommandLimit
        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            report.totalMilliseconds = 0
            return (nil, ["Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure."], report)
        }

        var failureContext = FailureContext()
        failureContext.specName = "\(Spec.self)"
        failureContext.isPreemptive = true

        var context = PreemptivePipelineContext(
            backend: backend,
            config: config,
            regressionSeeds: regressionSeeds,
            sequenceGen: Gen.arrayOf(taggedCommandGen, within: 1 ... UInt64(commandLimit), scaling: .constant),
            taggedCommandGen: taggedCommandGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            samplingBudget: config.budget.samplingBudget,
            coverageBudget: config.budget.coverageBudget,
            identifySkips: backend.makeIdentifySkips(),
            runStopwatch: Stopwatch(),
            invocationCounter: UnsafeSendableBox(0),
            lastRunTimedOut: UnsafeSendableBox(false),
            report: report,
            deferredIssues: [],
            failureContext: failureContext
        )

        if let result = runRegressionSeeds(&context) { return result }
        if let result = runSmokeTest(&context) { return result }

        let property = makeProperty(&context)
        let linearizableProbe = makeLinearizableProbe(&context)

        if let result = runCoveragePhase(&context, property: property, linearizableProbe: linearizableProbe) {
            return result
        }
        context.coverageInvocations = context.invocationCounter.value

        if let result = runSamplingPhase(&context, property: property, linearizableProbe: linearizableProbe) {
            return result
        }

        context.report.setInvocations(coverage: context.coverageInvocations, randomSampling: 0, reduction: 0)
        finalizeReport(&context)
        return (nil, context.deferredIssues, context.report)
    }
}

// MARK: - Pipeline Phases

private extension __ExhaustRuntime {
    /// Replays each regression seed by re-invoking the pipeline with modified config, returning early on the first reproduction.
    static func runRegressionSeeds<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>
    ) -> PreemptivePipelineContext<Backend>.PipelineResult? {
        guard context.config.coverageReplayRow == nil, context.config.seed == nil else { return nil }
        for encodedSeed in context.regressionSeeds {
            guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                context.deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                continue
            }

            var replayConfig = context.config
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
                backend: context.backend,
                config: replayConfig
            )
            context.deferredIssues.append(contentsOf: replayIssues)

            if let replayResult {
                finalizeReport(&context)
                return (replayResult, context.deferredIssues, context.report)
            } else if context.config.suppressIssueReporting == false {
                context.deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
            }
        }
        return nil
    }

    /// Runs the smoke test (seed 0, one iteration) and returns an early-exit result on failure.
    static func runSmokeTest<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>
    ) -> PreemptivePipelineContext<Backend>.PipelineResult? {
        typealias Spec = Backend.Spec
        do {
            let smokeGen = Gen.arrayOf(
                context.commandGen,
                within: 1 ... UInt64(context.commandLimit),
                scaling: .constant
            )
            var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, seed: 0, maxRuns: 1)
            if let (commands, _) = try smokeIterator.next() {
                let smoke = context.backend.runSmoke(commands)
                if smoke.failed {
                    let result = ContractResult<Spec>(
                        commands: commands,
                        originalCommands: nil,
                        trace: smoke.trace,
                        systemUnderTest: smoke.systemUnderTest,
                        seed: nil,
                        replaySeed: ReplaySeed.Resolved.sampling(seed: 0, iteration: 1).encoded,
                        discoveryMethod: .smokeTest
                    )
                    if context.config.suppressIssueReporting == false {
                        let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                        let message = renderFailure(result, failureInfo: failureInfo, failureDescription: smoke.failureDescription)
                        context.deferredIssues.append(message)
                    }
                    context.report.replaySeed = result.replaySeed
                    context.report.setInvocations(coverage: 0, randomSampling: 1, reduction: 0)
                    finalizeReport(&context)
                    return (result, context.deferredIssues, context.report)
                }
            }
        } catch {
            context.deferredIssues.append("Generator failed during smoke test: \(error)")
        }
        return nil
    }

    /// Runs the SCA coverage row loop and reduces the first failure found, if any.
    static func runCoveragePhase<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>,
        property: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Bool,
        linearizableProbe: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)], ChoiceTree) -> (Bool, ResponseWitness?, String?, FailureEvidence<Backend.Spec>?)
    ) -> PreemptivePipelineContext<Backend>.PipelineResult? {
        guard context.config.shouldRunCoverage else { return nil }
        let effectiveCoverageBudget: UInt64 = if let row = context.config.coverageReplayRow {
            max(context.coverageBudget, UInt64(row) + 1)
        } else {
            context.coverageBudget
        }
        let taggedCommandGen = context.taggedCommandGen
        let scaRowResult = runSCACoverageRowLoop(
            sequenceGen: context.sequenceGen,
            commandGen: context.commandGen,
            commandLimit: context.commandLimit,
            coverageBudget: effectiveCoverageBudget,
            skipToRow: context.config.coverageReplayRow,
            logEventPrefix: "concurrent_sca_coverage",
            concurrencyLevel: context.config.concurrencyLevel,
            sequenceGenForLength: { range in
                Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant)
            },
            property: property
        )
        guard case let .failure(taggedCommands, tree, coverageIterations) = scaRowResult else {
            return nil
        }
        let reduction = reduceConfirmedFailure(
            &context,
            taggedCommands: taggedCommands,
            tree: tree,
            pruneSeed: UInt64(coverageIterations),
            discoveryIterations: coverageIterations,
            property: property,
            linearizableProbe: linearizableProbe
        )
        return assembleReducedFailure(
            &context,
            reduction: reduction,
            originalCommands: taggedCommands.map(\.1),
            discoveryMethod: .coverage,
            seed: nil,
            iteration: coverageIterations,
            budget: context.coverageBudget,
            sequencesTested: context.invocationCounter.value,
            originalCount: taggedCommands.count,
            replaySeed: ReplaySeed.Resolved.encodeCoverageIteration(coverageIterations),
            coverageInvocations: context.invocationCounter.value,
            randomSamplingInvocations: 0
        )
    }

    /// Runs the random sampling loop, short-circuiting on timeout (no reduction) or reducing the first confirmed failure.
    static func runSamplingPhase<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>,
        property: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Bool,
        linearizableProbe: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)], ChoiceTree) -> (Bool, ResponseWitness?, String?, FailureEvidence<Backend.Spec>?)
    ) -> PreemptivePipelineContext<Backend>.PipelineResult? {
        guard context.config.coverageReplayRow == nil else { return nil }
        let (startIndex, maxRuns) = samplingReplayWindow(
            replayIteration: context.config.replayIteration,
            samplingBudget: context.samplingBudget
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            context.sequenceGen,
            materializePicks: false,
            seed: context.config.seed,
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

                if context.lastRunTimedOut.value {
                    let discoveryMethod: ContractDiscoveryMethod = context.config.replayIteration != nil
                        ? .replay
                        : .randomSampling
                    let samplingReplaySeed = ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded
                    let reportedInput: [(ScheduleMarker, Backend.Spec.Command)] = taggedCommands.filter(\.0.isPrefix) + taggedCommands.filter { $0.0.isPrefix == false }
                    let (result, failureDescription) = context.backend.buildResult(
                        reduced: reportedInput,
                        originalCommands: nil,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )
                    context.report.setInvocations(coverage: context.coverageInvocations, randomSampling: samplingIteration, reduction: 0)
                    if context.config.suppressIssueReporting == false {
                        context.failureContext.discoveryMethod = discoveryMethod
                        context.failureContext.seed = actualSeed
                        context.failureContext.iteration = absoluteIteration
                        context.failureContext.budget = context.samplingBudget
                        context.failureContext.sequencesTested = context.coverageInvocations + samplingIteration
                        context.failureContext.originalCount = taggedCommands.count
                        context.failureContext.replaySeed = samplingReplaySeed
                        context.failureContext.timedOut = true
                        context.failureContext.oracleDescription = failureDescription.map { "Expected state (from sequential replay):\n  \($0)" }
                        context.deferredIssues.append(renderFailureMessage(reportedInput, context: context.failureContext))
                    }
                    finalizeReport(&context)
                    return (result, context.deferredIssues, context.report)
                }

                let reduction = reduceConfirmedFailure(
                    &context,
                    taggedCommands: taggedCommands,
                    tree: tree,
                    pruneSeed: UInt64(absoluteIteration),
                    discoveryIterations: context.coverageInvocations + samplingIteration,
                    property: property,
                    linearizableProbe: linearizableProbe
                )
                let discoveryMethod: ContractDiscoveryMethod = context.config.replayIteration != nil ? .replay : .randomSampling
                return assembleReducedFailure(
                    &context,
                    reduction: reduction,
                    originalCommands: taggedCommands.map(\.1),
                    discoveryMethod: discoveryMethod,
                    seed: actualSeed,
                    iteration: absoluteIteration,
                    budget: context.samplingBudget,
                    sequencesTested: context.coverageInvocations + samplingIteration,
                    originalCount: taggedCommands.count,
                    replaySeed: ReplaySeed.Resolved.sampling(seed: actualSeed, iteration: absoluteIteration).encoded,
                    coverageInvocations: context.coverageInvocations,
                    randomSamplingInvocations: samplingIteration
                )
            }
        } catch {
            context.deferredIssues.append("Generator failed during sampling: \(error)")
        }
        return nil
    }
}

// MARK: - Helpers

private extension __ExhaustRuntime {
    /// Determines whether a failing outcome represents a confirmed linearizability violation. Returns `nil` when the execution passed or when linearizability holds despite the oracle flag.
    static func classifyFailure<Backend: PreemptiveBackend>(
        taggedCommands: [(ScheduleMarker, Backend.Spec.Command)],
        outcome: Preemptive.Outcome<Backend.Spec>,
        backend: Backend
    ) -> FailureEvidence<Backend.Spec>? {
        if outcome.passed {
            return nil
        }
        guard let laneResponses = outcome.laneResponses,
              let concurrentSpec = outcome.concurrentSpec
        else {
            return .init(outcome: outcome, witness: nil, failureDescription: nil)
        }
        guard case let .notLinearizable(witness, failure) = backend.checkLinearizability(
            taggedCommands: taggedCommands,
            laneResponses: laneResponses,
            concurrentSpec: concurrentSpec
        ) else {
            return nil
        }
        return .init(outcome: outcome, witness: witness, failureDescription: failure)
    }

    /// Extracts per-lane response display values from an outcome for trace annotation.
    static func laneResponseValues(
        from outcome: Preemptive.Outcome<some ContractSpecBase>?
    ) -> [UInt8: [String?]]? {
        guard let outcome, let typedResponses = outcome.laneResponses else { return nil }
        var values: [UInt8: [String?]] = [:]
        for laneArray in typedResponses {
            for response in laneArray {
                values[response.lane, default: []].append(response.outcome.displayValue)
            }
        }
        return values
    }

    /// Builds the oracle-based property closure, closing over the shared invocation counter and timeout flag.
    static func makeProperty<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>
    ) -> @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Bool {
        let backend = context.backend
        let invocationCounter = context.invocationCounter
        let lastRunTimedOut = context.lastRunTimedOut
        return { taggedCommands in
            invocationCounter.value += 1
            let outcome = backend.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            guard classifyFailure(
                taggedCommands: taggedCommands,
                outcome: outcome,
                backend: backend
            ) == nil else {
                return false
            }
            return true
        }
    }

    /// Builds the linearizability probe closure used during structural reduction.
    static func makeLinearizableProbe<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>
    ) -> @Sendable ([(ScheduleMarker, Backend.Spec.Command)], ChoiceTree) -> (Bool, ResponseWitness?, String?, FailureEvidence<Backend.Spec>?) {
        let backend = context.backend
        return { probeCommands, _ in
            guard let failure = classifyFailure(
                taggedCommands: probeCommands,
                outcome: backend.execute(probeCommands),
                backend: backend
            ) else {
                return (true, nil, nil, nil)
            }
            return (false, failure.witness, failure.failureDescription, failure)
        }
    }

    /// Re-executes the reduced input to confirm the race is reproducible, since prior reduction probes may not have triggered it.
    static func confirmRealFailure<Backend: PreemptiveBackend>(
        _ context: borrowing PreemptivePipelineContext<Backend>,
        input: [(ScheduleMarker, Backend.Spec.Command)],
        discoveryIterations: Int
    ) -> FailureEvidence<Backend.Spec>? {
        for _ in 0 ..< PreemptiveReduction.finalConfirmationRepetitions(discoveryIterations: discoveryIterations) {
            if let confirmed = classifyFailure(
                taggedCommands: input,
                outcome: context.backend.execute(input),
                backend: context.backend
            ) {
                return confirmed
            }
        }
        return nil
    }

    static func finalizeReport(
        _ context: inout PreemptivePipelineContext<some PreemptiveBackend>
    ) {
        context.report.totalMilliseconds = context.runStopwatch.elapsedMilliseconds
    }

    static func renderFailureMessage(
        _ input: [(ScheduleMarker, some CustomStringConvertible)],
        context: FailureContext
    ) -> String {
        let trace = buildPreemptiveTrace(
            input,
            laneResponseValues: context.laneResponseValues,
            linearizabilityWitness: context.linearizabilityWitness
        )
        return renderFailure(input, trace: trace, context: context)
    }

    /// Reduces a confirmed failure in two passes: lane collapse (moving concurrent commands to the prefix) followed by deletion and value search on the tighter schedule. Falls back to ``confirmRealFailure(_:input:discoveryIterations:)`` when neither pass cached a failing outcome.
    static func reduceConfirmedFailure<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>,
        taggedCommands: [(ScheduleMarker, Backend.Spec.Command)],
        tree: ChoiceTree,
        pruneSeed: UInt64,
        discoveryIterations: Int,
        property: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Bool,
        linearizableProbe: @escaping @Sendable ([(ScheduleMarker, Backend.Spec.Command)], ChoiceTree) -> (Bool, ResponseWitness?, String?, FailureEvidence<Backend.Spec>?)
    ) -> ReducedFailure<Backend.Spec> {
        let repetitions = PreemptiveReduction.confirmationRepetitions(discoveryIterations: discoveryIterations)
        let (prunedCommands, prunedTree) = pruneSkippedCommands(
            value: taggedCommands,
            tree: tree,
            generator: context.sequenceGen,
            seed: pruneSeed,
            property: property,
            identifySkips: context.identifySkips,
            logEvent: "preemptive_skip_pruning"
        )

        // Pass 1: lane collapse. Moves concurrent commands into the sequential prefix, reducing the number of lanes and the interleaving space before the checker-heavy deletion pass.
        let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
        let collapseResult = PreemptiveReduction.reduceSinglePass(
            generator: context.sequenceGen,
            tree: prunedTree,
            output: prunedCommands,
            encoders: [.laneCollapse],
            maxStalls: 2,
            deadlineNanoseconds: 7_500_000_000,
            rematerialize: true,
            repetitions: repetitions,
            tuning: noRelax,
            execute: linearizableProbe
        )

        // Pass 2: deletion and value reduction on the collapsed schedule. The tighter interleaving space (fewer concurrent commands) makes each linearizability check cheaper.
        let combinedResult = PreemptiveReduction.reduceSinglePass(
            generator: context.sequenceGen,
            tree: collapseResult.tree,
            output: collapseResult.output,
            encoders: [.deletion, .valueSearch, .floatSearch],
            maxStalls: 2,
            deadlineNanoseconds: 7_500_000_000,
            rematerialize: true,
            repetitions: repetitions,
            tuning: noRelax,
            execute: linearizableProbe
        )
        var stats = collapseResult.stats
        stats.merge(combinedResult.stats)
        context.report.applyReductionStats(stats)

        let reduced = combinedResult.output.sorted { $0.0.isPrefix && $1.0.isPrefix == false }
        let totalInvocations = combinedResult.propertyInvocations + collapseResult.propertyInvocations

        // Evidence priority: (1) reduction cache from the deletion pass, (2) reduction cache from the lane collapse pass, (3) confirmRealFailure re-execution as last resort when no reduction probe reproduced the race.
        let cached = combinedResult.failureOutcome ?? collapseResult.failureOutcome
        if let cached {
            return .init(
                reduced: reduced,
                reductionInvocations: totalInvocations,
                witness: combinedResult.witness ?? collapseResult.witness,
                reportedOutcome: cached.outcome,
                failureDescription: combinedResult.failureDescription ?? collapseResult.failureDescription
            )
        }
        let confirmed = confirmRealFailure(context, input: reduced, discoveryIterations: discoveryIterations)
        return .init(
            reduced: reduced,
            reductionInvocations: totalInvocations,
            witness: confirmed?.witness,
            reportedOutcome: confirmed?.outcome,
            failureDescription: confirmed?.failureDescription
        )
    }

    /// Populates the failure context with reduction evidence and renders the failure message for deferred issue reporting.
    static func assembleReducedFailure<Backend: PreemptiveBackend>(
        _ context: inout PreemptivePipelineContext<Backend>,
        reduction: ReducedFailure<Backend.Spec>,
        originalCommands: [Backend.Spec.Command],
        discoveryMethod: ContractDiscoveryMethod,
        seed: UInt64?,
        iteration: Int,
        budget: UInt64,
        sequencesTested: Int,
        originalCount: Int,
        replaySeed: String,
        coverageInvocations: Int,
        randomSamplingInvocations: Int
    ) -> PreemptivePipelineContext<Backend>.PipelineResult {
        let (result, failureDescription) = context.backend.buildResult(
            reduced: reduction.reduced,
            originalCommands: originalCommands,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
        context.report.setInvocations(
            coverage: coverageInvocations,
            randomSampling: randomSamplingInvocations,
            reduction: reduction.reductionInvocations
        )
        if context.config.suppressIssueReporting == false {
            context.failureContext.discoveryMethod = discoveryMethod
            context.failureContext.seed = seed
            context.failureContext.iteration = iteration
            context.failureContext.budget = budget
            context.failureContext.sequencesTested = sequencesTested
            context.failureContext.reductionInvocations = reduction.reductionInvocations
            context.failureContext.originalCount = originalCount
            context.failureContext.replaySeed = replaySeed
            context.failureContext.oracleDescription = failureDescription.map { "Expected state (from sequential replay):\n  \($0)" }
            context.failureContext.failureDescription = (reduction.failureDescription ?? reduction.reportedOutcome?.concurrentSpec?.failureDescription()).map { "Actual state (from concurrent execution):\n  \($0)" }
            context.failureContext.laneResponseValues = laneResponseValues(from: reduction.reportedOutcome)
            context.failureContext.linearizabilityWitness = reduction.witness
            context.deferredIssues.append(renderFailureMessage(reduction.reduced, context: context.failureContext))
        }
        finalizeReport(&context)
        return (result, context.deferredIssues, context.report)
    }
}

// MARK: - Supporting Types

/// Accumulates configuration, report state, and deferred issues across the preemptive pipeline phases.
///
/// Phase functions on ``__ExhaustRuntime`` take this as `inout` and return an optional early-exit result; `nil` means "continue to the next phase."
private struct PreemptivePipelineContext<Backend: PreemptiveBackend>: ~Copyable {
    typealias Spec = Backend.Spec
    typealias PipelineResult = (result: ContractResult<Spec>?, deferredIssues: [String], report: ExhaustReport)

    let backend: Backend
    let config: ResolvedConcurrentConfig
    let regressionSeeds: [String]
    let sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let taggedCommandGen: Generator<(ScheduleMarker, Spec.Command)>
    let commandGen: Generator<Spec.Command>
    let commandLimit: Int
    let samplingBudget: UInt64
    let coverageBudget: UInt64
    let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>
    let runStopwatch: Stopwatch
    let invocationCounter: UnsafeSendableBox<Int>
    let lastRunTimedOut: UnsafeSendableBox<Bool>

    var report: ExhaustReport
    var deferredIssues: [String]
    var coverageInvocations: Int = 0
    var failureContext: __ExhaustRuntime.FailureContext
}

extension __ExhaustRuntime {
    /// Captures the outcome, response-level witness, and failure description from a single failing execution.
    struct FailureEvidence<Spec: ContractSpecBase> {
        let outcome: Preemptive.Outcome<Spec>
        let witness: ResponseWitness?
        let failureDescription: String?
    }

    /// Holds the reduced command sequence and associated evidence after reduction.
    struct ReducedFailure<Spec: ContractSpecBase> {
        let reduced: [(ScheduleMarker, Spec.Command)]
        let reductionInvocations: Int
        let witness: ResponseWitness?
        let reportedOutcome: Preemptive.Outcome<Spec>?
        let failureDescription: String?
    }
}
