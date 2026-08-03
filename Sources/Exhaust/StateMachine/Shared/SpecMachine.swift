import ExhaustCore

// MARK: - StateMachine Machine

/// Pulls candidates from prioritized sources, dispatches to a ``StateMachineBackend`` for probing, and reduces the first failure found.
///
/// Modeled after ``ReductionMachine``'s stepped architecture. Each call to ``next()`` advances one phase and returns a ``Transition`` describing what happened. The caller iterates until `nil`:
/// ```swift
/// var machine = SpecMachine(...)
/// while let transition = machine.next() {
///     // handle transition
/// }
/// ```
struct SpecMachine<Backend: StateMachineBackend> {
    let backend: Backend
    let context: StateMachineRunContext<Backend.Spec>
    var sources: [AnyStateMachineCandidateSource<Backend.Spec>]

    // MARK: - State

    var phase: Phase = .pullSource
    var sourceIndex: Int = 0
    var discoveryInvocations: Int = 0
    var reportedSeed: UInt64?

    var candidate: StateMachineCandidate<Backend.Spec>?
    /// The setup step as reduction left it. Seeded from the candidate and replaced by the setup pass, so it outlives ``reductionInput`` and is what the assembled result reports.
    var reducedSetupStep: Backend.Spec.SetupStep?
    /// The decomposed halves the reduction passes edit, or nil when the candidate tree could not be decomposed. Each pass reads it and writes it back; nothing reads `candidate.tree` after ``stepPrune()``.
    var reductionInput: ReductionInput?
    var setupReductionStats: ReductionStats?
    var reduction: StateMachineReduction<Backend.Spec.Command>?
    var preReductionInvocations: Int = 0
    var reductionStopwatch: Stopwatch?
    var result: StateMachineResult<Backend.Spec>?

    /// The candidate decomposed into its setup and command children, which reduction is free to edit.
    ///
    /// `setupTree` is nil for zero-setup specs, whose candidate tree IS the command tree. The whole value is nil when a with-setup candidate tree does not have the expected zip-group root: reducing such a tree would let structural encoders reach the setup subtree, so ``stepPrune()`` reports the candidate unreduced instead and the reduction passes never run.
    struct ReductionInput {
        var setupTree: ChoiceTree?
        var taggedCommands: [(ScheduleMarker, Backend.Spec.Command)]
        var commandTree: ChoiceTree
    }

    // MARK: - Step

    mutating func next() -> Transition? {
        switch phase {
            case .pullSource:
                return stepPullSource()
            case .prune:
                return stepPrune()
            case .reduceSetup:
                return stepReduceSetup()
            case .reduce:
                return stepReduce()
            case .recordStats:
                return stepRecordStats()
            case .assemble:
                return stepAssemble()
            case .finalize:
                stepFinalize()
                return nil
            case .done:
                return nil
        }
    }

    // MARK: - Pull Source

    /// Advances to the next source, returning `.candidateFound` on the first failure or `.sourceExhausted` when all sources pass or error.
    private mutating func stepPullSource() -> Transition {
        guard sourceIndex < sources.count else {
            phase = .finalize
            return stepFinalize() ?? .sourceExhausted
        }

        let source = sources[sourceIndex]
        let invocationsBefore = context.invocationCounter.value
        let stopwatch = Stopwatch()
        do {
            let found = try source.next()
            accountSource(
                source,
                invocations: context.invocationCounter.value - invocationsBefore,
                elapsed: stopwatch.elapsedMilliseconds,
                foundFailure: found != nil
            )
            guard let found else {
                sourceIndex += 1
                return .sourceExhausted
            }
            candidate = found
            accountCandidate(found)
            phase = .prune
            return .candidateFound(
                discoveryMethod: found.discoveryMethod,
                commandCount: found.value.taggedCommands.count
            )
        } catch {
            accountSource(
                source,
                invocations: context.invocationCounter.value - invocationsBefore,
                elapsed: stopwatch.elapsedMilliseconds,
                foundFailure: false
            )
            let message = source.resolvedReplaySeed.map {
                "Generator failed during regression replay (seed \($0.encoded)): \(error)"
            } ?? "Generator failed: \(error)"
            context.state.deferredIssues.append(message)
            sourceIndex += 1
            return .sourceError(message)
        }
    }

