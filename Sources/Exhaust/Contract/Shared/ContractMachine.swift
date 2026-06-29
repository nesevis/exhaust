import ExhaustCore

/// Mutable state for a single contract test run.
///
/// Non-`Sendable` — the machine and context live on a single GCD thread. Concurrent backends
/// internally parallelize during ``ContractBackend/probe(_:context:)`` but return synchronously
/// before the context is mutated.
final class ContractRunContext<Spec: ContractSpecBase> {
    let config: ResolvedConcurrentConfig
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    let sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let commandGen: Generator<Spec.Command>
    let commandLimit: Int
    let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>
    let runStopwatch = Stopwatch()

    let invocationCounter: UnsafeSendableBox<Int>
    let lastRunTimedOutBox: UnsafeSendableBox<Bool>?
    var lastRunTimedOut: Bool {
        lastRunTimedOutBox?.value ?? false
    }

    var report = ExhaustReport()
    var deferredIssues: [String] = []
    var failureContext = __ExhaustRuntime.FailureContext()

    init(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>,
        invocationCounter: UnsafeSendableBox<Int> = UnsafeSendableBox(0),
        lastRunTimedOut: UnsafeSendableBox<Bool>? = nil,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        self.config = config
        self.sequenceGen = sequenceGen
        self.commandGen = commandGen
        self.commandLimit = commandLimit
        self.identifySkips = identifySkips
        self.invocationCounter = invocationCounter
        lastRunTimedOutBox = lastRunTimedOut
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    var reductionConfig: Interpreters.ReducerConfiguration {
        Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: config.budget.samplingBudget * 5 * 1_000_000,
            tuning: SchedulerTuning(relaxMaterializationBudget: 0)
        )
    }
}

/// Pulls candidates from prioritized sources, dispatches to a ``ContractBackend`` for probing, and reduces the first failure found. A single linear pass through sources rather than a multi-cycle convergence loop, modeled after ``ReductionMachine``'s source-dispatch architecture.
struct ContractMachine<Backend: ContractBackend> {
    let backend: Backend
    let context: ContractRunContext<Backend.Spec>
    var sources: [AnyContractCandidateSource<Backend.Spec.Command>]

    /// Returns the first failing ``ContractResult``, or `nil` when all sources exhaust without finding a failure.
    func run() -> ContractResult<Backend.Spec>? {
        let coverageStopwatch = Stopwatch()
        var coverageTimingRecorded = false

        defer {
            if coverageTimingRecorded == false {
                context.report.coverageMilliseconds = coverageStopwatch.elapsedMilliseconds
            }
            if let onReport = context.config.onReportClosure {
                context.report.seed = context.config.seed
                context.report.totalMilliseconds = context.runStopwatch.elapsedMilliseconds
                onReport(context.report)
            }
        }

        for sourceIndex in sources.indices {
            let candidate: ContractCandidate<Backend.Spec.Command>
            do {
                guard let found = try sources[sourceIndex].next() else {
                    continue
                }
                candidate = found
            } catch {
                if let resolved = sources[sourceIndex].resolvedReplaySeed {
                    context.deferredIssues.append("Generator failed during regression replay (seed \(resolved.encoded)): \(error)")
                } else {
                    context.deferredIssues.append("Generator failed: \(error)")
                }
                continue
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

            guard context.lastRunTimedOut == false else {
                let (result, issueMessage) = backend.buildResult(
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
                return result
            }

            nonisolated(unsafe) let unsafeBackend = backend
            nonisolated(unsafe) let unsafeContext = context
            let pruned = __ExhaustRuntime.pruneSkippedCommands(
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

            let preReductionInvocations = context.invocationCounter.value
            let reductionStopwatch = Stopwatch()
            let reduction = backend.reduce(
                taggedCommands: pruned.value,
                tree: pruned.tree,
                context: context
            )
            let reductionInvocations = context.invocationCounter.value - preReductionInvocations
            context.report.reductionMilliseconds = reductionStopwatch.elapsedMilliseconds
            context.report.reductionInvocations = reductionInvocations
            context.report.propertyInvocations += reductionInvocations
            context.failureContext.reductionInvocations = reductionInvocations
            if let stats = reduction.stats {
                context.report.applyReductionStats(stats)
            }

            let originalCommands = candidate.taggedCommands.map(\.1)
            let (result, issueMessage) = backend.buildResult(
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

            return result
        }
        return nil
    }
}
