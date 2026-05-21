import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Runner Entry Point

/// Runs a preemptive concurrent contract test for the given sync specification type.
///
/// Dispatches commands across real GCD threads and uses the spec's ``ConcurrentContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving — bug detection is probabilistic, relying on repetition across the sampling budget.
@discardableResult
public func __runPreemptiveConcurrentContract<Spec: ConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    let config: ResolvedConcurrentConfig
    switch ResolvedConcurrentConfig.parse(settings) {
    case let .success(resolved):
        config = resolved
    case let .invalidReplaySeed(seed):
        reportIssue(
            "Invalid replay seed: \(seed)",
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        return nil
    }

    let commandGen = Spec.commandGenerator.gen
    let commandLimit = config.commandLimit ?? 8
    let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
    let sequenceGen = Gen.arrayOf(
        taggedCommandGen,
        within: 1 ... UInt64(commandLimit),
        scaling: .constant
    )

    let samplingBudget = config.budget.samplingBudget
    var interpreter = ValueAndChoiceTreeInterpreter(
        sequenceGen,
        materializePicks: true,
        seed: config.seed,
        maxRuns: samplingBudget
    )
    let actualSeed = interpreter.baseSeed

    let check = PreemptiveChecker<Spec>()
    var iteration = 0

    // Sampling phase: find first failure
    while let (taggedCommands, tree) = try? interpreter.next() {
        iteration += 1
        if check.execute(taggedCommands) == false {
            // Reduction phase: best-effort three-pass shrinking
            let reductionResult = check.reduce(
                generator: sequenceGen,
                tree: tree,
                output: taggedCommands,
                repetitions: 10
            )
            let reduced = reductionResult.output

            let commands = reduced.map(\.1)

            // Build trace with per-lane indices matching CCR format
            var laneCounts: [UInt8: Int] = [:]
            let trace = reduced.enumerated().map { index, tagged in
                let (marker, command) = tagged
                if marker.isPrefix {
                    return TraceStep(
                        index: index + 1,
                        command: "\(command) (prefix)",
                        outcome: .ok
                    )
                } else {
                    let laneLabel = marker.description.uppercased()
                    laneCounts[marker.rawValue, default: 0] += 1
                    let laneIndex = laneCounts[marker.rawValue]!
                    return TraceStep(
                        index: index + 1,
                        command: "\(laneIndex)\(laneLabel) \(command) (completed)",
                        outcome: .ok
                    )
                }
            }

            // Run sequential oracle on the reduced sequence for the failure report
            let oracleSpec = Spec()
            for (_, command) in reduced {
                try? oracleSpec.run(command)
            }

            let result = ContractResult<Spec>(
                commands: commands,
                trace: trace,
                systemUnderTest: oracleSpec.systemUnderTest,
                seed: actualSeed,
                discoveryMethod: .randomSampling
            )

            if config.suppressIssueReporting == false {
                var failureContext = FailureContext()
                failureContext.specName = "\(Spec.self)"
                failureContext.discoveryMethod = .randomSampling
                failureContext.seed = actualSeed
                failureContext.iteration = iteration
                failureContext.budget = samplingBudget
                failureContext.sequencesTested = iteration
                failureContext.reductionInvocations = reductionResult.propertyInvocations
                failureContext.originalCount = taggedCommands.count
                failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(oracleSpec.sutDescription)"
                let message = renderFailure(reduced, trace: trace, context: failureContext)
                reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
            }

            return result
        }
    }

    return nil
}

// MARK: - Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for a ``ConcurrentContractSpec``.
private struct PreemptiveChecker<Spec: ConcurrentContractSpec> {

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants + oracle.
    ///
    /// Returns `true` if the execution passes. Returns `false` if invariants fail or the oracle detects divergence from sequential behavior.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter { $0.0.isPrefix }
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        for (_, command) in prefixCommands {
            try? concurrentSpec.run(command)
            try? sequentialSpec.run(command)
        }

        for (_, command) in concurrentCommands {
            try? sequentialSpec.run(command)
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                for (_, command) in laneCommands {
                    try? concurrentSpec.run(command)
                }
                group.leave()
            }
        }
        group.wait()

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return false
        }

        return concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)
    }

    struct ReductionResult {
        let output: [(ScheduleMarker, Spec.Command)]
        let propertyInvocations: Int
    }

    /// Best-effort three-pass reduction. Returns the best result found, which may be the original if reduction stalled.
    func reduce(
        generator: Generator<[(ScheduleMarker, Spec.Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Spec.Command)],
        repetitions: Int
    ) -> ReductionResult {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if self.execute(taggedCommands) == false {
                    return false
                }
            }
            return true
        }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let cosmetic = Set(EncoderName.allCases).subtracting(structural).subtracting([.laneCollapse])

        var currentOutput = output
        var currentTree = tree

        // Pass 0: establish maximal sequential prefix
        if let (sequence, reduced) = try? Interpreters.choiceGraphReduce(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10_000_000_000, enabledEncoders: [.laneCollapse]),
            property: property
        ) {
            currentOutput = reduced
            if case let .success(_, freshTree, _) = Materializer.materialize(
                generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
            ) {
                currentTree = freshTree
            }
        }

        // Pass 1: structural reduction on the concurrent tail
        if let (sequence, reduced) = try? Interpreters.choiceGraphReduce(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 30_000_000_000, enabledEncoders: structural),
            property: property
        ) {
            currentOutput = reduced
            if case let .success(_, freshTree, _) = Materializer.materialize(
                generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
            ) {
                currentTree = freshTree
            }
        }

        // Pass 2: cosmetic value cleanup, short budget
        if let (_, reduced) = try? Interpreters.choiceGraphReduce(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 5_000_000_000, enabledEncoders: cosmetic),
            property: property
        ) {
            currentOutput = reduced
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations)
    }
}

// MARK: - Async Entry Point

/// Entry point for preemptive concurrent contract testing with async commands and oracle comparison.
///
/// Same as ``__runPreemptiveConcurrentContract`` but for specs with async commands.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@discardableResult
public func __runPreemptiveConcurrentContractAsync<Spec: AsyncConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    // TODO: Implement async variant
    reportIssue(
        "Async preemptive concurrent contract testing is not yet implemented",
        fileID: fileID, filePath: filePath, line: line, column: column
    )
    return nil
}
