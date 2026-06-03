// Cooperative concurrent contract runner.
//
// Based on Claessen, Palka, Smallbone, Hughes, Svensson, Arts, and Wiger, "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work combines QuickCheck's eqc_par_statem with a user-level scheduler (PULSE) that records and replays Erlang process schedules for deterministic concurrency testing.
//
// This implementation adapts the approach to Swift Concurrency:
// - Schedule markers encoded as reducible chooseBits replace PULSE's external schedule.
// - A cooperative TaskExecutor-based drain loop replaces the Erlang VM instrumentation.
// - The schedule is part of the generated input (not an external random choice), so reduction operates on schedule and commands jointly — no separate ?ALWAYS(N, Prop) wrapper is needed for reduction stability.
import ExhaustCore
import IssueReporting

// MARK: - Runner Entry Point

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
public extension __ExhaustRuntime {
    /// Runs a concurrent contract property test for the given async specification type.
    ///
    /// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``drainSchedule(taggedCommands:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer reduces both the command sequence and the lane assignments.
    ///
    /// The same seed always produces the same command ordering and lane assignment. Commands with multiple internal suspension points may exhaust the encoded schedule, falling back to deterministic round-robin for remaining continuations.
    @discardableResult
    static func __runContractConcurrent<Spec: AsyncContractSpec>(
        _: Spec.Type,
        settings: [ConcurrentContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> ContractResult<Spec>? {
        if Spec.self is any Actor.Type {
            let requestedLevel = settings.compactMap { setting -> Int? in
                if case let .concurrent(level) = setting { return level }
                return nil
            }.last
            if let requestedLevel, requestedLevel > 1 {
                reportIssue(
                    "Actor isolation serialises all command dispatch. .concurrent(\(requestedLevel)) will be ignored.",
                    severity: .warning,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        }

        var config: ResolvedConcurrentConfig
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
            case let .invalidConcurrencyLevel(level):
                reportIssue(
                    "concurrencyLevel must be between 1 and 8, but was \(level)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return nil
        }

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            let traitConfig = ExhaustTraitConfiguration.current
            regressionSeeds = traitConfig?.regressions ?? []
            if let traitConfig {
                let hasInlineBudget = settings.contains {
                    switch $0 {
                        case .budget: true
                        default: false
                    }
                }
                if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                    config.budget = traitBudget
                }
            }
        #endif

        // The drain loop inside drainSchedule calls runSynchronously in a tight polling loop on whatever thread hosts it. When that thread belongs to the cooperative pool, parallel test suites each occupy a cooperative thread with a spin-wait, starving the pool and preventing the Swift runtime from scheduling the Task continuations that feed the drain loop — a deadlock under parallel execution on machines with few cores. Dispatching the entire pipeline to a GCD thread moves all drain loops off the cooperative pool. GCD grows its thread pool dynamically, so concurrent drain loops cannot exhaust it.
        let logConfiguration = ExhaustLog.Configuration(
            isEnabled: config.suppressLogs == false,
            minimumLevel: config.logLevel,
            format: config.logFormat
        )

        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD {
            ExhaustLog.withConfiguration(logConfiguration) {
                runConcurrentPipeline(
                    Spec.self,
                    config: config,
                    regressionSeeds: regressionSeeds,
                    fileID: fileID
                )
            }
        }
        for issue in deferredIssues {
            reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}

// MARK: - Pipeline

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    /// Executes the full concurrent contract pipeline: regression replay, SCA coverage, random sampling with reduction. Runs on a GCD thread — the caller handles ``dispatchToGCD(_:)`` and deferred issue reporting.
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
        let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
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

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
            rawIdentifySkips(taggedCommands.map(\.1))
        }
        let concurrencyLevel = config.concurrencyLevel
        let idleTimeout = config.idleTimeout
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
            lastRunTimedOut.value = result.timedOut
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

        // Regression seeds
        if let regression = runConcurrentRegressionSeeds(
            regressionSeeds: regressionSeeds,
            sequenceGen: sequenceGen,
            property: property,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeout: idleTimeout,
            failureContext: failureContext,
            suppressIssueReporting: config.suppressIssueReporting
        ) as (result: ContractResult<Spec>, deferredIssues: [String])? {
            deferredIssues.append(contentsOf: regression.deferredIssues)
            return (regression.result, deferredIssues)
        }

        // Ordered coverage
        let coverageStopwatch = Stopwatch()
        var discovery: ConcurrentDiscovery<Spec.Command>?

        if config.shouldRunCoverage {
            if let scaResult = runConcurrentSCACoverage(
                seqGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: resolvedCommandLimit,
                coverageBudget: coverageBudget,
                concurrencyLevel: concurrencyLevel,
                idleTimeout: idleTimeout,
                skipToRow: config.coverageReplayRow,
                property: property,
                identifySkips: identifySkips,
                lastRunTimedOut: lastRunTimedOut,
                invocationCounter: invocationCounter
            ) {
                discovery = ConcurrentDiscovery(
                    taggedCommands: scaResult.finalInput,
                    discoveryMethod: .coverage,
                    timedOut: scaResult.timedOut,
                    seed: nil,
                    originalCount: scaResult.originalCount,
                    iteration: Int(scaResult.iteration),
                    budget: coverageBudget,
                    sequencesTested: invocationCounter.value,
                    reductionStats: scaResult.reductionStats,
                    reductionInvocations: scaResult.reductionInvocations,
                    reductionMilliseconds: 0
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
                    failureContext: failureContext,
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

        if let stats = discovery.reductionStats {
            report.applyReductionStats(stats)
        }
        reductionInvocations = discovery.reductionInvocations
        discoveredDuringCoverage = discovery.discoveryMethod == .coverage
        report.reductionMilliseconds = discovery.reductionMilliseconds

        var ctx = failureContext
        ctx.seed = discovery.seed
        ctx.originalCount = discovery.originalCount
        ctx.iteration = discovery.iteration
        ctx.budget = discovery.budget
        ctx.sequencesTested = discovery.sequencesTested
        let failure = buildFailureResult(
            finalInput: discovery.taggedCommands,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeout: idleTimeout,
            seed: discovery.seed,
            discoveryMethod: discovery.discoveryMethod,
            timedOut: discovery.timedOut,
            failureContext: &ctx
        )
        if config.suppressIssueReporting == false {
            deferredIssues.append(failure.issueMessage)
        }
        return (failure.result, deferredIssues)
    }
}

// MARK: - Regression Seeds

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension __ExhaustRuntime {
    /// Replays each regression seed against the concurrent property, returning the first failure as a ``ContractResult`` with deferred issue messages. Returns nil when all seeds pass or are absent.
    static func runConcurrentRegressionSeeds<Spec: AsyncContractSpec>(
        regressionSeeds: [String],
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool,
        specInit: @escaping () -> Spec,
        concurrencyLevel: Int,
        idleTimeout: Int,
        failureContext: FailureContext,
        suppressIssueReporting: Bool
    ) -> (result: ContractResult<Spec>, deferredIssues: [String])? {
        guard regressionSeeds.isEmpty == false else {
            return nil
        }

        var issues: [String] = []
        for encodedSeed in regressionSeeds {
            guard let regressionSeed = CrockfordBase32.decode(encodedSeed) else {
                issues.append("Invalid regression seed: \(encodedSeed)")
                continue
            }
            var regressionInterpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: regressionSeed,
                maxRuns: 1
            )
            do {
                if let (input, _) = try regressionInterpreter.next() {
                    let passed = property(input)
                    if passed == false {
                        var ctx = failureContext
                        ctx.seed = regressionSeed
                        ctx.originalCount = input.count
                        ctx.sequencesTested = 1
                        let failure = buildFailureResult(
                            finalInput: input,
                            specInit: specInit,
                            concurrencyLevel: concurrencyLevel,
                            idleTimeout: idleTimeout,
                            seed: regressionSeed,
                            discoveryMethod: .replay,
                            timedOut: false,
                            failureContext: &ctx
                        )
                        if suppressIssueReporting == false {
                            issues.append(failure.issueMessage)
                        }
                        return (failure.result, issues)
                    } else if suppressIssueReporting == false {
                        issues.append("Regression seed \"\(encodedSeed)\" now passes — consider removing it.")
                    }
                }
            } catch {
                issues.append("Generator failed during regression replay (seed \(encodedSeed)): \(error)")
            }
        }
        return nil
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
        failureContext _: FailureContext,
        statsAccumulator: OpenPBTStatsAccumulator?
    ) throws -> ConcurrentDiscovery<Command>? {
        let startIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
        let maxRuns = replayIteration.map { UInt64($0) } ?? samplingBudget
        var interpreter = ValueAndChoiceTreeInterpreter(
            sequenceGen,
            materializePicks: true,
            seed: seed,
            maxRuns: maxRuns,
            initialRunIndex: startIndex
        )
        let actualSeed = interpreter.baseSeed

        var samplingIteration = 0
        while let (input, tree) = try interpreter.next() {
            samplingIteration += 1
            let absoluteIteration = Int(startIndex) + samplingIteration
            let passed = property(input)
            statsAccumulator?.record(
                representation: "\(input.map { "[\($0.0)] \($0.1)" })",
                passed: passed,
                tree: tree,
                phase: .random
            )

            if passed == false {
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "concurrent_failure_found",
                    metadata: ["commands": "\(input.count)", "timedOut": "\(lastRunTimedOut.value)"]
                )

                let reductionStartInvocations = invocationCounter.value
                let reductionStopwatch = Stopwatch()
                let reduction = reduceConcurrentCounterexample(
                    input: input,
                    tree: tree,
                    sequenceGen: sequenceGen,
                    reductionConfig: reductionConfig,
                    property: property,
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

        return nil
    }
}

// MARK: - Reduction

/// Internal (not fileprivate) so the SCA coverage path in `CooperativeConcurrentContractRunner+SCA.swift` can share this single reducer. Not `@available`-gated: it uses no macOS-15 APIs, so the (ungated) coverage and preemptive paths can call it directly.
extension __ExhaustRuntime {
    /// Prunes skipped commands, then runs graph reduction on the failing counterexample. When the failing probe timed out, skips reduction entirely and returns the input unchanged — timed-out schedules produce non-deterministic replay, making reduction unreliable.
    ///
    /// Shared by the random-sampling and SCA-coverage paths. Keeps no invocation count of its own: every probe flows through `property`, so the caller measures reduction invocations by snapshotting its own counter around this call.
    ///
    /// - Parameters:
    ///   - seed: Pruning materialization seed (sampling uses `0`; coverage uses the row iteration for determinism per row).
    ///   - skipPruningLogEvent: Log event name for the skip-pruning pass, distinguishing the two callers in the log stream.
    ///   - timedOut: The failing probe's timeout status, captured by the caller before reduction. Returned unchanged, so a reduced counterexample reports `false` rather than whatever the reducer probed last.
    static func reduceConcurrentCounterexample<Command>(
        input: [(ScheduleMarker, Command)],
        tree: ChoiceTree,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        reductionConfig: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
        seed: UInt64,
        skipPruningLogEvent: String,
        timedOut: Bool
    ) -> ConcurrentReduction<Command> {
        guard timedOut == false else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_timeout_skipping_reduction"
            )
            return ConcurrentReduction(finalInput: input, stats: nil, timedOut: true)
        }

        let (reduceValue, reduceTree) = pruneSkippedCommands(
            value: input,
            tree: tree,
            generator: sequenceGen,
            seed: seed,
            property: property,
            identifySkips: identifySkips,
            logEvent: skipPruningLogEvent
        )

        guard let reduceResult = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: sequenceGen,
            tree: reduceTree,
            output: reduceValue,
            config: reductionConfig,
            property: property
        ) else {
            return ConcurrentReduction(finalInput: reduceValue, stats: nil, timedOut: false)
        }

        let finalInput: [(ScheduleMarker, Command)]
        if case let .reduced(_, reduced) = reduceResult.outcome {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_reduced",
                metadata: ["from": "\(input.count)", "to": "\(reduced.count)"]
            )
            finalInput = reduced
        } else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_reduction_no_improvement"
            )
            finalInput = reduceValue
        }

        return ConcurrentReduction(finalInput: finalInput, stats: reduceResult.stats, timedOut: false)
    }
}

