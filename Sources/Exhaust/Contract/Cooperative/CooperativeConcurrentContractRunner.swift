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
                if case let .concurrent(level) = setting { return level.rawValue }
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

        let config: ResolvedConcurrentConfig
        switch ResolvedConcurrentConfig.parse(settings) {
            case let .success(resolved):
                config = resolved
            case let .invalidReplaySeed(seed):
                reportIssue(
                    "Invalid replay seed: \(seed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return nil
        }

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
                    case let .sampling(seed, iteration):
                        replayConfig.seed = seed
                        replayConfig.replayIteration = iteration
                }

                let runContext = ContractRunContext<Spec>(
                    config: replayConfig,
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
                    config: replayConfig,
                    sequenceGen: sequenceGen,
                    commandGen: commandGen,
                    commandLimit: resolvedCommandLimit,
                    concurrencyLevel: concurrencyLevel,
                    taggedCommandGen: taggedCommandGen,
                    property: property
                )

                var machine = ContractMachine(backend: backend, context: runContext, sources: sources)
                if let result = machine.run() {
                    deferredIssues.append(contentsOf: runContext.deferredIssues)
                    return (result, deferredIssues)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        let runContext = ContractRunContext<Spec>(
            config: config,
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

        nonisolated(unsafe) let unsafeSpecInit = specInit
        var smokeProperty: (@Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool)?
        if concurrencyLevel > 1 {
            smokeProperty = { tagged in
                let passed = __ExhaustRuntime._blockingAwaitSemaphore(timeoutMilliseconds: nil) {
                    let spec = unsafeSpecInit()
                    for (_, command) in tagged {
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
                }
                return passed ?? false
            }
        }

        let sources = buildConcurrentSources(
            config: config,
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
        deferredIssues.append(contentsOf: runContext.deferredIssues)
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

// MARK: - Legacy Pipeline (to be removed)

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    /// Executes the full concurrent contract pipeline: regression replay, SCA coverage, random sampling with reduction. Runs on a GCD thread; the caller handles ``dispatchToGCD(_:)`` and deferred issue reporting.
    static func runConcurrentPipeline<Spec: AsyncContractSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        fileID: StaticString
    ) -> (result: ContractResult<Spec>?, deferredIssues: [String]) {
        let runStopwatch = Stopwatch()
        nonisolated(unsafe) var report = ExhaustReport()
        nonisolated(unsafe) var coverageSnapshot = 0
        nonisolated(unsafe) var reductionInvocations = 0
        nonisolated(unsafe) var discoveredDuringCoverage = false
        var deferredIssues: [String] = []
        let statsAccumulator: OpenPBTStatsAccumulator? = config.collectOpenPBTStats
            ? OpenPBTStatsAccumulator(propertyName: "\(fileID)")
            : nil

        var failureContext = FailureContext()
        failureContext.specName = "\(Spec.self)"

        var config = config
        if config.concurrencyLevel > 1, Spec.self is any Actor.Type {
            config.concurrencyLevel = 1
        }

        let commandGen = Spec.commandGenerator.gen
        let samplingBudget = config.budget.samplingBudget
        let coverageBudget = config.budget.coverageBudget
        let resolvedCommandLimit = config.commandLimit
            ?? min(estimateCommandLimit(commandGen: commandGen, coverageBudget: coverageBudget), 40)
        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            return (nil as ContractResult<Spec>?, deferredIssues)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )
        let reductionConfig = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: UInt64(samplingBudget) * 5 * 1_000_000
        )

        // Safe: metatypes are stateless.
        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        let concurrencyLevel = config.concurrencyLevel
        let idleTimeout = config.idleTimeout
        let rawIdentifySkips = Spec.skipIdentifier(
            specInit: specInit,
            idleTimeoutMilliseconds: idleTimeout
        )
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
            rawIdentifySkips(taggedCommands.map(\.1))
        }
        // Single-threaded: the reducer and SCA row loop call the property sequentially on the pipeline GCD thread.
        let lastRunTimedOut = UnsafeSendableBox(false)
        let invocationCounter = UnsafeSendableBox(0)
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

        defer {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
            report.setConcurrentInvocations(
                totalInvocations: invocationCounter.value,
                coverageThroughReduction: coverageSnapshot,
                reduction: reductionInvocations,
                discoveredDuringCoverage: discoveredDuringCoverage
            )
            report.seed = config.seed
            if let statsAccumulator {
                let lines = statsAccumulator.finalize()
                if lines.isEmpty == false {
                    report.openPBTStatsLines = lines
                }
            }
            config.onReportClosure?(report)
        }

        /// Builds the final result and deferred issue from a discovery, recording reduction stats. Shared by the regression-replay short-circuit and the normal coverage/sampling path so both account identically.
        func finishDiscovery(_ discovery: ConcurrentDiscovery<Spec.Command>) -> (result: ContractResult<Spec>?, deferredIssues: [String]) {
            if let stats = discovery.reductionStats {
                report.applyReductionStats(stats)
            }
            reductionInvocations = discovery.reductionInvocations
            discoveredDuringCoverage = discovery.discoveryMethod == .coverage
            report.reductionMilliseconds = discovery.reductionMilliseconds

            var discoveryContext = failureContext
            discoveryContext.seed = discovery.seed
            discoveryContext.originalCount = discovery.originalCount
            discoveryContext.iteration = discovery.iteration
            discoveryContext.budget = discovery.budget
            discoveryContext.sequencesTested = discovery.sequencesTested
            let failure = buildFailureResult(
                finalInput: discovery.taggedCommands,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                idleTimeout: idleTimeout,
                seed: discovery.seed,
                discoveryMethod: discovery.discoveryMethod,
                timedOut: discovery.timedOut,
                failureContext: &discoveryContext
            )
            if config.suppressIssueReporting == false {
                deferredIssues.append(failure.issueMessage)
            }
            return (failure.result, deferredIssues)
        }

        // Regression seeds: replay each through the same coverage/sampling machinery as an inline `.replay`, so the printed `U…` (coverage) and `…-N` (sampling) formats round-trip and the failing run is re-materialised at its true position. An explicit `.replay` takes precedence and skips this pass.
        if config.coverageReplayRow == nil, config.seed == nil {
            for encodedSeed in regressionSeeds {
                guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                var regressionDiscovery: ConcurrentDiscovery<Spec.Command>?
                if case let .coverage(row: coverageRow) = decoded {
                    if let scaResult = runConcurrentSCACoverage(
                        sequenceGen: sequenceGen,
                        commandGen: commandGen,
                        commandLimit: resolvedCommandLimit,
                        coverageBudget: max(coverageBudget, UInt64(coverageRow) + 1),
                        concurrencyLevel: config.concurrencyLevel,
                        skipToRow: coverageRow,
                        sequenceGenForLength: { range in Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant) },
                        property: property,
                        identifySkips: identifySkips,
                        lastRunTimedOut: lastRunTimedOut,
                        invocationCounter: invocationCounter
                    ) {
                        regressionDiscovery = ConcurrentDiscovery(
                            scaResult: scaResult,
                            coverageBudget: coverageBudget,
                            sequencesTested: invocationCounter.value
                        )
                    }
                } else if case let .sampling(seed, iteration) = decoded {
                    do {
                        regressionDiscovery = try runConcurrentSampling(
                            sequenceGen: sequenceGen,
                            reductionConfig: reductionConfig,
                            property: property,
                            identifySkips: identifySkips,
                            lastRunTimedOut: lastRunTimedOut,
                            invocationCounter: invocationCounter,
                            seed: seed,
                            replayIteration: iteration,
                            samplingBudget: samplingBudget,

                            statsAccumulator: statsAccumulator
                        )
                    } catch {
                        deferredIssues.append("Generator failed during regression replay (seed \(encodedSeed)): \(error)")
                        continue
                    }
                }

                if let regressionDiscovery {
                    return finishDiscovery(regressionDiscovery)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        // Ordered coverage
        let coverageStopwatch = Stopwatch()
        var discovery: ConcurrentDiscovery<Spec.Command>?

        if config.shouldRunCoverage {
            let effectiveCoverageBudget: UInt64 = if let row = config.coverageReplayRow {
                max(coverageBudget, UInt64(row) + 1)
            } else {
                coverageBudget
            }
            if let scaResult = runConcurrentSCACoverage(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: resolvedCommandLimit,
                coverageBudget: effectiveCoverageBudget,
                concurrencyLevel: config.concurrencyLevel,
                skipToRow: config.coverageReplayRow,
                sequenceGenForLength: { range in Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant) },
                property: property,
                identifySkips: identifySkips,
                lastRunTimedOut: lastRunTimedOut,
                invocationCounter: invocationCounter
            ) {
                discovery = ConcurrentDiscovery(
                    scaResult: scaResult,
                    coverageBudget: coverageBudget,
                    sequencesTested: invocationCounter.value
                )
            }
        }

        coverageSnapshot = invocationCounter.value
        report.coverageMilliseconds = coverageStopwatch.elapsedMilliseconds

        // Random sampling
        if discovery == nil, config.coverageReplayRow == nil {
            do {
                discovery = try runConcurrentSampling(
                    sequenceGen: sequenceGen,
                    reductionConfig: reductionConfig,
                    property: property,
                    identifySkips: identifySkips,
                    lastRunTimedOut: lastRunTimedOut,
                    invocationCounter: invocationCounter,
                    seed: config.seed,
                    replayIteration: config.replayIteration,
                    samplingBudget: samplingBudget,
                    statsAccumulator: statsAccumulator
                )
            } catch {
                deferredIssues.append("Concurrent contract runner error: \(error)")
                return (nil as ContractResult<Spec>?, deferredIssues)
            }
        }

        guard let discovery else {
            return (nil as ContractResult<Spec>?, deferredIssues)
        }
        return finishDiscovery(discovery)
    }
}

