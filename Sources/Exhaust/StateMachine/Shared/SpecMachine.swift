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
    var sources: [AnyStateMachineCandidateSource<Backend.Spec.Command>]

    // MARK: - State

    var phase: Phase = .pullSource
    var sourceIndex: Int = 0
    var discoveryInvocations: Int = 0
    var reportedSeed: UInt64?

    var candidate: StateMachineCandidate<Backend.Spec.Command>?
    var pruned: (value: [(ScheduleMarker, Backend.Spec.Command)], tree: ChoiceTree)?
    var reduction: StateMachineReduction<Backend.Spec.Command>?
    var preReductionInvocations: Int = 0
    var reductionStopwatch: Stopwatch?
    var result: StateMachineResult<Backend.Spec>?

    // MARK: - Step

    mutating func next() -> Transition? {
        switch phase {
            case .pullSource:
                return stepPullSource()
            case .prune:
                return stepPrune()
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
            accountSource(source, invocations: context.invocationCounter.value - invocationsBefore, elapsed: stopwatch.elapsedMilliseconds)
            guard let found else {
                sourceIndex += 1
                return .sourceExhausted
            }
            candidate = found
            accountCandidate(found)
            phase = .prune
            return .candidateFound(
                discoveryMethod: found.discoveryMethod,
                commandCount: found.taggedCommands.count
            )
        } catch {
            accountSource(source, invocations: context.invocationCounter.value - invocationsBefore, elapsed: stopwatch.elapsedMilliseconds)
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
        _ source: AnyStateMachineCandidateSource<Backend.Spec.Command>,
        invocations: Int,
        elapsed: Double
    ) {
        switch source.discoveryMethod {
            case .screening:
                context.state.report.screeningInvocations += invocations
                context.state.report.screeningMilliseconds += elapsed
            case .randomSampling, .smokeTest, .replay:
                context.state.report.randomSamplingInvocations += invocations
        }
        context.state.report.propertyInvocations += invocations
        discoveryInvocations += invocations
        if let seed = source.reportedSeed {
            reportedSeed = seed
        }
    }

    private mutating func accountCandidate(_ candidate: StateMachineCandidate<Backend.Spec.Command>) {
        context.state.failureContext.seed = candidate.discoveryMethod == .screening ? nil : candidate.seed
        context.state.failureContext.originalCount = candidate.taggedCommands.count
        context.state.failureContext.iteration = candidate.iteration
        context.state.failureContext.budget = candidate.discoveryMethod == .screening
            ? context.config.budget.screeningBudget
            : context.config.budget.samplingBudget
        context.state.failureContext.sequencesTested = discoveryInvocations
    }

    // MARK: - Prune

    /// Removes skipped commands from the candidate before reduction.
    private mutating func stepPrune() -> Transition {
        guard let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }

        // Prune and reduce against the generator that produced this candidate so the choice sequence matches its tree. Smoke supplies a concurrency-1 generator, so smoke failures reduce sequentially regardless of the run's lane count.
        context.state.sequenceGen = candidate.sequenceGen
        preReductionInvocations = context.invocationCounter.value
        reductionStopwatch = Stopwatch()

        nonisolated(unsafe) let unsafeBackend = backend
        nonisolated(unsafe) let capturedContext = context
        let pruneResult = __ExhaustRuntime.pruneSkippedCommands(
            value: candidate.taggedCommands,
            tree: candidate.tree,
            generator: context.state.sequenceGen,
            seed: candidate.seed,
            property: { commands in
                unsafeBackend.countedProbe(commands, context: capturedContext) != .fail
            },
            identifySkips: context.identifySkips,
            logEvent: "statemachine_skip_pruning"
        )
        pruned = (value: pruneResult.value, tree: pruneResult.tree)

        phase = .reduce
        return .pruned
    }

    // MARK: - Reduce

    private mutating func stepReduce() -> Transition {
        guard let pruned else {
            phase = .pullSource
            return .sourceExhausted
        }

        reduction = backend.reduce(
            taggedCommands: pruned.value,
            tree: pruned.tree,
            context: context
        )

        phase = .recordStats
        return .reduced
    }

    // MARK: - Record Stats

    private mutating func stepRecordStats() -> Transition {
        let reductionInvocations = context.invocationCounter.value - preReductionInvocations
        context.state.report.reductionMilliseconds = reductionStopwatch?.elapsedMilliseconds ?? 0
        context.state.report.reductionInvocations = reductionInvocations
        context.state.report.propertyInvocations += reductionInvocations
        context.state.failureContext.reductionInvocations = reductionInvocations
        if let stats = reduction?.stats {
            context.state.report.applyReductionStats(stats)
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

        let originalCommands = candidate.taggedCommands.map(\.1)
        let (built, issueMessage) = backend.buildResult(
            reduced: reduction.finalInput,
            originalCommands: originalCommands,
            seed: candidate.seed,
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
    let identifySkips: @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Set<Int>
    let property: @Sendable ([(ScheduleMarker, Backend.Spec.Command)]) -> Bool
    let invocationCounter: UnsafeSendableBox<Int>
    let sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Backend.Spec.Command)]>)?
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    func run(
        config: ResolvedConcurrentConfig,
        smokeSource: AnyStateMachineCandidateSource<Backend.Spec.Command>? = nil
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
                case .sourceExhausted, .sourceError, .pruned, .reduced, .statsRecorded, .assembled:
                    break
            }
        }
        return (machine.result, runContext.state.deferredIssues)
    }

    func runWithRegressions(
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        mainRunSmokeSource: AnyStateMachineCandidateSource<Backend.Spec.Command>? = nil
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
