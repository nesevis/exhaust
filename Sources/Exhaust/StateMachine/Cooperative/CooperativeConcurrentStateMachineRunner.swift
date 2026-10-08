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
package extension __ExhaustRuntime {
    /// Runs a `.tasks` concurrent spec test for the given async spec type.
    ///
    /// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``CooperativeScheduler/drainSchedule(taggedCommands:setupStep:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer reduces both the command sequence and the lane assignments.
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
        parsed.reportCommandLimitClampWarning(fileID: fileID, filePath: filePath, line: line, column: column)
        let config = parsed.config

        // The trait-budget fallback is applied in `ResolvedConcurrentConfig.parse`, so `config.budget` already reflects a suite-level `.budget` trait here.
        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        // Only a spec that declares an equivalence runs an interleaving search, and only its default command limit is knowable here: without one, the limit comes from an estimate over the command generator that the pipeline computes for itself. Emitted here rather than inside the pipeline for the same reason the thread-based runner does it here — on the test's own thread, before the work is dispatched, so the issue attaches to the running test.
        if Spec.hasEquivalence {
            warnIfInterleavingSpaceIsLarge(
                commandLimit: config.commandLimit ?? ConcurrentSpecTunables.defaultCommandLimit,
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
        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.single) { gateWaitNanoseconds in
            var admittedConfig = config
            admittedConfig.postponeDeadline(by: gateWaitNanoseconds)
            return ExhaustLog.withConfiguration(admittedConfig.logConfiguration) {
                runCooperativeMachine(
                    Spec.self,
                    config: admittedConfig,
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
        warnIfSearchesWentUnjudged(
            abandonedSearches: searchAbandonments.value,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return result
    }
}