// MARK: - Sampling

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    /// Iterates random tagged command sequences, invoking the property on each. On failure, delegates to ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:timedOut:)`` and returns a ``ConcurrentDiscovery``. Returns nil when the full sampling budget passes.
    static func runConcurrentSampling<Command: CustomStringConvertible>(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        reductionConfig: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        lastRunTimedOut: UnsafeSendableBox<Bool>,
        invocationCounter: UnsafeSendableBox<Int>,
        seed: UInt64?,
        replayIteration: Int?,
        samplingBudget: UInt64,
        statsAccumulator: OpenPBTStatsAccumulator?
    ) throws -> ConcurrentDiscovery<Command>? {
        let (startIndex, maxRuns) = samplingReplayWindow(
            replayIteration: replayIteration,
            samplingBudget: samplingBudget
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            sequenceGen,
            materializePicks: statsAccumulator != nil,
            seed: seed,
            maxRuns: maxRuns,
            initialRunIndex: startIndex
        )
        let actualSeed = interpreter.baseSeed

        var samplingIteration = 0

        if let statsAccumulator {
            while let (input, tree) = try interpreter.next() {
                samplingIteration += 1
                let absoluteIteration = Int(startIndex) + samplingIteration
                let passed = property(input)
                statsAccumulator.record(
                    representation: "\(input.map { "[\($0.0)] \($0.1)" })",
                    passed: passed,
                    tree: tree,
                    phase: .random
                )

                if passed == false {
                    return try buildSamplingDiscovery(
                        input: input,
                        tree: tree,
                        absoluteIteration: absoluteIteration,
                        actualSeed: actualSeed,
                        sequenceGen: sequenceGen,
                        reductionConfig: reductionConfig,
                        property: property,
                        identifySkips: identifySkips,
                        lastRunTimedOut: lastRunTimedOut,
                        invocationCounter: invocationCounter,
                        replayIteration: replayIteration,
                        samplingBudget: samplingBudget
                    )
                }
            }
        } else {
            while let input = try interpreter.nextValueOnly() {
                samplingIteration += 1
                if property(input) == false {
                    let tree = try interpreter.reproduceFailureTree()
                    let absoluteIteration = Int(startIndex) + samplingIteration
                    return try buildSamplingDiscovery(
                        input: input,
                        tree: tree,
                        absoluteIteration: absoluteIteration,
                        actualSeed: actualSeed,
                        sequenceGen: sequenceGen,
                        reductionConfig: reductionConfig,
                        property: property,
                        identifySkips: identifySkips,
                        lastRunTimedOut: lastRunTimedOut,
                        invocationCounter: invocationCounter,
                        replayIteration: replayIteration,
                        samplingBudget: samplingBudget
                    )
                }
            }
        }

        return nil
    }

    /// Builds a ``ConcurrentDiscovery`` from a failing command sequence by pruning skipped commands and reducing the counterexample.
    static func buildSamplingDiscovery<Command: CustomStringConvertible>(
        input: [(ScheduleMarker, Command)],
        tree: ChoiceTree,
        absoluteIteration: Int,
        actualSeed: UInt64,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        reductionConfig: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        lastRunTimedOut: UnsafeSendableBox<Bool>,
        invocationCounter: UnsafeSendableBox<Int>,
        replayIteration: Int?,
        samplingBudget: UInt64
    ) throws -> ConcurrentDiscovery<Command> {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_failure_found",
            metadata: ["commands": "\(input.count)", "timedOut": "\(lastRunTimedOut.value)"]
        )

        let reductionStartInvocations = invocationCounter.value
        let reductionStopwatch = Stopwatch()
        let reductionProperty: @Sendable ([(ScheduleMarker, Command)]) -> Bool = { taggedCommands in
            let passed = property(taggedCommands)
            return passed || lastRunTimedOut.value
        }
        let reduction = reduceConcurrentCounterexample(
            input: input,
            tree: tree,
            sequenceGen: sequenceGen,
            reductionConfig: reductionConfig,
            property: reductionProperty,
            identifySkips: identifySkips,
            seed: 0,
            skipPruningLogEvent: "concurrent_skip_pruning",
            timedOut: lastRunTimedOut.value
        )
        let reductionMilliseconds = reductionStopwatch.elapsedMilliseconds
        let reductionInvocations = invocationCounter.value - reductionStartInvocations

        let discoveryMethod: ContractDiscoveryMethod = replayIteration != nil ? .replay : .randomSampling
        return ConcurrentDiscovery(
            taggedCommands: reduction.finalInput,
            discoveryMethod: discoveryMethod,
            timedOut: reduction.timedOut,
            seed: actualSeed,
            originalCount: input.count,
            iteration: absoluteIteration,
            budget: samplingBudget,
            sequencesTested: invocationCounter.value,
            reductionStats: reduction.stats,
            reductionInvocations: reductionInvocations,
            reductionMilliseconds: reductionMilliseconds
        )
    }
}

