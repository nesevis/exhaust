// Concurrent SCA coverage and reduction helpers shared by the cooperative and preemptive runners.
import ExhaustCore

// MARK: - Sampling Replay Window

extension __ExhaustRuntime {
    /// Computes the interpreter start index and run count for a sampling or replay pass.
    ///
    /// When `replayIteration` is non-nil, the interpreter is positioned to replay exactly that 1-based iteration. When nil, the interpreter runs the full `samplingBudget` from the beginning. Clamps `replayIteration` to >= 1 to prevent a UInt64 underflow on `iteration - 1`.
    static func samplingReplayWindow(
        replayIteration: Int?,
        samplingBudget: UInt64
    ) -> (startIndex: UInt64, maxRuns: UInt64) {
        guard let iteration = replayIteration else {
            return (startIndex: 0, maxRuns: samplingBudget)
        }
        let clamped = max(iteration, 1)
        return (startIndex: UInt64(clamped - 1), maxRuns: UInt64(clamped))
    }
}

// MARK: - SCA Failure Result

extension __ExhaustRuntime {
    /// Packages the outcome of a failed SCA coverage probe for the concurrent runner, carrying the reduced input, original length, and reduction statistics so the caller can assemble the final ``ContractResult``.
    struct SCAFailureResult<Command> {
        var finalInput: [(ScheduleMarker, Command)]
        var originalCount: Int
        var iteration: UInt64
        var timedOut: Bool
        var reductionStats: ReductionStats?
        var reductionInvocations: Int = 0
    }
}

// MARK: - Concurrent SCA Coverage

extension __ExhaustRuntime {
    /// Runs SCA coverage for concurrent contract command sequences.
    ///
    /// Delegates to the shared ``runSCACoverageRowLoop(sequenceGen:commandGen:commandLimit:coverageBudget:skipToRow:logEventPrefix:property:)`` for the covering array iteration, then reduces any counterexample through ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``.
    ///
    /// See also: ``ConcurrentDiscovery/init(scaResult:coverageBudget:sequencesTested:)`` for converting a failure result into a discovery.
    ///
    /// - Returns: A failure result if a counterexample is found during coverage, or nil if all rows pass or SCA is not applicable.
    static func runConcurrentSCACoverage<Command>(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        skipToRow: Int? = nil,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        lastRunTimedOut: UnsafeSendableBox<Bool>,
        invocationCounter: UnsafeSendableBox<Int>
    ) -> SCAFailureResult<Command>? {
        let result = runSCACoverageRowLoop(
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            coverageBudget: coverageBudget,
            skipToRow: skipToRow,
            logEventPrefix: "concurrent_sca_coverage",
            property: property
        )
        switch result {
            case let .failure(value, tree, coverageInvocations):
                let timedOut = lastRunTimedOut.value
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "concurrent_sca_failure",
                    metadata: ["iteration": "\(coverageInvocations)", "commands": "\(value.count)", "timedOut": "\(timedOut)"]
                )

                let reductionConfig = Interpreters.ReducerConfiguration(maxStalls: 2)
                let reductionStartInvocations = invocationCounter.value
                let reduction = reduceConcurrentCounterexample(
                    input: value,
                    tree: tree,
                    sequenceGen: sequenceGen,
                    reductionConfig: reductionConfig,
                    property: property,
                    identifySkips: identifySkips,
                    seed: UInt64(coverageInvocations),
                    skipPruningLogEvent: "concurrent_sca_skip_pruning",
                    timedOut: timedOut
                )
                let reductionInvocations = invocationCounter.value - reductionStartInvocations

                return SCAFailureResult(
                    finalInput: reduction.finalInput,
                    originalCount: value.count,
                    iteration: UInt64(coverageInvocations),
                    timedOut: reduction.timedOut,
                    reductionStats: reduction.stats,
                    reductionInvocations: reductionInvocations
                )
            case .completed, .skipped:
                return nil
        }
    }
}

