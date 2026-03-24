// Runtime execution engine for async contract property tests.
//
// Bridges async spec execution to the synchronous core (Freer Monad, ChoiceTree,
// reduction) by dispatching the entire sync pipeline onto a non-cooperative GCD
// thread where semaphore-blocking is safe. This avoids deadlocking the
// cooperative thread pool per Massicotte's guidance.
import ExhaustCore
import Foundation
import IssueReporting

/// Mutable box for passing a value-type spec across the Task boundary.
final class SpecBox<Spec>: @unchecked Sendable {
    var spec: Spec
    init(_ spec: Spec) {
        self.spec = spec
    }
}

/// Runs an async contract property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized `commandGenerator`, executes each sequence against a fresh instance using async `run`/`checkInvariants`, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
///
/// The synchronous core runs on a GCD thread. Async spec methods are invoked via `Task` + semaphore from that thread, avoiding cooperative thread pool deadlocks.
@discardableResult
public func __runContractAsync<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int,
    settings: [ContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    var budget = ExhaustBudget.expensive
    var seed: UInt64?
    var suppressIssueReporting = false
    var useRandomOnly = false
    var useArgumentAwareCoverage = false
    for setting in settings {
        switch setting {
        case let .budget(b):
            budget = b
        case let .replay(s):
            seed = s
        case .suppressIssueReporting:
            suppressIssueReporting = true
        case .randomOnly:
            useRandomOnly = true
        case .argumentAwareCoverage:
            useArgumentAwareCoverage = true
        }
    }

    let commandGen = Spec.commandGenerator
    let samplingBudget = budget.samplingBudget
    let coverageBudget = budget.coverageBudget
    let reductionConfig = budget.reducerBudget

    let seqGen: ReflectiveGenerator<[Spec.Command]> = commandGen.array(
        length: 0 ... commandLimit
    )

    // The sync property closure runs async spec methods via Task + semaphore.
    // This closure is called from a GCD thread where semaphore.wait() is safe.
    nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
    let property: @Sendable ([Spec.Command]) -> Bool = { commands in
        let box = SpecBox(specInit())
        let resultBox = SpecBox(true)
        let semaphore = DispatchSemaphore(value: 0)

        Task { @Sendable in
            for command in commands {
                do {
                    try await box.spec.run(command)
                    try await box.spec.checkInvariants()
                } catch is ContractSkip {
                    continue
                } catch is ContractCheckFailure {
                    resultBox.spec = false
                    break
                } catch {
                    resultBox.spec = false
                    break
                }
            }
            semaphore.signal()
        }

        semaphore.wait()
        return resultBox.spec
    }

    // Snapshot mutable settings into let bindings for Sendable capture.
    let maxIter = samplingBudget
    let covBudget = coverageBudget
    let replaySeed = seed
    nonisolated(unsafe) let reduction = reductionConfig
    let randomOnly = useRandomOnly
    let argAwareCoverage = useArgumentAwareCoverage

    // Dispatch the entire sync core onto a GCD thread via withCheckedContinuation.
    let searchResult: ([Spec.Command], ContractFailureInfo<Spec.Command>)? = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            // SCA coverage
            var scaResult: SCAResult<Spec.Command>?
            if !randomOnly, replaySeed == nil {
                scaResult = runSCACoverage(
                    seqGen: seqGen,
                    commandGen: commandGen,
                    commandLimit: commandLimit,
                    coverageBudget: covBudget,
                    reductionConfig: reduction,
                    argumentAware: argAwareCoverage,
                    property: property
                )
            }

            if let scaResult {
                let info = ContractFailureInfo(originalCommands: scaResult.original, discoveryMethod: .coverage)
                continuation.resume(returning: (scaResult.commands, info))
            } else {
                let skipGenericCoverage = !randomOnly && replaySeed == nil && extractPickChoices(from: commandGen) != nil
                let exhaustResult = __ExhaustRuntime.__exhaust(
                    seqGen,
                    settings: buildExhaustSettings(
                        samplingBudget: maxIter,
                        coverageBudget: covBudget,
                        seed: replaySeed,
                        reductionConfig: reduction,
                        suppressIssueReporting: true,
                        useRandomOnly: randomOnly || skipGenericCoverage
                    ),
                    sourceCode: nil,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: property
                )
                if let exhaustResult {
                    let info: ContractFailureInfo<Spec.Command> = ContractFailureInfo(
                        originalCommands: nil,
                        discoveryMethod: replaySeed != nil ? .replay : .randomSampling
                    )
                    continuation.resume(returning: (exhaustResult, info))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    guard let (failingSequence, failureInfo) = searchResult else {
        return nil
    }

    // Build trace asynchronously
    let (trace, spec) = await buildTraceAsync(failingSequence, specType: specType)

    let result = ContractResult<Spec>(
        commands: failingSequence,
        trace: trace,
        sut: spec.sut,
        seed: seed,
        discoveryMethod: failureInfo.discoveryMethod
    )

    if !suppressIssueReporting {
        let rendered = renderFailure(result, failureInfo: failureInfo, modelDescription: spec.modelDescription)
        ExhaustLog.error(
            category: .propertyTest,
            event: "contract_failed",
            rendered
        )
        reportIssue(
            rendered,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    return result
}

// MARK: - Async trace building

/// Re-executes the failing command sequence asynchronously to build a step-by-step trace.
private func buildTraceAsync<Spec: AsyncContractSpec>(
    _ commands: [Spec.Command],
    specType _: Spec.Type
) async -> ([TraceStep], Spec) {
    var spec = Spec()
    var trace: [TraceStep] = []
    trace.reserveCapacity(commands.count)

    for (index, command) in commands.enumerated() {
        let step = index + 1
        let description = "\(command)"

        do {
            try await spec.run(command)
        } catch is ContractSkip {
            trace.append(TraceStep(index: step, command: description, outcome: .skipped))
            continue
        } catch let failure as ContractCheckFailure {
            trace.append(TraceStep(index: step, command: description, outcome: .checkFailed(message: failure.message)))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(index: step, command: description, outcome: .checkFailed(message: "\(error)")))
            return (trace, spec)
        }

        do {
            try await spec.checkInvariants()
        } catch let failure as ContractCheckFailure {
            let name = failure.message ?? "unknown"
            trace.append(TraceStep(index: step, command: description, outcome: .invariantFailed(name: name)))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(index: step, command: description, outcome: .invariantFailed(name: "\(error)")))
            return (trace, spec)
        }

        trace.append(TraceStep(index: step, command: description, outcome: .ok))
    }

    return (trace, spec)
}
