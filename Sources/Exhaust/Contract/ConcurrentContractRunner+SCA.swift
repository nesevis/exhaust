// SCA (Sequence Covering Array) coverage phase for concurrent contract testing.
import ExhaustCore

/// Packages the outcome of a failed SCA coverage probe for the concurrent runner, carrying the reduced input, original length, and reduction statistics so the caller can assemble the final ``ContractResult``.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
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
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func runConcurrentSCACoverage<Command>(
    seqGen: Generator<[(ScheduleMarker, Command)]>,
    commandGen: Generator<Command>,
    commandLimit: Int,
    coverageBudget: UInt64,
    concurrencyLevel: Int,
    idleTimeout: Int,
    property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
    identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
    lastRunTimedOut: SendableBox<Bool>
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

    let strengthCap = switch sequenceLength {
    case ...6: 6
    case ...8: 5
    case ...12: 4
    case ...20: 3
    default: 2
    }

    guard let domain = SCADomain.build(
        sequenceLength: sequenceLength,
        pickChoices: pickChoices,
        coverageBudget: coverageBudget,
        strengthCap: strengthCap
    ) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Domain construction failed"
        )
        return nil
    }

    let domainSizes = domain.profile.domainSizes
    let strength = min(domain.maxStrength, domainSizes.count, 4)
    guard strength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Too few parameters for covering array"
        )
        return nil
    }

    let generator = PullBasedCoveringArrayGenerator(
        domainSizes: domainSizes,
        strength: strength
    )
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
        if property(value) == false {
            let timedOut = lastRunTimedOut.value
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_failure",
                metadata: ["iteration": "\(iterations)", "commands": "\(value.count)", "timedOut": "\(timedOut)"]
            )

            if timedOut {
                return SCAFailureResult(finalInput: value, originalCount: value.count, iteration: iterations, timedOut: true)
            }

            let (reduceValue, reduceTree) = pruneSkippedCommands(
                value: value,
                tree: freshTree,
                generator: seqGen,
                seed: iterations,
                property: property,
                identifySkips: identifySkips,
                logEvent: "concurrent_sca_skip_pruning"
            )

            nonisolated(unsafe) var reductionPropertyInvocations = 0
            let countingProperty: @Sendable ([(ScheduleMarker, Command)]) -> Bool = { taggedCommands in
                reductionPropertyInvocations += 1
                return property(taggedCommands)
            }
            if let reduceResult = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: seqGen,
                tree: reduceTree,
                output: reduceValue,
                config: reductionConfig,
                property: countingProperty
            ) {
                if let (_, reduced) = reduceResult.reduced {
                    return SCAFailureResult(finalInput: reduced, originalCount: value.count, iteration: iterations, timedOut: false, reductionStats: reduceResult.stats, reductionInvocations: reductionPropertyInvocations)
                }
                return SCAFailureResult(finalInput: reduceValue, originalCount: value.count, iteration: iterations, timedOut: false, reductionStats: reduceResult.stats, reductionInvocations: reductionPropertyInvocations)
            }
            return SCAFailureResult(finalInput: reduceValue, originalCount: value.count, iteration: iterations, timedOut: false)
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "concurrent_sca_coverage",
        metadata: [
            "command_types": "\(pickChoices.count)",
            "iterations": "\(iterations)",
            "sequence_length": "\(sequenceLength)",
            "strength": "\(strength)",
        ]
    )

    return nil
}
