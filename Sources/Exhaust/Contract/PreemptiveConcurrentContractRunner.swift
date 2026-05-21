import ExhaustCore
import Foundation
import IssueReporting

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

    while let (taggedCommands, _) = try? interpreter.next() {
        let commands = taggedCommands.map(\.1)

        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter { $0.0.isPrefix }
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        // Run prefix sequentially on both specs
        for (_, command) in prefixCommands {
            try? concurrentSpec.run(command)
            try? sequentialSpec.run(command)
        }

        // Run concurrent commands sequentially on the oracle
        for (_, command) in concurrentCommands {
            try? sequentialSpec.run(command)
        }

        // Dispatch concurrent commands across GCD lanes
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

        // Check invariants on quiescent SUT
        let invariantFailed: Bool
        do {
            try concurrentSpec.checkInvariants()
            invariantFailed = false
        } catch {
            invariantFailed = true
        }

        // Oracle comparison
        let oracleMatches = concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)

        if invariantFailed || oracleMatches == false {
            let trace = commands.enumerated().map { index, command in
                TraceStep(
                    index: index + 1,
                    command: "\(command)",
                    outcome: .ok
                )
            }

            let result = ContractResult<Spec>(
                commands: commands,
                trace: trace,
                systemUnderTest: concurrentSpec.systemUnderTest,
                seed: actualSeed,
                discoveryMethod: .randomSampling
            )

            if config.suppressIssueReporting == false {
                let detail = oracleMatches == false
                    ? "Oracle mismatch: concurrent SUT state differs from sequential replay"
                    : "Invariant violation after concurrent execution"
                reportIssue(
                    "Preemptive concurrent contract failure in \(Spec.self): \(detail)\nCommands: \(commands)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            }

            return result
        }
    }

    return nil
}

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
