import ExhaustCore

// MARK: - Contract Machine

/// Pulls candidates from prioritized sources, dispatches to a ``ContractBackend`` for probing, and reduces the first failure found.
///
/// Modeled after ``ReductionMachine``'s stepped architecture. Each call to ``next()`` advances one phase and returns a ``Transition`` describing what happened. The caller iterates until `nil`:
///
/// ```swift
/// var machine = ContractMachine(...)
/// while let transition = machine.next() {
///     // handle transition
/// }
/// ```
struct ContractMachine<Backend: ContractBackend> {
    let backend: Backend
    let context: ContractRunContext<Backend.Spec>
    var sources: [AnyContractCandidateSource<Backend.Spec.Command>]

    // MARK: - State

    var phase: Phase = .pullSource
    var sourceIndex: Int = 0
    let coverageStopwatch = Stopwatch()
    var coverageTimingRecorded = false

    var candidate: ContractCandidate<Backend.Spec.Command>?
    var pruned: (value: [(ScheduleMarker, Backend.Spec.Command)], tree: ChoiceTree)?
    var reduction: ContractReduction<Backend.Spec.Command>?
    var preReductionInvocations: Int = 0
    var reductionStopwatch: Stopwatch?
    var result: ContractResult<Backend.Spec>?

    // MARK: - Step

    mutating func next() -> Transition? {
        switch phase {
            case .pullSource:
                return stepPullSource()
            case .accountCandidate:
                return stepAccountCandidate()
            case .checkTimeout:
                return stepCheckTimeout()
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

    // MARK: - Convenience

    mutating func run() -> ContractResult<Backend.Spec>? {
        while next() != nil {}
        return result
    }

    // MARK: - Pull Source

    private mutating func stepPullSource() -> Transition {
        guard sourceIndex < sources.count else {
            phase = .finalize
            return stepFinalize() ?? .sourceExhausted
        }

        do {
            guard let found = try sources[sourceIndex].next() else {
                sourceIndex += 1
                return .sourceExhausted
            }
            candidate = found
            phase = .accountCandidate
            return .candidateFound(
                discoveryMethod: found.discoveryMethod,
                commandCount: found.taggedCommands.count
            )
        } catch {
            let message: String
            if let resolved = sources[sourceIndex].resolvedReplaySeed {
                message = "Generator failed during regression replay (seed \(resolved.encoded)): \(error)"
            } else {
                message = "Generator failed: \(error)"
            }
            context.deferredIssues.append(message)
            sourceIndex += 1
            return .sourceError(message)
        }
    }

    // MARK: - Account Candidate

    private mutating func stepAccountCandidate() -> Transition {
        guard let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }

        switch candidate.discoveryMethod {
            case .coverage, .replay:
                context.report.coverageInvocations += candidate.sourceInvocations
            case .randomSampling:
                if coverageTimingRecorded == false {
                    context.report.coverageMilliseconds = coverageStopwatch.elapsedMilliseconds
                    coverageTimingRecorded = true
                }
                context.report.randomSamplingInvocations += candidate.sourceInvocations
            case .smokeTest:
                context.report.coverageInvocations += candidate.sourceInvocations
        }
        context.report.propertyInvocations += candidate.sourceInvocations

        context.failureContext.timedOut = context.lastRunTimedOut
        context.failureContext.seed = candidate.discoveryMethod == .coverage ? nil : candidate.seed
        context.failureContext.originalCount = candidate.taggedCommands.count
        context.failureContext.iteration = candidate.iteration
        context.failureContext.budget = context.config.budget.samplingBudget
        context.failureContext.sequencesTested = candidate.sourceInvocations

        phase = .checkTimeout
        return .candidateFound(
            discoveryMethod: candidate.discoveryMethod,
            commandCount: candidate.taggedCommands.count
        )
    }

    // MARK: - Check Timeout

    private mutating func stepCheckTimeout() -> Transition {
        guard let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }

        guard context.lastRunTimedOut == false else {
            let (built, issueMessage) = backend.buildResult(
                reduced: candidate.taggedCommands,
                originalCommands: nil,
                seed: candidate.seed,
                iteration: candidate.iteration,
                discoveryMethod: candidate.discoveryMethod,
                context: context
            )
            if issueMessage.isEmpty == false {
                context.deferredIssues.append(issueMessage)
            }
            result = built
            phase = .finalize
            return .timedOut
        }

        phase = .prune
        return .timedOut
    }

    // MARK: - Prune

    private mutating func stepPrune() -> Transition {
        guard let candidate else {
            phase = .pullSource
            return .sourceExhausted
        }

        nonisolated(unsafe) let unsafeBackend = backend
        nonisolated(unsafe) let unsafeContext = context
        pruned = __ExhaustRuntime.pruneSkippedCommands(
            value: candidate.taggedCommands,
            tree: candidate.tree,
            generator: context.sequenceGen,
            seed: candidate.seed,
            property: { commands in
                unsafeBackend.probe(commands, context: unsafeContext) == .pass
            },
            identifySkips: context.identifySkips,
            logEvent: "contract_skip_pruning"
        )

        phase = .reduce
        return .pruned
    }

    // MARK: - Reduce

    private mutating func stepReduce() -> Transition {
        guard let pruned else {
            phase = .pullSource
            return .sourceExhausted
        }

        preReductionInvocations = context.invocationCounter.value
        reductionStopwatch = Stopwatch()
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
        context.report.reductionMilliseconds = reductionStopwatch?.elapsedMilliseconds ?? 0
        context.report.reductionInvocations = reductionInvocations
        context.report.propertyInvocations += reductionInvocations
        context.failureContext.reductionInvocations = reductionInvocations
        if let stats = reduction?.stats {
            context.report.applyReductionStats(stats)
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
            context.deferredIssues.append(issueMessage)
        }

        result = built
        phase = .finalize
        return .assembled(built)
    }

    // MARK: - Finalize

    @discardableResult
    private mutating func stepFinalize() -> Transition? {
        if coverageTimingRecorded == false {
            context.report.coverageMilliseconds = coverageStopwatch.elapsedMilliseconds
        }
        if let onReport = context.config.onReportClosure {
            context.report.seed = context.config.seed
            context.report.totalMilliseconds = context.runStopwatch.elapsedMilliseconds
            onReport(context.report)
        }
        phase = .done
        return nil
    }
}

// MARK: - Phase

extension ContractMachine {
    enum Phase {
        case pullSource
        case accountCandidate
        case checkTimeout
        case prune
        case reduce
        case recordStats
        case assemble
        case finalize
        case done
    }
}

// MARK: - Transition

extension ContractMachine {
    enum Transition {
        case sourceExhausted
        case sourceError(String)
        case candidateFound(discoveryMethod: ContractDiscoveryMethod, commandCount: Int)
        case timedOut
        case pruned
        case reduced
        case statsRecorded
        case assembled(ContractResult<Backend.Spec>)
    }
}
