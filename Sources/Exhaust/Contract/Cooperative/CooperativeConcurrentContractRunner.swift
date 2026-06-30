// Cooperative concurrent contract runner.
//
// Based on Claessen, Palka, Smallbone, Hughes, Svensson, Arts, and Wiger, "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work combines QuickCheck's eqc_par_statem with a user-level scheduler (PULSE) that records and replays Erlang process schedules for deterministic concurrency testing.
//
// This implementation adapts the approach to Swift Concurrency:
// - Schedule markers encoded as reducible chooseBits replace PULSE's external schedule.
// - A cooperative TaskExecutor-based drain loop replaces the Erlang VM instrumentation.
// - The schedule is part of the generated input (not an external random choice), so reduction operates on schedule and commands jointly. No separate ?ALWAYS(N, Prop) wrapper is needed for reduction stability.
import ExhaustCore
import IssueReporting

// MARK: - Async Dispatch

public extension __ExhaustRuntime {
    /// Dispatches an asynchronous contract test to the appropriate runner based on the contract's ``ExecutionModel``.
    @discardableResult
    static func __runContractDispatchAsync<Spec: AsyncContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> ContractResult<Spec>? {
        switch Spec.executionModel {
            case .sequential:
                return await __runContractAsync(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .tasks:
                guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
                    reportIssue(
                        "@Contract(.tasks) requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    return nil
                }
                return await __runContractConcurrent(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .threads:
                return await __runPreemptiveConcurrentContractAsync(
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

// MARK: - Runner Entry Point

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
public extension __ExhaustRuntime {
    /// Runs a `.tasks` concurrent contract property test for the given async contract type.
    ///
    /// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``drainSchedule(taggedCommands:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer reduces both the command sequence and the lane assignments.
    ///
    /// The same seed always produces the same command ordering and lane assignment. Commands with multiple internal suspension points may exhaust the encoded schedule, falling back to deterministic round-robin for remaining continuations.
    @discardableResult
    static func __runContractConcurrent<Spec: AsyncContractSpec>(
        _: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> ContractResult<Spec>? {
        if Spec.self is any Actor.Type {
            let requestedLevel = settings.compactMap { setting -> Int? in
                if case let .concurrent(level) = setting {
                    return level.rawValue
                }
                return nil
            }.last
            if let requestedLevel, requestedLevel > 1 {
                reportIssue(
                    "Actor isolation serializes all command dispatch. .concurrent(\(requestedLevel)) will be ignored.",
                    severity: .warning,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        }

        let parsed = ResolvedConcurrentConfig.parse(settings)
        if let invalidSeed = parsed.invalidReplaySeed {
            reportIssue(
                "Invalid replay seed: \(invalidSeed)",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return nil
        }
        let config = parsed.config

        // The trait-budget fallback is applied in `ResolvedConcurrentConfig.parse`, so `config.budget` already reflects a suite-level `.budget` trait here.
        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        // The drain loop inside drainSchedule calls runSynchronously in a tight polling loop on whatever thread hosts it. When that thread belongs to the cooperative pool, parallel test suites each occupy a cooperative thread with a spin-wait, starving the pool and preventing the Swift runtime from scheduling the Task continuations that feed the drain loop. This deadlocks under parallel execution on machines with few cores. Dispatching the entire pipeline to a GCD thread moves all drain loops off the cooperative pool. GCD grows its thread pool dynamically, so concurrent drain loops cannot exhaust it.
        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runCooperativeMachine(
                    Spec.self,
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
            reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}

// MARK: - Machine Pipeline

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    static func runCooperativeMachine<Spec: AsyncContractSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: ContractResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []
        var config = config

        if config.concurrencyLevel > 1, Spec.self is any Actor.Type {
            config.concurrencyLevel = 1
        }

        let commandGen = Spec.commandGenerator.gen
        let coverageBudget = config.budget.coverageBudget
        let resolvedCommandLimit = config.commandLimit
            ?? min(estimateCommandLimit(commandGen: commandGen, coverageBudget: coverageBudget), 40)

        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            return (nil, deferredIssues)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let concurrencyLevel = config.concurrencyLevel
        let idleTimeout = config.idleTimeout

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit, idleTimeoutMilliseconds: idleTimeout)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
            rawIdentifySkips(taggedCommands.map(\.1))
        }

        let backend = CooperativeContractBackend<Spec>(
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeout: idleTimeout
        )

        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let result = drainSchedule(
                taggedCommands: taggedCommands,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeout
            )
            if result.timedOut {
                lastRunTimedOut.value = true
            }
            return result.passed
        }

        func runMachine(
            config machineConfig: ResolvedConcurrentConfig,
            smokeProperty: (@Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool)? = nil
        ) -> (result: ContractResult<Spec>?, issues: [String]) {
            let runContext = ContractRunContext<Spec>(
                config: machineConfig,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: resolvedCommandLimit,
                identifySkips: identifySkips,
                invocationCounter: invocationCounter,
                lastRunTimedOut: lastRunTimedOut,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            let sources = buildConcurrentSources(
                config: machineConfig,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: resolvedCommandLimit,
                concurrencyLevel: concurrencyLevel,
                taggedCommandGen: taggedCommandGen,
                property: property,
                smokeProperty: smokeProperty
            )

            var machine = ContractMachine(backend: backend, context: runContext, sources: sources)
            let result = machine.run()
            return (result, runContext.deferredIssues)
        }

        // Regression seeds
        if config.coverageReplayRow == nil, config.seed == nil {
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

                let (result, issues) = runMachine(config: replayConfig)
                deferredIssues.append(contentsOf: issues)
                if let result {
                    return (result, deferredIssues)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        var smokeProperty: (@Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool)?
        if concurrencyLevel > 1 {
            smokeProperty = asyncSequentialProperty(specInit: specInit)
        }

        let (result, issues) = runMachine(config: config, smokeProperty: smokeProperty)
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }

    static func buildConcurrentSources<Command: CustomStringConvertible>(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        concurrencyLevel: Int,
        taggedCommandGen: Generator<(ScheduleMarker, Command)>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        smokeProperty: (@Sendable ([(ScheduleMarker, Command)]) -> Bool)? = nil
    ) -> [AnyContractCandidateSource<Command>] {
        var sources: [AnyContractCandidateSource<Command>] = []

        if let row = config.coverageReplayRow {
            sources.append(.coverageReplay(
                row: row,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: max(config.budget.coverageBudget, UInt64(row) + 1),
                concurrencyLevel: concurrencyLevel,
                property: property
            ))
        }

        if let replayIteration = config.replayIteration, let seed = config.seed {
            sources.append(.samplingReplay(
                replaySeed: seed,
                replayIteration: replayIteration,
                sequenceGen: sequenceGen,
                property: property
            ))
        }

        if let smokeProperty {
            sources.append(.smoke(sequenceGen: sequenceGen, property: smokeProperty))
        }

        if config.shouldRunCoverage {
            sources.append(.coverage(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: config.budget.coverageBudget,
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: { range in
                    Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant)
                },
                property: property
            ))
        }

        if config.replayIteration == nil, config.coverageReplayRow == nil {
            let seed = config.seed ?? Xoshiro256().seed
            sources.append(.sampling(
                sequenceGen: sequenceGen,
                seed: seed,
                samplingBudget: config.budget.samplingBudget,
                property: property
            ))
        }

        return sources
    }
}