    /// Attributes a source's discovery invocations and wall time to the matching report bucket. Runs for every source the machine advances through, so a phase that passes is still counted — not only the one that produces the failing candidate.
    private mutating func accountSource(
        _ source: AnyStateMachineCandidateSource<Backend.Spec>,
        invocations: Int,
        elapsed: Double,
        foundFailure: Bool
    ) {
        let phase: RunLedger.Phase
        switch source.discoveryMethod {
            case .screening:
                phase = .screening
                context.state.report.screeningMilliseconds += elapsed
            case .randomSampling, .smokeTest, .replay:
                phase = .sampling
        }
        // A found candidate is the one failing sequence in this source's batch. A source may surface a candidate without routing probes through the shared invocation counter (stub sources do), so the failure outcome is attributed only when the batch counted invocations. Skips are pruned downstream and never reach the counter, so they carry no ledger outcome here.
        let failureCount = foundFailure && invocations > 0 ? 1 : 0
        context.state.ledger.record(phase, invocations: invocations, failures: failureCount)
        discoveryInvocations += invocations
        if let seed = source.reportedSeed {
            reportedSeed = seed
        }
    }

    private mutating func accountCandidate(_ candidate: StateMachineCandidate<Backend.Spec>) {
        context.state.failureContext.seed = candidate.discoveryMethod == .screening ? nil : candidate.seed
        context.state.failureContext.originalCount = candidate.value.taggedCommands.count
        context.state.failureContext.iteration = candidate.iteration
        context.state.failureContext.budget = candidate.discoveryMethod == .screening
            ? context.config.budget.screeningBudget
            : context.config.budget.samplingBudget
        context.state.failureContext.sequencesTested = discoveryInvocations
    }

    // MARK: - Prune

    /// Decomposes the candidate into its setup and command children, then removes skipped commands from the command side before reduction.
    private mutating func stepPrune() -> Transition {
        guard let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }

        // Prune and reduce against the generator that produced this candidate's command child so the choice sequence matches its tree. Smoke supplies a concurrency-1 generator, so smoke failures reduce sequentially regardless of the run's lane count.
        context.state.sequenceGen = candidate.sequenceGen
        preReductionInvocations = context.invocationCounter.value
        reductionStopwatch = Stopwatch()

        let setupStep = candidate.value.setupStep
        reducedSetupStep = setupStep

        var setupTree: ChoiceTree?
        var commandTree = candidate.tree
        if setupStep != nil {
            guard let split = __ExhaustRuntime.splitCandidateTree(candidate.tree) else {
                ExhaustLog.error(
                    category: .reducer,
                    event: "statemachine_candidate_tree_shape_mismatch",
                    "Candidate tree root is not the expected setup/command group. Skipping pruning and reduction for this candidate."
                )
                // Report what discovery found rather than editing a tree whose halves cannot be told apart.
                reduction = StateMachineReduction(
                    finalInput: candidate.value.taggedCommands,
                    stats: nil,
                    timedOut: false
                )
                phase = .recordStats
                return .pruned
            }
            setupTree = split.setupTree
            commandTree = split.commandTree
        }

        let pruned = pruneCommands(
            setupStep: setupStep,
            taggedCommands: candidate.value.taggedCommands,
            commandTree: commandTree,
            seed: candidate.seed
        )

        reductionInput = ReductionInput(
            setupTree: setupTree,
            taggedCommands: pruned.value,
            commandTree: pruned.tree
        )

