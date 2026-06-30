// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Dispatch

public extension __ExhaustRuntime {
    /// Dispatches a synchronous contract test to the appropriate runner based on the contract's ``ExecutionModel``.
    @discardableResult
    static func __runContractDispatch<Spec: ContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ContractResult<Spec>? {
        switch Spec.executionModel {
            case .sequential, .tasks:
                return __runContract(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .threads:
                return __runPreemptiveConcurrentContract(
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
    /// Runs a `.tasks` contract property test for the given contract type.
    ///
    /// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
    ///
    /// - Parameters:
    ///   - specType: The `@Contract`-annotated contract type.
    ///   - settings: Configuration options controlling iteration count, coverage, reduction, and command limits.
    @discardableResult
    static func __runContract<Spec: ContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ContractResult<Spec>? {
        let parsed = ResolvedConcurrentConfig.parse(settings)
        guard parsed.invalidReplaySeed == nil else {
            reportIssue("Invalid replay seed", fileID: fileID, filePath: filePath, line: line, column: column)
            return nil
        }
        var config = parsed.config
        config.concurrencyLevel = 1

        return ExhaustLog.withConfiguration(config.logConfiguration) {
            if let result = runRegressionSeeds(
                specType: specType,
                settings: settings,
                config: config,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            ) {
                return result
            }

            let commandGen = Spec.commandGenerator
            let commandLimit = config.commandLimit ?? estimateCommandLimit(
                commandGen: commandGen.gen,
                coverageBudget: config.budget.coverageBudget
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

            let runContext = ContractRunContext<Spec>(
                config: config,
                sequenceGen: taggedSeqGen,
                commandGen: commandGen.gen,
                commandLimit: commandLimit,
                identifySkips: identifySkips,
                invocationCounter: invocationCounter,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            let sources = buildContractSources(
                config: config,
                sequenceGen: taggedSeqGen,
                commandGen: commandGen.gen,
                commandLimit: commandLimit,
                concurrencyLevel: 1,
                property: property
            )

            let backend = SequentialContractBackend<Spec>(
                property: property,
                finalize: { tagged in
                    let commands = tagged.map(\.1)
                    let (trace, spec) = buildTrace(commands, specType: specType)
                    return (trace, spec.systemUnderTest, spec.failureDescription())
                }
            )

            var machine = ContractMachine(backend: backend, context: runContext, sources: sources)
            let result = machine.run()

            for issue in runContext.deferredIssues {
                ExhaustLog.error(category: .propertyTest, event: "contract_failed", issue)
                reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
            }

            return result
        }
    }
}

// MARK: - Async Sequential Entry Point

public extension __ExhaustRuntime {
    /// Runs a `.sequential` async contract property test without requiring macOS 15.
    ///
    /// Dispatches the pipeline to a GCD thread and bridges async command execution via ``blockingAwait(_:)``. This avoids the cooperative executor (and its availability gate) while still running async commands sequentially.
    @discardableResult
    static func __runContractAsync<Spec: AsyncContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> ContractResult<Spec>? {
        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        let logConfiguration = ResolvedConcurrentConfig.logConfiguration(from: settings)

        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD {
            ExhaustLog.withConfiguration(logConfiguration) {
                runAsyncSequentialPipeline(
                    specType,
                    settings: settings,
                    regressionSeeds: regressionSeeds,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        }
        for issue in deferredIssues {
            reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}

private extension __ExhaustRuntime {
    static func runAsyncSequentialPipeline<Spec: AsyncContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        regressionSeeds: [String] = [],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: ContractResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        let parsed = ResolvedConcurrentConfig.parse(settings)
        guard parsed.invalidReplaySeed == nil else {
            deferredIssues.append("Invalid replay seed")
            return (nil, deferredIssues)
        }
        var config = parsed.config
        config.concurrencyLevel = 1

        if config.seed == nil, config.coverageReplayRow == nil, config.replayIteration == nil {
            for encodedSeed in regressionSeeds {
                guard ReplaySeed.Resolved.decode(encodedSeed) != nil else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                let (replayResult, replayIssues) = runAsyncSequentialPipeline(
                    specType,
                    settings: [.replay(.encoded(encodedSeed))] + settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                deferredIssues.append(contentsOf: replayIssues)

                if let replayResult {
                    return (replayResult, deferredIssues)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        let commandGen = Spec.commandGenerator
        let commandLimit = config.commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            coverageBudget: config.budget.coverageBudget
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

        let runContext = ContractRunContext<Spec>(
            config: config,
            sequenceGen: taggedSeqGen,
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            identifySkips: identifySkips,
            invocationCounter: invocationCounter,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        let sources = buildContractSources(
            config: config,
            sequenceGen: taggedSeqGen,
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            concurrencyLevel: 1,
            property: property
        )

        let backend = SequentialContractBackend<Spec>(
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

        var machine = ContractMachine(backend: backend, context: runContext, sources: sources)
        let result = machine.run()

        deferredIssues.append(contentsOf: runContext.deferredIssues)
        return (result, deferredIssues)
    }
}

// MARK: - Regression Seeds

private extension __ExhaustRuntime {
    /// Replays each regression seed from the Swift Testing trait configuration, returning the first failure as a ``ContractResult``. Returns nil when all seeds pass, none are configured, or Swift Testing is unavailable.
    ///
    /// Each seed is replayed through the same path as an inline `.replay(...)`, so coverage-row (`U…`) and iteration-suffixed (`…-N`) seeds (the exact strings the runner prints) round-trip and the failing run is re-materialised at its true position rather than only the first value.
    static func runRegressionSeeds<Spec: ContractSpec>(
        specType: Spec.Type,
        settings: [ContractSettings],
        config: ResolvedConcurrentConfig,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ContractResult<Spec>? {
        #if canImport(Testing)
            guard config.seed == nil, config.coverageReplayRow == nil, config.replayIteration == nil else {
                return nil
            }
            guard let traitConfig = ExhaustTraitConfiguration.current,
                  traitConfig.regressions.isEmpty == false
            else {
                return nil
            }

            for encodedSeed in traitConfig.regressions {
                guard ReplaySeed.Resolved.decode(encodedSeed) != nil else {
                    reportIssue("Invalid regression seed: \(encodedSeed)", fileID: fileID, filePath: filePath, line: line, column: column)
                    continue
                }
                if let result = __runContract(
                    specType,
                    settings: [.replay(.encoded(encodedSeed))] + settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                ) {
                    return result
                } else if config.suppressIssueReporting == false {
                    reportIssue(
                        "Regression seed \"\(encodedSeed)\" now passes. Consider removing it.",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }
            }
            return nil
        #else
            return nil
        #endif
    }
}

// MARK: - Regression Seed Replay

extension __ExhaustRuntime {
    /// Replays each regression seed through a caller-supplied machine runner, returning the first failure.
    ///
    /// Shared by the cooperative and preemptive entry points. Decodes each seed, builds a modified config (expanding the coverage budget for `.coverage(row)` seeds), and delegates to `runMachine`. Returns `nil` result when all seeds pass.
    static func replayRegressionSeeds<Spec: ContractSpecBase>(
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        runMachine: (ResolvedConcurrentConfig) -> (result: ContractResult<Spec>?, issues: [String])
    ) -> (result: ContractResult<Spec>?, deferredIssues: [String]) {
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
                    let needed = UInt64(row) + 1
                    if replayConfig.budget.coverageBudget < needed {
                        replayConfig.budget = .custom(
                            coverage: needed,
                            sampling: replayConfig.budget.samplingBudget
                        )
                    }
                case let .sampling(seed, iteration):
                    replayConfig.seed = seed
                    replayConfig.replayIteration = iteration
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
    static func buildTrace<Spec: ContractSpec>(
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