// MARK: - Concurrent Counterexample Reduction

extension __ExhaustRuntime {
    /// Prunes skipped commands, then runs reduction on the failing counterexample. When the failing probe timed out, skips reduction entirely and returns the input unchanged — timed-out schedules produce non-deterministic replay, making reduction unreliable.
    ///
    /// Shared by the random-sampling and SCA-coverage paths. Keeps no invocation count of its own: every probe flows through `property`, so the caller measures reduction invocations by snapshotting its own counter around this call.
    ///
    /// - Parameters:
    ///   - seed: Pruning materialization seed (sampling uses `0`; coverage uses the row iteration for determinism per row).
    ///   - skipPruningLogEvent: Log event name for the skip-pruning pass, distinguishing the two callers in the log stream.
    ///   - timedOut: The failing probe's timeout status, captured by the caller before reduction. Returned unchanged, so a reduced counterexample reports `false` rather than whatever the reducer probed last.
    static func reduceConcurrentCounterexample<Command>(
        input: [(ScheduleMarker, Command)],
        tree: ChoiceTree,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        reductionConfig: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        seed: UInt64,
        skipPruningLogEvent: String,
        timedOut: Bool
    ) -> ConcurrentReduction<Command> {
        guard timedOut == false else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_timeout_skipping_reduction"
            )
            return ConcurrentReduction(finalInput: input, stats: nil, timedOut: true)
        }

        let (reduceValue, reduceTree) = pruneSkippedCommands(
            value: input,
            tree: tree,
            generator: sequenceGen,
            seed: seed,
            property: property,
            identifySkips: identifySkips,
            logEvent: skipPruningLogEvent
        )

        let (finalInput, stats, reduced) = reduceContractCounterexample(
            value: reduceValue,
            tree: reduceTree,
            generator: sequenceGen,
            config: reductionConfig,
            property: property
        )
        if reduced {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_reduced",
                metadata: ["from": "\(input.count)", "to": "\(finalInput.count)"]
            )
        } else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_reduction_no_improvement"
            )
        }

        return ConcurrentReduction(finalInput: finalInput, stats: stats, timedOut: false)
    }
}

// MARK: - Supporting Types

extension __ExhaustRuntime {
    /// Outcome of ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``, shared by the sampling and coverage paths.
    ///
    /// Carries no invocation count or timing: every reduction probe flows through the caller's `property`, so the caller measures both by snapshotting around the call.
    struct ConcurrentReduction<Command> {
        let finalInput: [(ScheduleMarker, Command)]
        let stats: ReductionStats?
        /// The failing probe's timeout status, passed through unchanged — a reduced (non-timed-out) counterexample reports `false`, never the reducer's last probe.
        let timedOut: Bool
    }
}

// MARK: - SCAFailureResult → ConcurrentDiscovery Bridge

extension __ExhaustRuntime.ConcurrentDiscovery {
    /// Constructs a coverage discovery from an SCA failure result.
    ///
    /// Bridges the SCA-specific ``__ExhaustRuntime/SCAFailureResult`` into the pipeline-level ``__ExhaustRuntime/ConcurrentDiscovery`` with `.coverage` as the discovery method. `reductionMilliseconds` is always zero because SCA reduction time is not tracked separately from the row loop.
    init(
        scaResult: __ExhaustRuntime.SCAFailureResult<Command>,
        coverageBudget: UInt64,
        sequencesTested: Int
    ) {
        self.init(
            taggedCommands: scaResult.finalInput,
            discoveryMethod: .coverage,
            timedOut: scaResult.timedOut,
            seed: nil,
            originalCount: scaResult.originalCount,
            iteration: Int(scaResult.iteration),
            budget: coverageBudget,
            sequencesTested: sequencesTested,
            reductionStats: scaResult.reductionStats,
            reductionInvocations: scaResult.reductionInvocations,
            reductionMilliseconds: 0
        )
    }
}
