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
        let parsed = ResolvedConcurrentConfig.parse(settings)
        if let invalidSeed = parsed.invalidReplaySeed {
            reportIssue(
                "Invalid replay seed: \(invalidSeed)",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return nil
        }
        let config = parsed.config

        var regressionSeeds: [String] = []
        #if canImport(Testing)
            regressionSeeds = ExhaustTraitConfiguration.current?.regressions ?? []
        #endif

        let innerBackend = AsyncPreemptiveChecker<Spec>(idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds)
        let commandLimit = config.commandLimit ?? PreemptiveReduction.defaultCommandLimit
        warnIfInterleavingSpaceIsLarge(commandLimit: commandLimit, laneCount: config.concurrencyLevel, fileID: fileID, filePath: filePath, line: line, column: column)

        let timedOutProbeCount = UnsafeSendableBox(0)
        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.asyncThreads(config.concurrencyLevel)) {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runPreemptiveMachine(
                    innerBackend: innerBackend,
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

// MARK: - Async Checker

/// Bridges async command execution to GCD threads via Task+semaphore.
///
/// Each lane gets a real OS thread, and within that thread async commands are driven synchronously. The cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncContractSpec>: PreemptiveBackend {
    /// Idle-timeout bound (milliseconds) for the blocking drain loop, or `nil` to wait unbounded. A command that suspends onto a foreign executor never returns to the drain lane; without this bound the loop spins a CPU core forever.
    let idleTimeoutMilliseconds: Int?

    /// Bridges async work to the calling thread, bailing with `nil` (and a log) if the drain loop idles past ``idleTimeoutMilliseconds``. Returns the work's result, or `nil` only on timeout.
    private func awaitOrTimeout<Value>(_ label: String, timeoutMultiplier: Int = 1, _ work: @Sendable @escaping () async -> Value) -> Value? {
        guard let idleTimeoutMilliseconds else {
            return __ExhaustRuntime.blockingAwait(work)
        }
        let result = __ExhaustRuntime.blockingAwait(idleTimeoutMilliseconds: idleTimeoutMilliseconds * timeoutMultiplier, work)
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
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], partition _: LanePartition<Spec.Command>) -> Preemptive.Outcome<Spec> {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixOnConcurrent = runSequentially(taggedCommands, selectPrefix: true, on: concurrentSpec)
        if prefixOnConcurrent.succeeded == false {
            return prefixOnConcurrent.timedOut ? .timedOut(concurrentSpec: nil) : .failed(concurrentSpec: nil)
        }
        let prefixOnSequential = runSequentially(taggedCommands, selectPrefix: true, on: sequentialSpec)
        if prefixOnSequential.succeeded == false {
            return prefixOnSequential.timedOut ? .timedOut(concurrentSpec: nil) : .failed(concurrentSpec: nil)
        }
        let concurrentOnSequential = runSequentially(taggedCommands, selectPrefix: false, on: sequentialSpec)
        if concurrentOnSequential.succeeded == false {
            return concurrentOnSequential.timedOut ? .timedOut(concurrentSpec: nil) : .failed(concurrentSpec: nil)
        }

        var laneIDs: [UInt8] = []
        for (marker, _) in taggedCommands where marker.isPrefix == false {
            if laneIDs.contains(marker.rawValue) == false {
                laneIDs.append(marker.rawValue)
            }
        }
        laneIDs.sort()

        let perLaneResponses = laneIDs.map { _ in UnsafeSendableBox<[ObservedResponse<Spec.Command>]>([]) }
        let commandFailed = SendableBox(false)
        let timedOut = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        // `withValue`'s lock serializes appends into realized completion order.
        let completionOrdered = SendableBox<[ObservedResponse<Spec.Command>]>([])
        let group = DispatchGroup()

        // MEASUREMENT SCAFFOLDING — REMOVE BEFORE MERGE. Per-lane scheduling latency to classify timeouts.
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let laneStartedAt = laneIDs.map { _ in UnsafeSendableBox<UInt64?>(nil) }
        PreemptiveTimeoutStats.shared.recordProbe()

        for (offset, laneID) in laneIDs.enumerated() {
            let responseBox = perLaneResponses[offset]
            group.enter()
            DispatchQueue.global().async {
                laneStartedAt[offset].value = DispatchTime.now().uptimeNanoseconds
                var exception: NSException?
                nonisolated(unsafe) let spec = concurrentSpec
                let succeeded = exhaust_runCatchingObjCException({
                    let responses: [ObservedResponse<Spec.Command>]? = awaitOrTimeout("lane") {
                        var results: [ObservedResponse<Spec.Command>] = []
                        for (marker, command) in taggedCommands where marker.rawValue == laneID {
                            if commandFailed.value {
                                break
                            }
                            do {
                                let response = try await spec.run(command)
                                let outcome = response.returnValue.map(ObservedResponse<Spec.Command>.Outcome.returned) ?? .returnedVoid
                                let observed = ObservedResponse<Spec.Command>(lane: laneID, command: command, outcome: outcome)
                                results.append(observed)
                                completionOrdered.withValue { $0.append(observed) }
                            } catch is ContractSkip {
                                let observed = ObservedResponse<Spec.Command>(lane: laneID, command: command, outcome: .skipped)
                                results.append(observed)
                                completionOrdered.withValue { $0.append(observed) }
                            } catch {
                                commandFailed.value = true
                                break
                            }
                        }
                        return results
                    }
                    if let responses {
                        responseBox.value = responses
                    } else {
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
                recordPreemptiveTimeout(laneStartedAt: laneStartedAt, submittedAt: submittedAt, idleTimeoutMs: idleTimeoutMilliseconds)
                return .timedOut(concurrentSpec: nil)
            }
        } else {
            group.wait()
        }

        if caughtException.value != nil || commandFailed.value {
            if timedOut.value {
                if let idleTimeoutMilliseconds {
                    recordPreemptiveTimeout(laneStartedAt: laneStartedAt, submittedAt: submittedAt, idleTimeoutMs: idleTimeoutMilliseconds)
                }
                return .timedOut(concurrentSpec: nil)
            }
            return .failed(concurrentSpec: nil)
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
            return .timedOut(concurrentSpec: nil)
        }

        if invariantsPassed == false {
            return .failed(concurrentSpec: nil)
        }

        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
        // Void-only, no-skip commands carry no response data, so linearizability reduces to final-state equivalence.
        let hasResponseInfo = completionOrdered.value.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped }
        if hasResponseInfo == false {
            nonisolated(unsafe) let oracleSpec = concurrentSpec
            nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
            switch awaitOrTimeout("oracle", { await oracleSpec.oracleCheck(sequentialResult) }) {
                case .some(true):
                    return .passed
                case .none:
                    return .timedOut(concurrentSpec: nil)
                case .some(false):
                    return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
            }
        }
        // Try the realized completion order as a single linearization witness before the full interleaving search.
        if realizedOrderIsLinearizable(prefix: prefixCommands, realizedOrder: completionOrdered.value, concurrentSpec: concurrentSpec) {
            return .passed
        }
        return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Async counterpart of the synchronous witness check: replays the concurrent commands in realized completion order through the drain loop on a fresh spec.
    ///
    /// Returns `true` only when that single sequential order reproduces every observed response and the oracle's final state, which makes it a concrete linearization witness and lets the ``ContractMachine`` pass without the full interleaving search. A differing response, an oracle mismatch, a replay throw, an ObjC exception, or a drain timeout all return `false`, so the ``ContractMachine`` falls through to ``checkLinearizability(taggedCommands:laneResponses:concurrentSpec:)``.
    private func realizedOrderIsLinearizable(
        prefix: [Spec.Command],
        realizedOrder: [ObservedResponse<Spec.Command>],
        concurrentSpec: Spec
    ) -> Bool {
        let witnessSpec = Spec()
        nonisolated(unsafe) let unsafeWitness = witnessSpec
        nonisolated(unsafe) let unsafeConcurrent = concurrentSpec
        var matched = false
        var exception: NSException?
        let completed = exhaust_runCatchingObjCException({
            let result: Bool? = awaitOrTimeout("witness") {
                for command in prefix {
                    do {
                        try await unsafeWitness.run(command)
                    } catch is ContractSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                for observed in realizedOrder {
                    do {
                        let response = try await unsafeWitness.run(observed.command)
                        if preemptiveResponseMatches(observed: observed.outcome, replayValue: response.returnValue, replaySkipped: false) == false {
                            return false
                        }
                    } catch is ContractSkip {
                        if observed.outcome.isSkipped == false {
                            return false
                        }
                    } catch {
                        return false
                    }
                }
                return await unsafeConcurrent.oracleCheck(unsafeWitness.systemUnderTest)
            }
            matched = result ?? false
        }, &exception)
        return completed && exception == nil && matched
    }

    /// Reports whether a sequential command run succeeded or timed out.
    ///
    /// `timedOut` distinguishes a drain-loop idle bailout from a command that threw or trapped, so a hang in the prefix or sequential reference replay propagates to ``Preemptive/Outcome/timedOut`` rather than masquerading as a deterministic failure.
    struct SequentialOutcome {
        let succeeded: Bool
        let timedOut: Bool
    }

    /// Runs commands sequentially on a spec, bridging async execution via ``__ExhaustRuntime/blockingAwait(_:)``. Wraps in ObjC exception handling so NSExceptions from underlying C/ObjC code are caught rather than crashing the process.
    ///
    /// - Returns: A ``SequentialOutcome`` whose `succeeded` is `true` when all commands succeeded or were skipped, and whose `timedOut` is `true` only when the drain loop idled out (as opposed to a command throw or NSException).
    @discardableResult
    func runSequentially(_ commands: [Spec.Command], on spec: Spec) -> SequentialOutcome {
        var exception: NSException?
        var failed = false
        var timedOut = false
        nonisolated(unsafe) let spec = spec
        exhaust_runCatchingObjCException({
            let succeeded: Bool? = awaitOrTimeout("sequential") {
                for command in commands {
                    do {
                        try await spec.run(command)
                    } catch is ContractSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                return true
            }
            if let succeeded {
                failed = succeeded == false
            } else {
                failed = true
                timedOut = true
            }
        }, &exception)
        return SequentialOutcome(succeeded: exception == nil && failed == false, timedOut: timedOut)
    }

    /// Runs tagged commands sequentially on a spec, filtering by marker type to avoid intermediate array allocations.
    @discardableResult
    func runSequentially(
        _ taggedCommands: [(ScheduleMarker, Spec.Command)],
        selectPrefix: Bool,
        on spec: Spec
    ) -> SequentialOutcome {
        var exception: NSException?
        var failed = false
        var timedOut = false
        nonisolated(unsafe) let spec = spec
        exhaust_runCatchingObjCException({
            let succeeded: Bool? = awaitOrTimeout("sequential") {
                for (marker, command) in taggedCommands where marker.isPrefix == selectPrefix {
                    do {
                        try await spec.run(command)
                    } catch is ContractSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                return true
            }
            if let succeeded {
                failed = succeeded == false
            } else {
                failed = true
                timedOut = true
            }
        }, &exception)
        return SequentialOutcome(succeeded: exception == nil && failed == false, timedOut: timedOut)
    }

    func checkLinearizability(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        let prefixCommands: [Spec.Command] = taggedCommands.filter(\.0.isPrefix).map(\.1)
        let checker = LinearizabilityChecker(laneResponses: laneResponses)
        nonisolated(unsafe) let unsafeSpec = concurrentSpec
        let result: LinearizabilityChecker<Spec.Command>.Result = __ExhaustRuntime.blockingAwait {
            var replaySpec: Spec?
            return await checker.checkAsync(
                replayPrefix: {
                    let fresh = Spec()
                    for command in prefixCommands {
                        do {
                            try await fresh.run(command)
                        } catch is ContractSkip {
                            continue
                        } catch {
                            return false
                        }
                    }
                    replaySpec = fresh
                    return true
                },
                replayCommand: { command in
                    guard let spec = replaySpec else {
                        return nil
                    }
                    do {
                        let response = try await spec.run(command)
                        return .init(
                            returnValue: response.returnValue,
                            isSkipped: false
                        )
                    } catch is ContractSkip {
                        return .init(
                            returnValue: nil,
                            isSkipped: true
                        )
                    } catch {
                        return nil
                    }
                },
                checkOracle: {
                    guard let spec = replaySpec else {
                        return false
                    }
                    return await unsafeSpec.oracleCheck(spec.systemUnderTest)
                },
                failureDescription: {
                    unsafeSpec.failureDescription()
                }
            )
        }
        return makeLinearizabilityResult(result, laneObservations: laneResponses)
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

    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, timedOut: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
        let spec = Spec()
        nonisolated(unsafe) let unsafeSpec = spec
        let work: @Sendable () async -> ([TraceStep], Bool) = {
            await __ExhaustRuntime.buildAsyncSequentialTrace(
                commands,
                run: { try await unsafeSpec.run($0) },
                checkInvariants: { try await unsafeSpec.checkInvariants() }
            )
        }
        guard let (trace, failed) = awaitOrTimeout("smoke", timeoutMultiplier: 5, work) else {
            return ([], true, true, spec.systemUnderTest, spec.failureDescription())
        }
        if failed {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        // A .threads spec expresses its self-consistency check through the @Oracle, because the macro rejects @Invariant under .threads, and smoke never runs the concurrent phase.
        // Replay the sequence on a fresh reference and call the oracle once at the end, so a spec that is already broken under sequential execution fails here before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let reference = Spec()
        nonisolated(unsafe) let unsafeReference = reference
        let referenceFailed: Bool? = awaitOrTimeout("smoke-reference", timeoutMultiplier: 5) {
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
        // nil = timed out waiting for reference replay
        if referenceFailed == nil {
            return (trace, true, true, spec.systemUnderTest, spec.failureDescription())
        }
        if referenceFailed == true {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        nonisolated(unsafe) let referenceResult = reference.systemUnderTest
        nonisolated(unsafe) let oracleSpec = spec
        let oracleHeld = awaitOrTimeout("smoke-oracle", timeoutMultiplier: 5) {
            await oracleSpec.oracleCheck(referenceResult)
        }
        // nil = timed out waiting for oracle check
        if oracleHeld == nil {
            return (trace, true, true, spec.systemUnderTest, spec.failureDescription())
        }
        if oracleHeld == false {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        return (trace, false, false, spec.systemUnderTest, nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec via ``runSequentially(_:on:)`` to capture the oracle SUT state. Returns nil ``ContractResult/systemUnderTest`` when the sequential replay itself fails or times out, because the partial state would mislead debugging.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> (result: ContractResult<Spec>, failureDescription: String?) {
        let oracleSpec = Spec()
        let replayOutcome = runSequentially(reduced.map(\.1), on: oracleSpec)
        let result = ContractResult<Spec>(
            status: .fail,
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            trace: __ExhaustRuntime.buildPreemptiveTrace(reduced),
            systemUnderTest: replayOutcome.succeeded ? oracleSpec.systemUnderTest : nil,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
        return (result, replayOutcome.succeeded ? oracleSpec.failureDescription() : nil)
    }
}
