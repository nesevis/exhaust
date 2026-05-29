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
    /// Builds a covering array over command-type orderings (the schedule marker is tagged `.laneControl` and excluded from the covering array parameters). Each row materializes a specific command ordering with random lane assignments, testing the property under deterministic interleaving.
    ///
    /// - Returns: A failure result if a counterexample is found during coverage, or nil if all rows pass.
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
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_skipped",
                "Command generator is not a top-level pick — SCA not applicable"
            )
            return nil
        }

        let sequenceLength = commandLimit
        guard sequenceLength >= 2 else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_skipped",
                "Sequence length must be >= 2 for SCA"
            )
            return nil
        }

        guard let domain = SCADomain.build(
            sequenceLength: sequenceLength,
            pickChoices: pickChoices,
            coverageBudget: coverageBudget,
            strengthCap: 2
        ) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_skipped",
                "Domain construction failed"
            )
            return nil
        }

        let domainSizes = domain.profile.domainSizes
        guard domainSizes.count >= 2 else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_skipped",
                "Too few parameters for covering array"
            )
            return nil
        }

        let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
        let lengthRange = UInt64(0) ... UInt64(commandLimit)
        let reductionConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

        var iterations: UInt64 = 0
        while iterations < coverageBudget, let row = generator.next() {
            let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
            guard let tree else { continue }

            let mode = Materializer.Mode.guided(
                seed: iterations,
                fallbackTree: nil
            )
            guard case let .success(value, freshTree, _) = Materializer.materialize(
                seqGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree
            ) else {
                continue
            }

            iterations += 1
            if let skipToRow, iterations - 1 < skipToRow { continue }
            if property(value) == false {
                let timedOut = lastRunTimedOut.value
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "concurrent_sca_failure",
                    metadata: ["iteration": "\(iterations)", "commands": "\(value.count)", "timedOut": "\(timedOut)"]
                )

                let reductionStartInvocations = invocationCounter.value
                let reduction = reduceConcurrentCounterexample(
                    input: value,
                    tree: freshTree,
                    sequenceGen: seqGen,
                    reductionConfig: reductionConfig,
                    property: property,
                    identifySkips: identifySkips,
                    seed: iterations,
                    skipPruningLogEvent: "concurrent_sca_skip_pruning",
                    timedOut: timedOut
                )
                let reductionInvocations = invocationCounter.value - reductionStartInvocations

                return SCAFailureResult(
                    finalInput: reduction.finalInput,
                    originalCount: value.count,
                    iteration: iterations,
                    timedOut: reduction.timedOut,
                    reductionStats: reduction.stats,
                    reductionInvocations: reductionInvocations
                )
            }
            if skipToRow != nil { break }
        }

        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_coverage",
            metadata: [
                "command_types": "\(pickChoices.count)",
                "iterations": "\(iterations)",
                "sequence_length": "\(sequenceLength)",
                "strength": "2",
            ]
        )

        return nil
    }
}
