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
        let context = ContractContext(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        guard context.hasInvalidReplaySeed == false else {
            reportIssue(
                "Invalid replay seed",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return nil
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: context.suppressLogs == false, minimumLevel: context.logLevel, format: .keyValue)) {
            var context = context
            let commandGen = Spec.commandGenerator
            let (sequenceGenerator, commandLimit) = makeCommandSequence(commandGen: commandGen, context: context)

            // The property: execute the command sequence against a fresh spec and check for failures.
            let property: @Sendable ([Spec.Command]) -> Bool = { commands in
                let spec = Spec()
                for command in commands {
                    do {
                        try spec.run(command)
                        try spec.checkInvariants()
                    } catch is ContractSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                return true
            }

            // If regression seeds were passed in through a Swift Testing trait, execute those first.
            if let result = runRegressionSeeds(
                specType: specType,
                settings: settings,
                context: context
            ) {
                return result
            }

            guard let (result, rendered) = runSequentialContract(
                specType,
                commandGen: commandGen,
                sequenceGenerator: sequenceGenerator,
                commandLimit: commandLimit,
                context: &context,
                property: property,
                identifySkips: Spec.skipIdentifier,
                finalize: { commands in
                    let (trace, spec) = buildTrace(commands, specType: specType)
                    return (trace, spec.systemUnderTest, spec.failureDescription())
                }
            ) else {
                // The test passed
                return nil
            }

            if let rendered {
                ExhaustLog.error(category: .propertyTest, event: "contract_failed", rendered)
                reportIssue(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
            }

            return result
        } // withConfiguration
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

        let logConfiguration = ContractContext.logConfiguration(from: settings)

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

        var context = ContractContext(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        guard context.hasInvalidReplaySeed == false else {
            deferredIssues.append("Invalid replay seed")
            return (nil, deferredIssues)
        }

        if context.isSamplingReplay == false, context.isCoverageReplay == false {
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
                } else {
                    let suppressIssueReporting = settings.contains {
                        switch $0 {
                            case .suppress(.issueReporting), .suppress(.all): true
                            default: false
                        }
                    }
                    if suppressIssueReporting == false {
                        deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                    }
                }
            }
        }

        let commandGen = Spec.commandGenerator
        let (sequenceGenerator, commandLimit) = makeCommandSequence(commandGen: commandGen, context: context)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let identifySkips = Spec.skipIdentifier(specInit: specInit)

        let property: @Sendable ([Spec.Command]) -> Bool = { commands in
            __ExhaustRuntime._blockingAwaitSemaphore(timeoutMilliseconds: nil) {
                let spec = specInit()
                for command in commands {
                    do {
                        try await spec.run(command)
                        try await spec.checkInvariants()
                    } catch is ContractSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                return true
            }!
        }

        guard let (result, rendered) = runSequentialContract(
            specType,
            commandGen: commandGen,
            sequenceGenerator: sequenceGenerator,
            commandLimit: commandLimit,
            context: &context,
            property: property,
            identifySkips: identifySkips,
            finalize: { commands in
                // `DiagnosticSnapshot` is `@unchecked Sendable`, so returning it (rather than the bare non-Sendable SUT) crosses the blocking-await boundary without an unsafe escape hatch. The SUT is unpacked here, back on the calling thread.
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
        ) else {
            return (nil, deferredIssues)
        }

        if let rendered {
            deferredIssues.append(rendered)
        }

        return (result, deferredIssues)
    }
}

// MARK: - Shared Sequential Pipeline

private extension __ExhaustRuntime {
    /// Builds the command-sequence generator and resolves the command limit shared by the sync and async sequential runners.
    ///
    /// The sequence uses 0 as its lower length bound so the reducer can shrink sequences below the user's requested minimum. The minimum is a generation hint, not a reduction floor.
    static func makeCommandSequence<Command>(
        commandGen: ReflectiveGenerator<Command>,
        context: ContractContext
    ) -> (sequenceGenerator: Generator<[Command]>, commandLimit: Int) {
        let commandLimit = context.commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            coverageBudget: context.coverageBudget
        )
        let sequenceGenerator = commandGen.array(
            length: 0 ... commandLimit,
            scaling: .constant
        ).gen
        return (sequenceGenerator, commandLimit)
    }

    /// Runs the coverage-and-sampling discovery phase and assembles the failing ``ContractResult`` and its rendered report.
    ///
    /// Shared by the synchronous and asynchronous sequential runners. They differ only in how commands execute (directly versus bridged through ``blockingAwait(_:)``) and how failure state is captured, both supplied through closures. Returns `nil` when every sequence passes.
    ///
    /// - Parameter finalize: Re-executes the discovered sequence to produce the trace, SUT snapshot, and failure description used in the result and failure report.
    static func runSequentialContract<Spec: ContractSpecBase>(
        _: Spec.Type,
        commandGen: ReflectiveGenerator<Spec.Command>,
        sequenceGenerator: Generator<[Spec.Command]>,
        commandLimit: Int,
        context: inout ContractContext,
        property: @escaping @Sendable ([Spec.Command]) -> Bool,
        identifySkips: @escaping @Sendable ([Spec.Command]) -> Set<Int>,
        finalize: ([Spec.Command]) -> (trace: [TraceStep], systemUnderTest: Spec.SystemUnderTest, failureDescription: String)
    ) -> (result: ContractResult<Spec>, rendered: String?)? {
        guard let discovery = runCoverageAndSampling(
            commandGen: commandGen,
            commandLimit: commandLimit,
            sequenceGenerator: sequenceGenerator,
            property: property,
            identifySkips: identifySkips,
            context: &context
        ) else {
            return nil
        }

        let outcome = finalize(discovery.commands)
        let result = ContractResult<Spec>(
            commands: discovery.commands,
            trace: outcome.trace,
            systemUnderTest: outcome.systemUnderTest,
            seed: context.seed,
            replaySeed: discovery.replaySeed ?? context.encodedReplaySeed,
            discoveryMethod: discovery.failureInfo.discoveryMethod
        )

        let rendered: String? = context.suppressIssueReporting
            ? nil
            : renderFailure(
                result,
                failureInfo: discovery.failureInfo,
                failureDescription: outcome.failureDescription,
                includeDiff: context.includeDiff
            )
        return (result, rendered)
    }
}

// MARK: - Coverage and Sampling

private extension __ExhaustRuntime {
    /// Carries the failing command sequence, failure metadata, and replay seed from the coverage or sampling phase back to the entry point for result assembly and issue reporting.
    struct ContractDiscovery<Command> {
        let commands: [Command]
        let failureInfo: ContractFailureInfo<Command>
        let replaySeed: String?
    }

    /// Runs the SCA coverage phase followed by random sampling, returning a ``ContractDiscovery`` on the first failure or nil when the full budget passes.
    static func runCoverageAndSampling<Command>(
        commandGen: ReflectiveGenerator<Command>,
        commandLimit: Int,
        sequenceGenerator: Generator<[Command]>,
        property: @escaping @Sendable ([Command]) -> Bool,
        identifySkips: @escaping @Sendable ([Command]) -> Set<Int>,
        context: inout ContractContext
    ) -> ContractDiscovery<Command>? {
        let pipelineStopwatch = Stopwatch()
        let scaOutcome = runContractCoverage(
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            sequenceGenerator: sequenceGenerator,
            property: property,
            identifySkips: identifySkips,
            context: context
        )

        switch scaOutcome {
            case let .failure(commands, original, coverageInvocations, reductionStats, reductionInvocations, reductionMilliseconds):
                if let onReport = context.onReportClosure {
                    var report = ExhaustReport()
                    report.seed = context.seed
                    report.setInvocations(
                        coverage: coverageInvocations,
                        randomSampling: 0,
                        reduction: reductionInvocations
                    )
                    report.reductionMilliseconds = reductionMilliseconds
                    if let reductionStats {
                        report.applyReductionStats(reductionStats)
                    }
                    report.totalMilliseconds = pipelineStopwatch.elapsedMilliseconds
                    onReport(report)
                }
                return ContractDiscovery(
                    commands: commands,
                    failureInfo: ContractFailureInfo(originalCommands: original, discoveryMethod: .coverage),
                    replaySeed: ReplaySeed.Resolved.encodeCoverageIteration(coverageInvocations)
                )

            case .completed, .skipped:
                guard context.coverageReplayRow == nil else {
                    return nil
                }
                return runContractSampling(
                    scaOutcome: scaOutcome,
                    sequenceGenerator: sequenceGenerator,
                    property: property,
                    context: &context
                )
        }
    }

    /// Dispatches to the SCA coverage pipeline, handling replay-row targeting and budget-zero / deterministic-replay skip conditions.
    static func runContractCoverage<Command>(
        commandGen: Generator<Command>,
        commandLimit: Int,
        sequenceGenerator: Generator<[Command]>,
        property: @escaping @Sendable ([Command]) -> Bool,
        identifySkips: @escaping @Sendable ([Command]) -> Set<Int>,
        context: ContractContext
    ) -> SCAOutcome<Command> {
        if context.coverageReplayRow != nil {
            return runSCACoverage(
                sequenceGen: sequenceGenerator,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: context.coverageBudget,
                skipToRow: context.coverageReplayRow,
                property: property,
                identifySkips: identifySkips
            )
        }
        if context.coverageBudget == 0 {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (zero coverage budget)"
            )
            return .skipped
        }
        if context.isSamplingReplay {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (deterministic replay)"
            )
            return .skipped
        }
        return runSCACoverage(
            sequenceGen: sequenceGenerator,
            commandGen: commandGen,
            commandLimit: commandLimit,
            coverageBudget: context.coverageBudget,
            property: property,
            identifySkips: identifySkips
        )
    }

    /// Runs random sampling via ``__ExhaustRuntime/__exhaustBody(gen:settings:reflecting:fileID:filePath:line:column:testName:property:)``, folding in any coverage invocations from the prior phase for accurate reporting.
    static func runContractSampling<Command>(
        scaOutcome: SCAOutcome<Command>,
        sequenceGenerator: Generator<[Command]>,
        property: @escaping @Sendable ([Command]) -> Bool,
        context: inout ContractContext
    ) -> ContractDiscovery<Command>? {
        let scaCoverageInvocations: Int = switch scaOutcome {
            case let .completed(count): count
            default: 0
        }

        context.ensureSeed()
        let capturedSeed = context.seed
        let samplingSettings = context.propertySettings(
            samplingBudget: context.samplingReplayIteration != nil ? 1 : context.samplingBudget,
            coverageBudget: scaOutcome.isCompleted ? UInt64(0) : context.coverageBudget,
            onReport: context.onReportClosure.map { closure in
                { report in
                    var report = report
                    report.seed = capturedSeed
                    report.coverageInvocations += scaCoverageInvocations
                    report.propertyInvocations += scaCoverageInvocations
                    closure(report)
                }
            }
        )
        let (counterexample, innerReplaySeed) = __ExhaustRuntime.__exhaustBody(
            gen: sequenceGenerator,
            settings: samplingSettings,
            reflecting: nil,
            fileID: context.fileID,
            filePath: context.filePath,
            line: context.line,
            column: context.column,
            testName: "\(context.fileID)",
            property: property
        )

        guard let counterexample else {
            return nil
        }
        return ContractDiscovery(
            commands: counterexample,
            failureInfo: ContractFailureInfo(
                originalCommands: nil,
                discoveryMethod: context.isSamplingReplay ? .replay : .randomSampling
            ),
            replaySeed: innerReplaySeed
        )
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
        context: ContractContext
    ) -> ContractResult<Spec>? {
        #if canImport(Testing)
            // An explicit `.replay` takes precedence over the regression trait. This guard also stops the per-seed `__runContract` replay below from re-entering the regression pass.
            guard context.isSamplingReplay == false, context.isCoverageReplay == false else {
                return nil
            }
            guard let traitConfig = ExhaustTraitConfiguration.current,
                  traitConfig.regressions.isEmpty == false
            else {
                return nil
            }

            for encodedSeed in traitConfig.regressions {
                guard ReplaySeed.Resolved.decode(encodedSeed) != nil else {
                    reportIssue(
                        "Invalid regression seed: \(encodedSeed)",
                        fileID: context.fileID,
                        filePath: context.filePath,
                        line: context.line,
                        column: context.column
                    )
                    continue
                }
                if let result = __runContract(
                    specType,
                    settings: [.replay(.encoded(encodedSeed))] + settings,
                    fileID: context.fileID,
                    filePath: context.filePath,
                    line: context.line,
                    column: context.column
                ) {
                    return result
                } else if context.suppressIssueReporting == false {
                    reportIssue(
                        "Regression seed \"\(encodedSeed)\" now passes. Consider removing it.",
                        fileID: context.fileID,
                        filePath: context.filePath,
                        line: context.line,
                        column: context.column
                    )
                }
            }
            return nil
        #else
            return nil
        #endif
    }
}

// MARK: - Trace Building

private extension __ExhaustRuntime {
    /// Re-executes the failing command sequence to build a step-by-step trace.
    ///
    /// Returns the trace and the spec instance in the state it was in when the failure occurred (or after running all commands if the sequence passes on re-execution).
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