        phase = .reduceSetup
        return .pruned
    }

    /// Runs skip pruning on the command side, with the given setup spliced into every probe and skip-identification call.
    private func pruneCommands(
        setupStep: Backend.Spec.SetupStep?,
        taggedCommands: [(ScheduleMarker, Backend.Spec.Command)],
        commandTree: ChoiceTree,
        seed: UInt64
    ) -> (value: [(ScheduleMarker, Backend.Spec.Command)], tree: ChoiceTree) {
        nonisolated(unsafe) let unsafeBackend = backend
        nonisolated(unsafe) let capturedContext = context
        return __ExhaustRuntime.pruneSkippedCommands(
            value: taggedCommands,
            tree: commandTree,
            generator: context.state.sequenceGen,
            seed: seed,
            property: { commands in
                unsafeBackend.countedProbe(
                    SpecCandidateValue(setupStep: setupStep, taggedCommands: commands),
                    context: capturedContext
                ) != .fail
            },
            identifySkips: { commands in
                capturedContext.identifySkips(
                    SpecCandidateValue(setupStep: setupStep, taggedCommands: commands)
                )
            },
            logEvent: "statemachine_skip_pruning"
        )
    }

    // MARK: - Reduce Setup

    /// Pass 0: value-reduces the setup step against the fixed command sequence, then re-runs skip pruning because a shrunk setup changes which commands skip.
    ///
    /// The reduction runs over the extracted setup subtree with the spec's `setupGenerator`, so commands are unreachable by construction. Deletion is enabled deliberately: the setup step itself is the subtree's zip root, not a `.sequence` element, so deletion can only shorten sequence-valued setup arguments within their declared length ranges.
    private mutating func stepReduceSetup() -> Transition {
        guard var reductionInput, let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }
        guard let setupTree = reductionInput.setupTree,
              let setupGen = Backend.Spec.setupGenerator,
              let currentStep = reducedSetupStep
        else {
            phase = .reduce
            return .setupReduced
        }

        nonisolated(unsafe) let unsafeBackend = backend
        nonisolated(unsafe) let capturedContext = context
        let fixedCommands = reductionInput.taggedCommands
        let property: @Sendable (Backend.Spec.SetupStep) -> Bool = { step in
            unsafeBackend.countedProbe(
                SpecCandidateValue(setupStep: step, taggedCommands: fixedCommands),
                context: capturedContext
            ) != .fail
        }
        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: context.reductionDeadlineNanoseconds,
            enabledEncoders: [.valueSearch, .floatSearch, .deletion],
            tuning: SchedulerTuning(relaxMaterializationBudget: 0)
        )
        if let reduced = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: setupGen.gen,
            tree: setupTree,
            output: currentStep,
            config: config,
            property: property
        ) {
            setupReductionStats = reduced.stats
            if case let .reduced(_, reducedTree, reducedStep) = reduced.outcome {
                reducedSetupStep = reducedStep
                reductionInput.setupTree = reducedTree
                let repruned = pruneCommands(
                    setupStep: reducedStep,
                    taggedCommands: reductionInput.taggedCommands,
                    commandTree: reductionInput.commandTree,
                    seed: candidate.seed
                )
                reductionInput.taggedCommands = repruned.value
                reductionInput.commandTree = repruned.tree
            }
        }

        self.reductionInput = reductionInput
        phase = .reduce
        return .setupReduced
    }

    // MARK: - Reduce

    private mutating func stepReduce() -> Transition {
        guard let reductionInput else {
            phase = .pullSource
            return .sourceExhausted
        }

        reduction = backend.reduce(
            setupStep: reducedSetupStep,
            taggedCommands: reductionInput.taggedCommands,
            tree: reductionInput.commandTree,
            context: context
        )

        phase = .recordStats
        return .reduced
    }

    // MARK: - Record Stats

    private mutating func stepRecordStats() -> Transition {
        let reductionInvocations = context.invocationCounter.value - preReductionInvocations
        // The shared invocation counter hides per-probe verdicts, so only the reduction phase total is meaningful here (see ``RunLedger``).
        context.state.ledger.record(.reduction, invocations: reductionInvocations)
        let reductionElapsed = reductionStopwatch?.elapsedMilliseconds ?? 0
        context.state.report.reductionMilliseconds = reductionElapsed
        context.state.failureContext.reductionInvocations = reductionInvocations
        let collectedStats = [setupReductionStats, reduction?.stats].compactMap(\.self)
        if collectedStats.isEmpty == false {
            var mergedStats = ReductionStats()
            for stats in collectedStats {
                mergedStats.merge(stats)
            }
            context.state.report.applyReductionStats(mergedStats)
        }

        phase = .assemble
        return .statsRecorded
    }

    // MARK: - Assemble

    private mutating func stepAssemble() -> Transition {
        guard let candidate, let reduction else {
            phase = .pullSource
            return .sourceExhausted
        }

        // Set here rather than in any one backend so every backend's failure rendering sees the same setup descriptions.
        context.state.failureContext.setupDescription = reducedSetupStep.map { "\($0)" }

        let originalCommands = candidate.value.taggedCommands.map(\.1)
        let (built, issueMessage) = backend.buildResult(
            setupStep: reducedSetupStep,
            reduced: reduction.finalInput,
            originalCommands: originalCommands,
            seed: candidate.replayIdentitySeed,
            iteration: candidate.iteration,
            discoveryMethod: candidate.discoveryMethod,
            context: context
        )

        if issueMessage.isEmpty == false {
            context.state.deferredIssues.append(issueMessage)
        }

        result = built
        phase = .finalize
        return .assembled
    }

    // MARK: - Finalize

    @discardableResult
    private mutating func stepFinalize() -> Transition? {
        context.state.report.applyLedger(context.state.ledger)
        if let onReport = context.config.onReportClosure {
            context.state.report.seed = reportedSeed
            context.state.report.totalMilliseconds = context.state.runStopwatch.elapsedMilliseconds
            onReport(context.state.report)
        }
        phase = .done
        return nil
    }
}

