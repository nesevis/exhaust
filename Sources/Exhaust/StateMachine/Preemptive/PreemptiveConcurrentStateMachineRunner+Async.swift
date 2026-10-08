// Async preemptive concurrent spec runner.
//
// Async variant of the preemptive runner for AsyncStateMachineSpec conformances.
// Bridges async command execution to GCD threads via Task+semaphore to catch races in synchronous primitives hidden behind async facades.
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Async Entry Point

package extension __ExhaustRuntime {
    /// Runs a preemptive concurrent spec test for the given async specification type.
    ///
    /// Dispatches commands across real GCD threads and bridges async command execution via Task+semaphore. This catches races in synchronous primitives (locks, dispatch queues, atomics) hidden behind async facades. The cooperative runner's deterministic interleaving only reaches `await` suspension points.
    ///
    /// The outer loop runs on a GCD thread (via ``__ExhaustRuntime/dispatchToGCD(reserving:_:)``) to avoid starving the cooperative pool during parallel test runs. Issue reporting is deferred to the async return context where Swift Testing's task-locals are available.
    @discardableResult
    static func __runPreemptiveConcurrentStateMachineAsync<Spec: AsyncStateMachineSpec>(
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
        let searchStalls = UnsafeSendableBox(0)
        let timeoutProbeCounts = UnsafeSendableBox((attempts: 0, timedOut: 0))
        let innerBackend = AsyncPreemptiveChecker<Spec>(
            idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds,
            searchAbandonments: searchAbandonments,
            searchStalls: searchStalls
        )
        let commandLimit = config.commandLimit ?? ConcurrentSpecTunables.defaultCommandLimit
        warnIfInterleavingSpaceIsLarge(commandLimit: commandLimit, laneCount: config.concurrencyLevel, fileID: fileID, filePath: filePath, line: line, column: column)

        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) { gateWaitNanoseconds in
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
            stalledSearches: searchStalls.value,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return result
    }
}