// MARK: - Failure Result Assembly

// reportIssue must be called from the Swift Testing async context, not the GCD thread where this function executes — Swift Testing's task-locals are not available on GCD threads, so the caller must collect the rendered message and report it after awaiting dispatchToGCD.

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

        // Run the commands sequentially on a fresh spec. If the sequential replay passes, the resulting state is the expected outcome — what the system should have produced without the race.
        let oracle = timedOut ? nil : sequentialOracle(commands: finalInput.map(\.1), specInit: specInit, idleTimeoutMilliseconds: idleTimeout)

        let replaySeed: String?
        if let seed {
            replaySeed = CrockfordBase32.encode(seed: seed, iteration: failureContext.iteration)
        } else if discoveryMethod == .coverage || discoveryMethod == .smokeTest {
            replaySeed = CrockfordBase32.encodeCoverageRow(failureContext.iteration - 1)
        } else {
            replaySeed = nil
        }

        let result = ContractResult<Spec>(
            commands: finalInput.map(\.1),
            trace: trace,
            systemUnderTest: oracle?.systemUnderTest,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        failureContext.discoveryMethod = discoveryMethod
        failureContext.replaySeed = replaySeed
        failureContext.timedOut = timedOut
        failureContext.oracleDescription = oracle.map { oracle in
            let hasModel = oracle.modelDescription != "(no model properties)"
            return hasModel
                ? "Expected result (from sequential replay of @Model):\n  \(oracle.modelDescription)"
                : "Expected result (from sequential replay of @SystemUnderTest):\n  \(oracle.sutDescription)"
        }
        let message = renderFailure(finalInput, trace: trace, context: failureContext)

        return (result, message)
    }
}

// MARK: - Supporting Types

/// Not `@available`-gated: `ConcurrentReduction` is returned by the ungated shared reducer, and these are plain data carriers with no macOS-15 dependency.
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

    /// Outcome of ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``, shared by the sampling and coverage paths.
    ///
    /// Carries no invocation count or timing: every reduction probe flows through the caller's `property`, so the caller measures both by snapshotting around the call.
    struct ConcurrentReduction<Command> {
        let finalInput: [(ScheduleMarker, Command)]
        let stats: ReductionStats?
        /// The failing probe's timeout status, passed through unchanged — a reduced (non-timed-out) counterexample reports `false`, never the reducer's last probe.
        let timedOut: Bool
    }
}
