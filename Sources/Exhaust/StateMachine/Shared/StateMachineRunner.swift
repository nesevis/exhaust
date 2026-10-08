// Runtime execution engine for spec tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing screening + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous spec test to the runner the call site asked for.
    ///
    /// A synchronous spec has no suspension points to interleave at, so `.tasks` routes to the sequential runner: cooperative interleaving needs async commands, which reach the async twin instead.
    @discardableResult
    static func __runStateMachineDispatch<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        mode: ExecutionModel,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> StateMachineResult<Spec>? {
        switch mode {
            case .sequential, .tasks:
                // Sequential specs run inline and spawn no GCD lanes, so no gate hop is needed.
                return __runStateMachine(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .threads:
                return await __runPreemptiveConcurrentStateMachine(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
        }
    }
}

// MARK: - Entry Point

package extension __ExhaustRuntime {
    /// Runs a `.tasks` spec test for the given spec type.
    ///
    /// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
    ///
    /// - Parameters:
    ///   - specType: The `@StateMachine`-annotated spec type.
    ///   - settings: Configuration options controlling iteration count, screening, reduction, and command limits.
    @discardableResult
    static func __runStateMachine<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> StateMachineResult<Spec>? {
        let parsed = ResolvedConcurrentConfig.parse(settings)
        guard parsed.invalidReplaySeed == nil else {
            reportError("Invalid replay seed", fileID: fileID, filePath: filePath, line: line, column: column)
            return nil
        }
        parsed.reportCommandLimitClampWarning(fileID: fileID, filePath: filePath, line: line, column: column)
        var config = parsed.config
        config.concurrencyLevel = 1

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        return ExhaustLog.withConfiguration(config.logConfiguration) {
            let commandGen = Spec.commandGenerator
            let commandLimit = config.commandLimit ?? estimateCommandLimit(
                commandGen: commandGen.gen,
                screeningBudget: UInt64(config.budget.screeningBudget)
            )
            let taggedSeqGen = taggedSequenceGenerator(commandGen: commandGen, commandLimit: commandLimit)

            let invocationCounter = UnsafeSendableBox(0)
            let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = syncSequentialProperty(Spec.self)
            let property: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
                invocationCounter.value += 1
                return rawProperty(candidate)
            }

            let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
                Spec.identifySkips(setupStep: candidate.setupStep, commands: candidate.taggedCommands.map(\.1))
            }

            let backend = SequentialStateMachineBackend<Spec>(
                property: property,
                finalize: { candidate in
                    let (trace, spec) = buildTrace(candidate, specType: specType)
                    return (trace, spec.systemUnderTest, spec.failureDescription())
                }
            )

            let pipeline = SpecPipeline(
                backend: backend,
                sequenceGen: taggedSeqGen,
                commandGen: commandGen.gen,
                commandLimit: commandLimit,
                concurrencyLevel: nil,
                identifySkips: identifySkips,
                property: property,
                invocationCounter: invocationCounter,
                sequenceGenForLength: nil,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            let (result, deferredIssues) = pipeline.runWithRegressions(
                config: config,
                regressionSeeds: regressionSeeds
            )
            for issue in deferredIssues {
                ExhaustLog.error(category: .propertyTest, event: "statemachine_failed", issue)
                reportError(issue, fileID: fileID, filePath: filePath, line: line, column: column)
            }

            return result
        }
    }
}

// MARK: - Async Sequential Entry Point

package extension __ExhaustRuntime {
    /// Runs a `.sequential` async spec test without requiring macOS 15.
    ///
    /// Dispatches the pipeline to a GCD thread and bridges async command execution via ``blockingAwait(_:)``. This avoids the cooperative executor (and its availability gate) while still running async commands sequentially.
    @discardableResult
    static func __runStateMachineAsync<Spec: AsyncStateMachineSpec>(
        _ specType: Spec.Type,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> StateMachineResult<Spec>? {
        let parsed = ResolvedConcurrentConfig.parse(settings)
        guard parsed.invalidReplaySeed == nil else {
            reportError("Invalid replay seed", fileID: fileID, filePath: filePath, line: line, column: column)
            return nil
        }
        parsed.reportCommandLimitClampWarning(fileID: fileID, filePath: filePath, line: line, column: column)
        var config = parsed.config
        config.concurrencyLevel = 1

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        let logConfiguration = config.logConfiguration

        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.single) { gateWaitNanoseconds in
            var admittedConfig = config
            admittedConfig.postponeDeadline(by: gateWaitNanoseconds)
            return ExhaustLog.withConfiguration(logConfiguration) {
                runAsyncSequentialPipeline(
                    specType,
                    config: admittedConfig,
                    regressionSeeds: regressionSeeds,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        }
        for issue in deferredIssues {
            reportError(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}
