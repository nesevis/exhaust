// Cooperative concurrent spec runner.
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
    /// Dispatches an asynchronous spec test to the runner the call site asked for.
    @discardableResult
    static func __runStateMachineDispatchAsync<Spec: AsyncStateMachineSpec>(
        _ specType: Spec.Type,
        mode: ExecutionModel,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> StateMachineResult<Spec>? {
        switch mode {
            case .sequential:
                return await __runStateMachineAsync(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .tasks:
                guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
                    reportError(
                        "mode: .tasks requires macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, or visionOS 2+",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    return nil
                }
                return await __runStateMachineConcurrent(
                    specType,
                    settings: settings,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            case .threads:
                return await __runPreemptiveConcurrentStateMachineAsync(
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
    /// Runs a `.tasks` concurrent spec test for the given async spec type.
    ///
    /// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``drainSchedule(taggedCommands:setupStep:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer reduces both the command sequence and the lane assignments.
    ///
    /// The same seed always produces the same command ordering and lane assignment. Commands with multiple internal suspension points may exhaust the encoded schedule, falling back to deterministic round-robin for remaining continuations.
    @discardableResult
    static func __runStateMachineConcurrent<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        settings: [StateMachineSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> StateMachineResult<Spec>? {
        let parsed = ResolvedConcurrentConfig.parse(settings)
        if let invalidSeed = parsed.invalidReplaySeed {
            reportError(
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

        // Only a spec that declares an equivalence runs an interleaving search, and only its default command limit is knowable here: without one, the limit comes from an estimate over the command generator that the pipeline computes for itself. Emitted here rather than inside the pipeline for the same reason the thread-based runner does it here — on the test's own thread, before the work is dispatched, so the issue attaches to the running test.
        if Spec.hasEquivalence {
            warnIfInterleavingSpaceIsLarge(
                commandLimit: config.commandLimit ?? PreemptiveReduction.defaultCommandLimit,
                laneCount: config.concurrencyLevel,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }

        // The drain loop inside drainSchedule calls runSynchronously in a tight polling loop on whatever thread hosts it. When that thread belongs to the cooperative pool, parallel test suites each occupy a cooperative thread with a spin-wait, starving the pool and preventing the Swift runtime from scheduling the Task continuations that feed the drain loop. This deadlocks under parallel execution on machines with few cores. Dispatching the entire pipeline to a GCD thread moves all drain loops off the cooperative pool. GCD's global queue is far larger than the fixed cooperative pool, so this avoids that starvation — but it is not unbounded: a top-level concurrent queue caps at 64 threads, so aggregate lane demand is bounded by `LaneGate` (via `dispatchToGCD(reserving:)`) to keep it under that wall.
        let timeoutProbeCounts = UnsafeSendableBox((attempts: 0, timedOut: 0))
        let searchAbandonments = UnsafeSendableBox(0)
        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.single) {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runCooperativeMachine(
                    Spec.self,
                    config: config,
                    regressionSeeds: regressionSeeds,
                    timeoutProbeCounts: timeoutProbeCounts,
                    searchAbandonments: searchAbandonments,
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
        warnIfTimeoutFractionHigh(
            timedOutProbes: timeoutProbeCounts.value.timedOut,
            totalProbes: timeoutProbeCounts.value.attempts,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        warnIfSearchesWereAbandoned(
            abandonedSearches: searchAbandonments.value,
            totalProbes: timeoutProbeCounts.value.attempts,
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
    static func runCooperativeMachine<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        timeoutProbeCounts: UnsafeSendableBox<(attempts: Int, timedOut: Int)>,
        searchAbandonments: UnsafeSendableBox<Int>,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []
        let config = config

        let commandGen = Spec.commandGenerator.gen
        let screeningBudget = config.budget.screeningBudget
        let resolvedCommandLimit = config.commandLimit
            ?? defaultTasksCommandLimit(
                hasEquivalence: Spec.hasEquivalence,
                commandGen: commandGen,
                screeningBudget: screeningBudget
            )

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
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            rawIdentifySkips(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let backend = CooperativeStateMachineBackend<Spec>(
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds,
            searchAbandonments: searchAbandonments
        )

        let invocationCounter = UnsafeSendableBox(0)
        let property: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            invocationCounter.value += 1
            timeoutProbeCounts.value.attempts += 1
            let result = drainAndJudge(
                taggedCommands: candidate.taggedCommands,
                setupStep: candidate.setupStep,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                searchAbandonments: searchAbandonments
            )
            if result.timedOut {
                // A timed-out probe is inconclusive, not a counterexample. Count it as a pass so discovery keeps sampling, and tally it for the timeout-rate warning.
                timeoutProbeCounts.value.timedOut += 1
                return true
            }
            return result.passed
        }

        var smokeSource: AnyStateMachineCandidateSource<Spec>?
        if concurrencyLevel > 1 {
            let rawSmokeProperty = asyncSequentialProperty(specInit: specInit)
            let smokeProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
                invocationCounter.value += 1
                return rawSmokeProperty(candidate)
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

        let pipeline = SpecPipeline(
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

// MARK: - Command Limit

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension __ExhaustRuntime {
    /// The command limit a task-based run uses when the settings name none.
    ///
    /// A spec that declares an equivalence takes the thread-based default, because every probe its equivalence rejects pays for an interleaving search whose cost grows multinomially in the sequence length. The estimate-driven limit reaches 40, which puts that search past its replay budget on a spec whose commands answer nothing — the search is then abandoned and the probe passes without judging anything, which is the outcome the lower limit exists to avoid. The startup interleaving-space warning in ``__runStateMachineConcurrent(_:settings:fileID:filePath:line:column:)`` assumes this same default.
    ///
    /// Without an equivalence a probe costs one drain and nothing searches, so the estimate stands: longer sequences reach deeper states, and the drain's cost is linear in their length.
    static func defaultTasksCommandLimit(
        hasEquivalence: Bool,
        commandGen: Generator<some Any>,
        screeningBudget: Int
    ) -> Int {
        guard hasEquivalence == false else {
            return PreemptiveReduction.defaultCommandLimit
        }
        return min(estimateCommandLimit(commandGen: commandGen, screeningBudget: UInt64(screeningBudget)), 40)
    }
}
