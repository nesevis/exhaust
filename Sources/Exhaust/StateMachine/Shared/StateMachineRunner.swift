// Runtime execution engine for spec tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous spec test to the appropriate runner based on the spec's ``ExecutionModel``.
    @discardableResult
    static func __runStateMachineDispatch<Spec: StateMachineSpec>(
        _ specType: Spec.Type,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> StateMachineResult<Spec>? {
        switch Spec.executionModel {
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

public extension __ExhaustRuntime {
    /// Runs a `.tasks` spec test for the given spec type.
    ///
    /// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
    ///
    /// - Parameters:
    ///   - specType: The `@StateMachine`-annotated spec type.
    ///   - settings: Configuration options controlling iteration count, coverage, reduction, and command limits.
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
                coverageBudget: UInt64(config.budget.coverageBudget)
            )
            let untaggedSeqGen = commandGen.array(length: 0 ... commandLimit, scaling: .constant).gen
            let taggedSeqGen = untaggedSeqGen.map { commands in
                commands.map { (ScheduleMarker.prefix, $0) }
            }

            let invocationCounter = UnsafeSendableBox(0)
            let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = syncSequentialProperty(Spec.self)
            let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
                invocationCounter.value += 1
                return rawProperty(taggedCommands)
            }

            let syncSkipIdentifier = Spec.skipIdentifier
            let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
                syncSkipIdentifier(tagged.map(\.1))
            }

            let backend = SequentialStateMachineBackend<Spec>(
                property: property,
                finalize: { tagged in
                    let commands = tagged.map(\.1)
                    let (trace, spec) = buildTrace(commands, specType: specType)
                    return (trace, spec.systemUnderTest, spec.failureDescription())
                }
            )

            let pipeline = SpecPipeline(
                backend: backend,
                sequenceGen: taggedSeqGen,
                commandGen: commandGen.gen,
                commandLimit: commandLimit,
                concurrencyLevel: 1,
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

public extension __ExhaustRuntime {
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
        var config = parsed.config
        config.concurrencyLevel = 1

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        let logConfiguration = config.logConfiguration

        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.single) {
            ExhaustLog.withConfiguration(logConfiguration) {
                runAsyncSequentialPipeline(
                    specType,
                    config: config,
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

private extension __ExhaustRuntime {
    static func runAsyncSequentialPipeline<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String] = [],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        let commandGen = Spec.commandGenerator
        let commandLimit = config.commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            coverageBudget: UInt64(config.budget.coverageBudget)
        )
        let untaggedSeqGen = commandGen.array(length: 0 ... commandLimit, scaling: .constant).gen
        let taggedSeqGen = untaggedSeqGen.map { commands in
            commands.map { (ScheduleMarker.prefix, $0) }
        }

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        let invocationCounter = UnsafeSendableBox(0)
        let rawProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = asyncSequentialProperty(specInit: specInit)
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            return rawProperty(taggedCommands)
        }

        let asyncSkipIdentifier = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { tagged in
            asyncSkipIdentifier(tagged.map(\.1))
        }

        let backend = SequentialStateMachineBackend<Spec>(
            property: property,
            finalize: { tagged in
                let commands = tagged.map(\.1)
                let captured = __ExhaustRuntime._blockingAwaitSemaphore(timeoutMilliseconds: nil) {
                    let spec = specInit()
                    let (trace, _) = await buildAsyncSequentialTrace(
                        commands,
                        run: { try await spec.run($0) },
                        checkInvariants: { try await spec.checkInvariants() }
                    )
                    let snapshot = await spec.diagnosticSnapshot()
                    return (trace: trace, snapshot: snapshot)
                }!
                return (captured.trace, captured.snapshot.systemUnderTest, captured.snapshot.failureDescription)
            }
        )

        let pipeline = SpecPipeline(
            backend: backend,
            sequenceGen: taggedSeqGen,
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            concurrencyLevel: 1,
            identifySkips: identifySkips,
            property: property,
            invocationCounter: invocationCounter,
            sequenceGenForLength: nil,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        let (result, issues) = pipeline.runWithRegressions(
            config: config,
            regressionSeeds: regressionSeeds
        )
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }
}

// MARK: - Regression Seed Replay

extension __ExhaustRuntime {
    /// Replays each regression seed through a caller-supplied machine runner, returning the first failure.
    ///
    /// Shared by the cooperative and preemptive entry points. Decodes each seed, builds a modified config (expanding the coverage budget for `.coverage(row)` seeds), and delegates to `runMachine`. Returns `nil` result when all seeds pass.
    static func replayRegressionSeeds<Spec: StateMachineSpecBase>(
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        runMachine: (ResolvedConcurrentConfig) -> (result: StateMachineResult<Spec>?, issues: [String])
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        guard config.coverageReplayRow == nil, config.seed == nil else {
            return (nil, deferredIssues)
        }

        for encodedSeed in regressionSeeds {
            guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                continue
            }

            var replayConfig = config
            switch decoded {
                case let .coverage(row):
                    replayConfig.coverageReplayRow = row
                    let needed = row + 1
                    if replayConfig.budget.coverageBudget < needed {
                        replayConfig.budget = .custom(
                            coverage: needed,
                            sampling: replayConfig.budget.samplingBudget
                        )
                    }
                case let .sampling(seed, iteration?):
                    replayConfig.seed = seed
                    replayConfig.replayIteration = iteration
                    if replayConfig.budget.samplingBudget < iteration + 1 {
                        replayConfig.budget = .custom(
                            coverage: replayConfig.budget.coverageBudget,
                            sampling: iteration + 1
                        )
                    }
                case let .sampling(seed, nil):
                    replayConfig.seed = seed
            }

            let (result, issues) = runMachine(replayConfig)
            deferredIssues.append(contentsOf: issues)
            if let result {
                return (result, deferredIssues)
            } else if config.suppressIssueReporting == false {
                deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
            }
        }

        return (nil, deferredIssues)
    }
}

// MARK: - Trace Building

private extension __ExhaustRuntime {
    static func buildTrace<Spec: StateMachineSpec>(
        _ commands: [Spec.Command],
        specType _: Spec.Type
    ) -> ([TraceStep], Spec) {
        let spec = Spec()
        let (trace, _) = buildSequentialTrace(
            commands,
            run: { try spec.run($0) },
            checkInvariants: { try spec.checkInvariants() }
        )
        return (trace, spec)
    }
}