// MARK: - Failure Result Assembly

// reportIssue must be called from the Swift Testing async context, not the GCD thread where this function executes. Swift Testing's task-locals are not available on GCD threads, so the caller must collect the rendered message and report it after awaiting dispatchToGCD.

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    /// Assembles the final ``ContractResult`` for a concurrent contract failure.
    ///
    /// Re-drains the failing schedule with trace recording enabled, runs a sequential oracle to capture the expected (race-free) SUT state, and renders the failure report. Returns both the result and the rendered failure message for the caller to report.
    static func buildFailureResult<Spec: AsyncContractSpec>(
        finalInput: [(ScheduleMarker, Spec.Command)],
        specInit: @escaping () -> Spec,
        concurrencyLevel: Int,
        idleTimeout: Int,
        seed: UInt64?,
        discoveryMethod: ContractDiscoveryMethod,
        timedOut: Bool,
        failureContext: inout FailureContext
    ) -> (result: ContractResult<Spec>, issueMessage: String) {
        let traceResult = drainSchedule(
            taggedCommands: finalInput,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            recordTrace: true,
            idleTimeoutMilliseconds: idleTimeout
        )
        let trace = traceResult.trace

        // Run the commands sequentially on a fresh spec. If the sequential replay passes, the resulting state is the expected outcome, what the system should have produced without the race.
        let oracle = timedOut ? nil : sequentialOracle(commands: finalInput.map(\.1), specInit: specInit, idleTimeoutMilliseconds: idleTimeout)

        let replaySeed: String?
        if let seed {
            replaySeed = ReplaySeed.Resolved.sampling(seed: seed, iteration: failureContext.iteration).encoded
        } else if discoveryMethod == .coverage || discoveryMethod == .smokeTest {
            replaySeed = ReplaySeed.Resolved.encodeCoverageIteration(failureContext.iteration)
        } else {
            replaySeed = nil
        }

        let result = ContractResult<Spec>(
            status: timedOut ? .timeout : .fail,
            commands: finalInput.map(\.1),
            originalCommands: nil,
            trace: trace,
            systemUnderTest: oracle?.systemUnderTest,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        failureContext.discoveryMethod = discoveryMethod
        failureContext.replaySeed = replaySeed
        failureContext.timedOut = timedOut
        failureContext.oracleDescription = oracle.flatMap { oracle in
            guard let description = oracle.failureDescription else { return nil }
            let indented = description.replacingOccurrences(of: "\n", with: "\n  ")
            return "Expected result (from sequential replay):\n  \(indented)"
        }
        failureContext.failureDescription = oracle?.failureDescription
        let message = renderFailure(finalInput, trace: trace, context: failureContext)

        return (result, message)
    }
}

// MARK: - Supporting Types

extension __ExhaustRuntime {
    /// Carries the failure metadata from the coverage or sampling phase back to the entry point, which uses it to populate ``FailureContext``, call ``buildFailureResult(finalInput:specInit:concurrencyLevel:idleTimeout:seed:discoveryMethod:timedOut:failureContext:)``, and update the ``ExhaustReport``.
    struct ConcurrentDiscovery<Command> {
        let taggedCommands: [(ScheduleMarker, Command)]
        let discoveryMethod: ContractDiscoveryMethod
        let timedOut: Bool
        let seed: UInt64?
        let originalCount: Int
        let iteration: Int
        let budget: UInt64
        let sequencesTested: Int
        let reductionStats: ReductionStats?
        let reductionInvocations: Int
        let reductionMilliseconds: Double
    }
}
