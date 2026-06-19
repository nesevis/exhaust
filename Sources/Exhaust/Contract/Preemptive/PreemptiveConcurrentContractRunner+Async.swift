// Async preemptive concurrent contract runner.
//
// Async variant of the preemptive runner for AsyncContractSpec conformances.
// Bridges async command execution to GCD threads via Task+semaphore to catch races in synchronous primitives hidden behind async facades.
import ExhaustCore
import ExhaustObjCSupport
import Foundation
import IssueReporting

// MARK: - Async Entry Point

public extension __ExhaustRuntime {
    /// Runs a preemptive concurrent contract test for the given async specification type.
    ///
    /// Dispatches commands across real GCD threads and bridges async command execution via Task+semaphore. This catches races in synchronous primitives (locks, dispatch queues, atomics) hidden behind async facades. The cooperative runner's deterministic interleaving only reaches `await` suspension points.
    ///
    /// The outer loop runs on a GCD thread (via ``__ExhaustRuntime/dispatchToGCD(_:)``) to avoid starving the cooperative pool during parallel test runs. Issue reporting is deferred to the async return context where Swift Testing's task-locals are available.
    @discardableResult
    static func __runPreemptiveConcurrentContractAsync<Spec: AsyncContractSpec>(
        _: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> ContractResult<Spec>? {
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

        let backend = AsyncPreemptiveChecker<Spec>(idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds)

        let (result, deferredIssues, report): (ContractResult<Spec>?, [String], ExhaustReport) = await __ExhaustRuntime.dispatchToGCD {
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

// MARK: - Async Checker

/// Async ``PreemptiveBackend``: bridges async command execution to GCD threads via Task+semaphore.
///
/// Each lane gets a real OS thread, and within that thread async commands are driven synchronously. The cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncContractSpec>: PreemptiveBackend {
    /// Idle-timeout bound (milliseconds) for the blocking drain loop, or `nil` to wait unbounded. A command that suspends onto a foreign executor never returns to the drain lane; without this bound the loop spins a CPU core forever.
    let idleTimeoutMilliseconds: Int?

    /// Bridges async work to the calling thread, bailing with `nil` (and a log) if the drain loop idles past ``idleTimeoutMilliseconds``. Returns the work's result, or `nil` only on timeout.
    private func awaitOrTimeout<Value>(_ label: String, _ work: @Sendable @escaping () async -> Value) -> Value? {
        guard let idleTimeoutMilliseconds else {
            return __ExhaustRuntime.blockingAwait(work)
        }
        let result = __ExhaustRuntime.blockingAwait(idleTimeoutMilliseconds: idleTimeoutMilliseconds, work)
        if result == nil {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "async_preemptive_drain_timeout",
                label
            )
        }
        return result
    }

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants and oracle.
    ///
    /// Prefix and sequential commands are bridged through a single Task+semaphore. Concurrent commands are dispatched to real GCD threads (one per lane), each bridging async execution independently.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter(\.0.isPrefix)
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        let prefixOnConcurrent = runSequentially(prefixCommands.map(\.1), on: concurrentSpec)
        if prefixOnConcurrent.succeeded == false {
            return Preemptive.Outcome(passed: false, timedOut: prefixOnConcurrent.timedOut, laneResponses: nil, concurrentSpec: nil)
        }
        let prefixOnSequential = runSequentially(prefixCommands.map(\.1), on: sequentialSpec)
        if prefixOnSequential.succeeded == false {
            return Preemptive.Outcome(passed: false, timedOut: prefixOnSequential.timedOut, laneResponses: nil, concurrentSpec: nil)
        }
        let concurrentOnSequential = runSequentially(concurrentCommands.map(\.1), on: sequentialSpec)
        if concurrentOnSequential.succeeded == false {
            return Preemptive.Outcome(passed: false, timedOut: concurrentOnSequential.timedOut, laneResponses: nil, concurrentSpec: nil)
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
        let timedOut = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (rawValue, laneCommands) in laneGroups {
            let laneIndex = laneIndexByRawValue[rawValue]!
            let responseBox = perLaneResponses[laneIndex]
            let laneID = rawValue
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                nonisolated(unsafe) let spec = concurrentSpec
                let succeeded = exhaust_runCatchingObjCException({
                    let completed: Void? = awaitOrTimeout("lane") {
                        for (_, command) in laneCommands {
                            if commandFailed.value { break }
                            do {
                                let response = try await spec.run(command)
                                let outcome = response.returnValue.map(ObservedResponse<Spec.Command>.Outcome.returned) ?? .returnedVoid
                                responseBox.withValue { responses in
                                    responses.append(ObservedResponse<Spec.Command>(
                                        lane: laneID,
                                        command: command,
                                        commandDescription: response.commandDescription,
                                        outcome: outcome
                                    ))
                                }
                            } catch is ContractSkip {
                                responseBox.withValue { responses in
                                    responses.append(ObservedResponse<Spec.Command>(
                                        lane: laneID,
                                        command: command,
                                        commandDescription: command.description,
                                        outcome: .skipped
                                    ))
                                }
                            } catch {
                                commandFailed.value = true
                                break
                            }
                        }
                    }
                    if completed == nil {
                        commandFailed.value = true
                        timedOut.value = true
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
                return Preemptive.Outcome(passed: false, timedOut: true, laneResponses: nil, concurrentSpec: nil)
            }
        } else {
            group.wait()
        }

        if caughtException.value != nil || commandFailed.value {
            return Preemptive.Outcome(passed: false, timedOut: timedOut.value, laneResponses: nil, concurrentSpec: nil)
        }

        nonisolated(unsafe) let invariantSpec = concurrentSpec
        // Timeout → treat as failed (cannot confirm invariants held), and flag it so the failure is reported as a hang.
        guard let invariantsPassed = awaitOrTimeout("invariants", {
            do {
                try await invariantSpec.checkInvariants()
                return true
            } catch {
                return false
            }
        }) else {
            return Preemptive.Outcome(passed: false, timedOut: true, laneResponses: nil, concurrentSpec: nil)
        }

        if invariantsPassed == false {
            return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: nil, concurrentSpec: nil)
        }

        nonisolated(unsafe) let oracleSpec = concurrentSpec
        nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
        // Timeout → treat as failed (cannot confirm the oracle), and flag it so the failure is reported as a hang.
        guard let oraclePassed = awaitOrTimeout("oracle", {
            await oracleSpec.oracleCheck(sequentialResult)
        }) else {
            return Preemptive.Outcome(passed: false, timedOut: true, laneResponses: nil, concurrentSpec: nil)
        }
        if oraclePassed {
            return Preemptive.Outcome(passed: true, timedOut: false, laneResponses: nil, concurrentSpec: nil)
        }
        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        return Preemptive.Outcome(passed: false, timedOut: false, laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Outcome of a sequential command run.
    ///
    /// `timedOut` distinguishes a drain-loop idle bailout from a command that threw or trapped, so a hang in the prefix or sequential reference replay propagates to ``Preemptive/Outcome/timedOut`` rather than masquerading as a deterministic failure.
    struct SequentialOutcome {
        let succeeded: Bool
        let timedOut: Bool
    }

    /// Runs commands sequentially on a spec, bridging async execution via ``__ExhaustRuntime/blockingAwait(_:)``. Wraps in ObjC exception handling so NSExceptions from underlying C/ObjC code are caught rather than crashing the process.
    ///
    /// `succeeded` is `true` when all commands succeeded or were skipped, `false` when any command threw a non-skip error, an NSException was caught, or the drain loop idled out. `timedOut` is `true` only in that last case.
    @discardableResult
    func runSequentially(_ commands: [Spec.Command], on spec: Spec) -> SequentialOutcome {
        var exception: NSException?
        let failed = SendableBox(false)
        let timedOut = SendableBox(false)
        nonisolated(unsafe) let spec = spec
        exhaust_runCatchingObjCException({
            let completed: Void? = awaitOrTimeout("sequential") {
                for command in commands {
                    do {
                        try await spec.run(command)
                    } catch is ContractSkip {
                        continue
                    } catch {
                        failed.value = true
                        break
                    }
                }
            }
            if completed == nil {
                failed.value = true
                timedOut.value = true
            }
        }, &exception)
        return SequentialOutcome(succeeded: exception == nil && failed.value == false, timedOut: timedOut.value)
    }

    func checkLinearizability(
        prefix: [Spec.Command],
        laneResponses: Any,
        concurrentSpec: Any
    ) -> LinearizabilityResult {
        guard let typedResponses = laneResponses as? [[ObservedResponse<Spec.Command>]],
              let typedSpec = concurrentSpec as? Spec
        else {
            return .linearizable
        }
        let observations = typedResponses.map { lane in
            lane.map { response in
                LinearizabilityChecker<Spec.Command>.Observation(
                    command: response.command,
                    commandDescription: response.commandDescription,
                    returnValue: response.outcome.returnValue,
                    isSkipped: response.outcome.isSkipped
                )
            }
        }
        let checker = LinearizabilityChecker(laneObservations: observations)
        nonisolated(unsafe) let unsafeSpec = typedSpec
        let result: LinearizabilityChecker<Spec.Command>.Result = __ExhaustRuntime.blockingAwait {
            var replaySpec: Spec?
            return await checker.checkAsync(
                prefix: prefix,
                replayPrefix: { prefixCommands in
                    let fresh = Spec()
                    for command in prefixCommands {
                        do {
                            try await fresh.run(command)
                        } catch {
                            return false
                        }
                    }
                    replaySpec = fresh
                    return true
                },
                replayCommand: { command in
                    guard let spec = replaySpec else { return nil }
                    do {
                        let response = try await spec.run(command)
                        return .init(
                            commandDescription: response.commandDescription,
                            returnValue: response.returnValue,
                            isSkipped: false
                        )
                    } catch is ContractSkip {
                        return .init(
                            commandDescription: command.description,
                            returnValue: nil,
                            isSkipped: true
                        )
                    } catch {
                        return nil
                    }
                },
                checkOracle: {
                    guard let spec = replaySpec else { return false }
                    return await unsafeSpec.oracleCheck(spec.systemUnderTest)
                }
            )
        }
        return makeLinearizabilityResult(result, laneObservations: typedResponses)
    }

    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> {
        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let rawIdentifySkips = Spec.skipIdentifier(
            specInit: specInit,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        return { taggedCommands in
            // Skip identification replays the commands on a fresh spec via a blocking drain, outside the ObjC guard that wraps lane execution. A synchronously-thrown NSException would otherwise propagate out of the drain and abort, so degrade to "no skips identified" (pruning becomes a no-op and the actual execution catches and reports it).
            var skipped: Set<Int> = []
            var exception: NSException?
            let completed = exhaust_runCatchingObjCException({
                skipped = rawIdentifySkips(taggedCommands.map(\.1))
            }, &exception)
            return completed ? skipped : []
        }
    }

    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
        let spec = Spec()
        nonisolated(unsafe) let unsafeSpec = spec
        let work: @Sendable () async -> ([TraceStep], Bool) = {
            await __ExhaustRuntime.buildAsyncSequentialTrace(
                commands,
                run: { try await unsafeSpec.run($0) },
                checkInvariants: { try await unsafeSpec.checkInvariants() }
            )
        }
        let (trace, failed) = __ExhaustRuntime.blockingAwait(work)
        if failed {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        // A .threads spec expresses its self-consistency check through the @Oracle, because the macro rejects @Invariant under .threads, and smoke never runs the concurrent phase.
        // Replay the sequence on a fresh reference and call the oracle once at the end, so a spec that is already broken under sequential execution fails here before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let reference = Spec()
        nonisolated(unsafe) let unsafeReference = reference
        let smokeTimeout = (idleTimeoutMilliseconds ?? ResolvedConcurrentConfig.defaultIdleTimeout) * 5
        let referenceFailed: Bool? = __ExhaustRuntime.blockingAwait(idleTimeoutMilliseconds: smokeTimeout) {
            for command in commands {
                do {
                    try await unsafeReference.run(command)
                } catch is ContractSkip {
                    continue
                } catch {
                    return true
                }
            }
            return false
        }
        if referenceFailed != false {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        nonisolated(unsafe) let referenceResult = reference.systemUnderTest
        nonisolated(unsafe) let oracleSpec = spec
        let oracleHeld = __ExhaustRuntime.blockingAwait {
            await oracleSpec.oracleCheck(referenceResult)
        }
        if oracleHeld == false {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        return (trace, false, spec.systemUnderTest, nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec via ``runSequentially(_:on:)`` to capture the oracle SUT state. Returns nil ``ContractResult/systemUnderTest`` when the sequential replay itself fails or times out, because the partial state would mislead debugging.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> (result: ContractResult<Spec>, failureDescription: String?) {
        let oracleSpec = Spec()
        let replayOutcome = runSequentially(reduced.map(\.1), on: oracleSpec)
        let result = ContractResult<Spec>(
            commands: reduced.map(\.1),
            trace: __ExhaustRuntime.buildPreemptiveTrace(reduced),
            systemUnderTest: replayOutcome.succeeded ? oracleSpec.systemUnderTest : nil,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
        return (result, replayOutcome.succeeded ? oracleSpec.failureDescription() : nil)
    }
}