// MARK: - Phase

extension SpecMachine {
    /// Tracks which pipeline step the machine will execute on the next call to ``next()``.
    enum Phase {
        case pullSource
        case prune
        case reduceSetup
        case reduce
        case recordStats
        case assemble
        case finalize
        case done
    }
}

// MARK: - Transition

extension SpecMachine {
    /// Describes what happened during a single ``next()`` step, returned to the caller for logging or diagnostics.
    enum Transition: Equatable {
        case sourceExhausted
        case sourceError(String)
        case candidateFound(discoveryMethod: StateMachineDiscoveryMethod, commandCount: Int)
        case pruned
        case setupReduced
        case reduced
        case statsRecorded
        case assembled
    }
}

// MARK: - Pipeline

/// Drives a ``SpecMachine`` through its phases, handling regression replay and the main run.
///
/// Each entry point (sequential, cooperative, preemptive) constructs a pipeline once and calls ``runWithRegressions(config:regressionSeeds:mainRunSmokeSource:)`` to run the full pipeline. The pipeline drives ``SpecMachine/next()`` directly rather than using a blind loop, so each transition is available for logging and diagnostics.
struct SpecPipeline<Backend: StateMachineBackend> {
    let backend: Backend
    let sequenceGen: Generator<[(ScheduleMarker, Backend.Spec.Command)]>
    let commandGen: Generator<Backend.Spec.Command>
    let commandLimit: Int
    let concurrencyLevel: Int
    let identifySkips: @Sendable (SpecCandidateValue<Backend.Spec>) -> Set<Int>
    let property: @Sendable (SpecCandidateValue<Backend.Spec>) -> Bool
    let invocationCounter: UnsafeSendableBox<Int>
    let sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Backend.Spec.Command)]>)?
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    func run(
        config: ResolvedConcurrentConfig,
        smokeSource: AnyStateMachineCandidateSource<Backend.Spec>? = nil
    ) -> (result: StateMachineResult<Backend.Spec>?, issues: [String]) {
        let runContext = StateMachineRunContext<Backend.Spec>(
            config: config,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            identifySkips: identifySkips,
            invocationCounter: invocationCounter,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        let sources = __ExhaustRuntime.buildStateMachineSources(
            config: config,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            concurrencyLevel: concurrencyLevel,
            property: property,
            smokeSource: smokeSource,
            sequenceGenForLength: sequenceGenForLength
        )
        var machine = SpecMachine(backend: backend, context: runContext, sources: sources)
        while let transition = machine.next() {
            switch transition {
                case let .candidateFound(discoveryMethod, commandCount):
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "statemachine_candidate_found",
                        metadata: ["method": "\(discoveryMethod)", "commands": "\(commandCount)"]
                    )
                case .sourceExhausted, .sourceError, .pruned, .setupReduced, .reduced, .statsRecorded, .assembled:
                    break
            }
        }
        return (machine.result, runContext.state.deferredIssues)
    }

    func runWithRegressions(
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        mainRunSmokeSource: AnyStateMachineCandidateSource<Backend.Spec>? = nil
    ) -> (result: StateMachineResult<Backend.Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        let (regressionResult, regressionIssues) = __ExhaustRuntime.replayRegressionSeeds(
            config: config,
            regressionSeeds: regressionSeeds,
            runMachine: { run(config: $0) }
        )
        deferredIssues.append(contentsOf: regressionIssues)
        if let regressionResult {
            return (regressionResult, deferredIssues)
        }

        let (result, issues) = run(config: config, smokeSource: mainRunSmokeSource)
        deferredIssues.append(contentsOf: issues)
        // A passing run that never executed a command sequence asserts nothing. Checked against the shared invocation counter so a regression replay that did execute counts.
        if result == nil, issues.isEmpty, invocationCounter.value == 0 {
            deferredIssues.append("The spec was never executed: the screening and sampling budgets are both zero, so this test asserts nothing.")
        }
        return (result, deferredIssues)
    }
}
