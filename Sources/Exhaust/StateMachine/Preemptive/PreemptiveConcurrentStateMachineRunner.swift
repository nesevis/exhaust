// Preemptive concurrent spec runner.
//
// Based on eqc_par_statem from Claessen et al., "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work generates a sequential prefix followed by concurrent command groups, then compares the concurrent outcome against a sequential oracle. PULSE adds deterministic replay via a user-level scheduler; this runner omits replay and relies on OS thread scheduling for non-deterministic interleaving, compensating with repetition across the sampling budget.
//
// The cooperative runner (CooperativeConcurrentStateMachineRunner) implements the PULSE half, a TaskExecutor-based drain loop that makes interleavings deterministic and reducible. This runner targets bugs that require real thread-level preemption: races in locks, dispatch queues, and atomics that are invisible at `await` suspension points.
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Runner Entry Point

package extension __ExhaustRuntime {
    /// Runs a preemptive concurrent spec test for the given synchronous specification type.
    ///
    /// Dispatches commands across real GCD threads and uses the spec's ``StateMachineSpec/equivalenceCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving, so bug detection is probabilistic and relies on repetition across the sampling budget.
    @discardableResult
    static func __runPreemptiveConcurrentStateMachine<Spec: StateMachineSpec>(
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
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return nil
        }
        parsed.reportCommandLimitClampWarning(fileID: fileID, filePath: filePath, line: line, column: column)
        let config = parsed.config

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        guard threadsModeIsUsable(
            Spec.self,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        ) else {
            return nil
        }

        let searchAbandonments = UnsafeSendableBox(0)
        let innerBackend = PreemptiveChecker<Spec>(
            idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds,
            searchAbandonments: searchAbandonments
        )
        let commandLimit = config.commandLimit ?? ConcurrentSpecTunables.defaultCommandLimit
        warnIfInterleavingSpaceIsLarge(commandLimit: commandLimit, laneCount: config.concurrencyLevel, fileID: fileID, filePath: filePath, line: line, column: column)

        let timeoutProbeCounts = UnsafeSendableBox((attempts: 0, timedOut: 0))
        // Gate + offload: acquire a lane reservation, then run the (synchronous) machine on a GCD worker. The gate bounds how many preemptive runs execute at once so their lanes are not starved of threads under `--parallel`; the GCD hop frees the cooperative thread. Reporting is deferred to the async return context where Swift Testing's task-locals are available.
        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) { gateWaitNanoseconds in
            var admittedConfig = config
            admittedConfig.postponeDeadline(by: gateWaitNanoseconds)
            return ExhaustLog.withConfiguration(admittedConfig.logConfiguration) {
                runPreemptiveMachine(
                    innerBackend: innerBackend,
                    config: admittedConfig,
                    regressionSeeds: regressionSeeds,
                    timeoutProbeCounts: timeoutProbeCounts,
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
