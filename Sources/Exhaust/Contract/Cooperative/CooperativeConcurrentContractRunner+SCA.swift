// SCA (Sequence Covering Array) coverage phase for concurrent contract testing.
import ExhaustCore

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

    /// Runs SCA coverage for concurrent contract command sequences.
    ///
    /// Delegates to the shared ``runSCACoverageRowLoop(seqGen:commandGen:commandLimit:coverageBudget:skipToRow:logEventPrefix:property:)`` for the covering array iteration, then reduces any counterexample through ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``.
    ///
    /// - Returns: A failure result if a counterexample is found during coverage, or nil if all rows pass or SCA is not applicable.
    static func runConcurrentSCACoverage<Command>(
        seqGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        concurrencyLevel _: Int,
        idleTimeout _: Int,
        skipToRow: Int? = nil,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        lastRunTimedOut: UnsafeSendableBox<Bool>,
        invocationCounter: UnsafeSendableBox<Int>
    ) -> SCAFailureResult<Command>? {
        let result = runSCACoverageRowLoop(
            seqGen: seqGen,
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
                    sequenceGen: seqGen,
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
