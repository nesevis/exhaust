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
        let timedOutProbeCount = UnsafeSendableBox(0)
        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.single) {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runCooperativeMachine(
                    Spec.self,
                    config: config,
                    regressionSeeds: regressionSeeds,
                    timedOutProbeCount: timedOutProbeCount,
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
        warnIfTimeoutFractionHigh(
            timedOutProbes: timedOutProbeCount.value,
            totalBudget: config.budget.coverageBudget + config.budget.samplingBudget,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
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
        timedOutProbeCount: UnsafeSendableBox<Int>,
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
        let idleTimeoutMilliseconds = config.idleTimeoutMilliseconds

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit, idleTimeoutMilliseconds: idleTimeoutMilliseconds)
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
            rawIdentifySkips(taggedCommands.map(\.1))
        }

        let backend = CooperativeContractBackend<Spec>(
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )

        let invocationCounter = UnsafeSendableBox(0)
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let result = drainSchedule(
                taggedCommands: taggedCommands,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds
            )
            if result.timedOut {
                // A timed-out probe is inconclusive, not a counterexample. Count it as a pass so discovery keeps sampling, and tally it for the timeout-rate warning.
                timedOutProbeCount.value += 1
                return true
            }
            return result.passed
        }

        var smokeSource: AnyContractCandidateSource<Spec.Command>?
        if concurrencyLevel > 1 {
            let rawSmokeProperty = asyncSequentialProperty(specInit: specInit)
            let smokeProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { tagged in
                invocationCounter.value += 1
                return rawSmokeProperty(tagged)
            }
            // Smoke runs commands sequentially, so generate concurrency-1 (all-prefix) sequences. The candidate carries this generator and reduces sequentially even at higher lane counts.
            let smokeSequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
            if let sequentialCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: 1) {
                smokeSequenceGen = Gen.arrayOf(sequentialCommandGen, within: 1 ... UInt64(resolvedCommandLimit), scaling: .constant)
            } else {
                smokeSequenceGen = sequenceGen
            }
            smokeSource = .smoke(sequenceGen: smokeSequenceGen, property: smokeProperty)
        }

        let pipeline = ContractPipeline(
            backend: backend,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: resolvedCommandLimit,
            concurrencyLevel: concurrencyLevel,
            identifySkips: identifySkips,
            property: property,
            invocationCounter: invocationCounter,
            sequenceGenForLength: { range in
                Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant)
            },
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        let (result, issues) = pipeline.runWithRegressions(
            config: config,
            regressionSeeds: regressionSeeds,
            mainRunSmokeSource: smokeSource
        )
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }
}
