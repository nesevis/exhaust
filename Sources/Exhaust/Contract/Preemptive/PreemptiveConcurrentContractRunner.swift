// Preemptive concurrent contract runner.
//
// Based on eqc_par_statem from Claessen et al., "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work generates a sequential prefix followed by concurrent command groups, then compares the concurrent outcome against a sequential oracle. PULSE adds deterministic replay via a user-level scheduler; this runner omits replay and relies on OS thread scheduling for non-deterministic interleaving, compensating with repetition across the sampling budget.
//
// The cooperative runner (CooperativeConcurrentContractRunner) implements the PULSE half, a TaskExecutor-based drain loop that makes interleavings deterministic and reducible. This runner targets bugs that require real thread-level preemption: races in locks, dispatch queues, and atomics that are invisible at `await` suspension points.
import ExhaustCore
import ExhaustObjCSupport
import Foundation
import IssueReporting

// MARK: - Runner Entry Point

public extension __ExhaustRuntime {
    /// Runs a preemptive concurrent contract test for the given synchronous specification type.
    ///
    /// Dispatches commands across real GCD threads and uses the spec's ``ContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving, so bug detection is probabilistic and relies on repetition across the sampling budget.
    @discardableResult
    static func __runPreemptiveConcurrentContract<Spec: ContractSpec>(
        _: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ContractResult<Spec>? {
        let config: ResolvedConcurrentConfig
        switch ResolvedConcurrentConfig.parse(settings) {
            case let .success(resolved):
                config = resolved
            case let .invalidReplaySeed(seed):
                reportIssue(
                    "Invalid replay seed: \(seed)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return nil
        }

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        let backend = PreemptiveChecker<Spec>(idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds)

        let (result, deferredIssues, report): (ContractResult<Spec>?, [String], ExhaustReport) = DispatchQueue.global().sync {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runPreemptivePipeline(backend: backend, config: config, regressionSeeds: regressionSeeds)
            }
        }
        config.onReportClosure?(report)
        for issue in deferredIssues {
            reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}

// MARK: - Trace Building

extension __ExhaustRuntime {
    /// Builds a trace from a preemptive execution's reduced command sequence in input order. No interleaving annotations are included because preemptive scheduling is non-deterministic, so actual execution order may differ from the listed order.
    static func buildPreemptiveTrace(
        _ reduced: [(ScheduleMarker, some CustomStringConvertible)]
    ) -> [TraceStep] {
        var laneCounts: [UInt8: Int] = [:]
        return reduced.enumerated().map { index, tagged in
            let (marker, command) = tagged
            if marker.isPrefix {
                return TraceStep(
                    index: index + 1,
                    command: "\(command) (prefix)",
                    outcome: .ok
                )
            } else {
                let laneLabel = marker.description.uppercased()
                laneCounts[marker.rawValue, default: 0] += 1
                let laneIndex = laneCounts[marker.rawValue]!
                return TraceStep(
                    index: index + 1,
                    command: "\(laneIndex)\(laneLabel) \(command) (completed)",
                    outcome: .ok
                )
            }
        }
    }
}

// MARK: - ObjC Exception Helper

/// Executes a closure inside the ObjC `@try`/`@catch` wrapper. Returns `true` if the closure completed normally, `false` if an `NSException` was caught. Discards the exception; use the lane-level `caughtException` box when the identity matters.
@discardableResult
private func runCatchingObjC(_ body: @convention(block) () -> Void) -> Bool {
    var exception: NSException?
    return exhaust_runCatchingObjCException(body, &exception)
}

// MARK: - Checker

/// Synchronous ``PreemptiveBackend``: runs each probe directly on GCD threads and compares against a sequential oracle.
private struct PreemptiveChecker<Spec: ContractSpec>: PreemptiveBackend {
    /// Idle bound for the concurrent lanes, or `nil` to wait indefinitely. Without a bound, a synchronous SUT deadlock (the exact bug class preemptive testing targets) would wedge a lane forever and hang the test process with no diagnostic.
    let idleTimeoutMilliseconds: Int?

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants and oracle.
    ///
    /// `passed` is `false` when a command throws, an invariant fails, or the oracle detects divergence from sequential behavior. `timedOut` is `true` when the concurrent lanes did not finish within ``idleTimeoutMilliseconds``, surfaced separately so the caller can skip reduction (every probe would wait out the bound) and report a hang rather than a deterministic failure.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter(\.0.isPrefix)
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        for (_, command) in prefixCommands {
            guard runCommandCatchingObjC(command, on: concurrentSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil)
            }
            guard runCommandCatchingObjC(command, on: sequentialSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil)
            }
        }

        for (_, command) in concurrentCommands {
            guard runCommandCatchingObjC(command, on: sequentialSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil)
            }
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let laneCount = laneGroups.count
        let perLaneResponses = (0 ..< laneCount).map { _ in SendableBox<[ObservedResponse<Spec.Command>]>([]) }
        let laneIndexByRawValue: [UInt8: Int] = {
            var mapping: [UInt8: Int] = [:]
            for (index, rawValue) in laneGroups.keys.sorted().enumerated() {
                mapping[rawValue] = index
            }
            return mapping
        }()

        let commandFailed = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (rawValue, laneCommands) in laneGroups {
            let laneIndex = laneIndexByRawValue[rawValue]!
            let responseBox = perLaneResponses[laneIndex]
            let laneID = rawValue
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    for (_, command) in laneCommands {
                        if commandFailed.value { break }
                        let timestamp = mach_absolute_time()
                        do {
                            let response = try concurrentSpec.run(command)
                            let outcome: ObservedResponse<Spec.Command>.Outcome =
                                response.returnValue != nil
                                    ? .returned(response.returnValue!)
                                    : .returnedVoid
                            responseBox.withValue { responses in
                                responses.append(ObservedResponse<Spec.Command>(
                                    lane: laneID,
                                    command: command,
                                    commandDescription: response.commandDescription,
                                    outcome: outcome,
                                    timestamp: timestamp
                                ))
                            }
                        } catch is ContractSkip {
                            responseBox.withValue { responses in
                                responses.append(ObservedResponse<Spec.Command>(
                                    lane: laneID,
                                    command: command,
                                    commandDescription: command.description,
                                    outcome: .skipped,
                                    timestamp: timestamp
                                ))
                            }
                        } catch {
                            commandFailed.value = true
                            break
                        }
                    }
                }, &exception)
                if succeeded == false {
                    caughtException.value = exception
                }
                group.leave()
            }
        }
        if let idleTimeoutMilliseconds {
            if group.wait(timeout: .now() + .milliseconds(idleTimeoutMilliseconds)) == .timedOut {
                commandFailed.value = true
                return Preemptive.Outcome(passed: false, timedOut: true, laneResponses: nil)
            }
        } else {
            group.wait()
        }

        if caughtException.value != nil || commandFailed.value {
            return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil)
        }

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil)
        }

        let oraclePassed = concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)
        if oraclePassed {
            return Preemptive.Outcome(passed: true, timedOut: false, laneResponses: nil)
        }
        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: collectedResponses)
    }

    /// Runs a command on a spec with ObjC exception safety, treating ``ContractSkip`` as a pass.
    private func runCommandCatchingObjC(_ command: Spec.Command, on spec: Spec) -> Bool {
        var commandError: (any Error)?
        let objcSucceeded = runCatchingObjC {
            do {
                try spec.run(command)
            } catch {
                commandError = error
            }
        }
        guard objcSucceeded else {
            return false
        }
        if let commandError, commandError is ContractSkip == false {
            return false
        }
        return true
    }

    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> {
        let rawIdentifySkips = Spec.skipIdentifier
        return { taggedCommands in rawIdentifySkips(taggedCommands.map(\.1)) }
    }

    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
        let spec = Spec()
        let (trace, failed) = __ExhaustRuntime.buildSequentialTrace(
            commands,
            run: { command in
                var caughtError: (any Error)?
                let objcSucceeded = runCatchingObjC {
                    do {
                        try spec.run(command)
                    } catch {
                        caughtError = error
                    }
                }
                if let caughtError {
                    throw caughtError
                }
                if objcSucceeded == false {
                    throw ContractCheckFailure(message: "NSException during command execution")
                }
            },
            checkInvariants: { try spec.checkInvariants() }
        )
        return (trace, failed, spec.systemUnderTest, failed ? spec.failureDescription() : nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec to capture the oracle SUT state. Returns nil ``ContractResult/systemUnderTest`` when the sequential replay itself fails, because the partial state would mislead debugging.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> (result: ContractResult<Spec>, failureDescription: String?) {
        let oracleSpec = Spec()
        var replaySucceeded = true
        for (_, command) in reduced {
            var exception: NSException?
            let succeeded = exhaust_runCatchingObjCException({
                do {
                    try oracleSpec.run(command)
                } catch is ContractSkip {
                    // Skip is expected, continue.
                } catch {
                    replaySucceeded = false
                }
            }, &exception)
            if succeeded == false || replaySucceeded == false {
                replaySucceeded = false
                break
            }
        }
        let result = ContractResult<Spec>(
            commands: reduced.map(\.1),
            trace: __ExhaustRuntime.buildPreemptiveTrace(reduced),
            systemUnderTest: replaySucceeded ? oracleSpec.systemUnderTest : nil,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
        return (result, replaySucceeded ? oracleSpec.failureDescription() : nil)
    }
}
