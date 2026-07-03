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
    /// The outer loop runs on a GCD thread (via ``__ExhaustRuntime/dispatchToGCD(reserving:_:)``) to avoid starving the cooperative pool during parallel test runs. Issue reporting is deferred to the async return context where Swift Testing's task-locals are available.
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
        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) {
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
    /// The three sequential phases (prefix on the concurrent spec, prefix and concurrent commands on the sequential reference) are bridged through a single Task+semaphore. Concurrent commands are dispatched to real GCD threads (one per lane), each bridging async execution independently.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], partition: LanePartition) -> Preemptive.Outcome<Spec> {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let sequentialPhases = runSequentialPhases(
            taggedCommands,
            partition: partition,
            concurrentSpec: concurrentSpec,
            sequentialSpec: sequentialSpec
        )
        if sequentialPhases.succeeded == false {
            return sequentialPhases.timedOut ? .timedOut(concurrentSpec: concurrentSpec) : .failed(concurrentSpec: concurrentSpec)
        }

        let perLaneResponses = partition.laneIDs.map { _ in UnsafeSendableBox<[ObservedResponse<Spec.Command>]>([]) }
        let commandFailed = SendableBox(false)
        let timedOut = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()

        // Observation stays lane-local on purpose: a shared, locked log on the command path would serialize the lanes between commands and flush caches, which both narrows the interleavings the probe can realize and can mask the memory-visibility bugs this runner exists to catch (Lowe, "Testing for Linearizability", section 7.1). Cross-lane ordering is reconstructed afterwards from the per-command timestamps.
        for (offset, laneID) in partition.laneIDs.enumerated() {
            let laneIndices = partition.laneBuckets[laneID] ?? []
            let responseBox = perLaneResponses[offset]
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                nonisolated(unsafe) let spec = concurrentSpec
                let succeeded = exhaust_runCatchingObjCException({
                    let responses: [ObservedResponse<Spec.Command>]? = awaitOrTimeout("lane") {
                        var results: [ObservedResponse<Spec.Command>] = []
                        for laneIndex in laneIndices {
                            if commandFailed.value {
                                break
                            }
                            let command = taggedCommands[laneIndex].1
                            let callTime = DispatchTime.now().uptimeNanoseconds
                            do {
                                let response = try await spec.run(command)
                                let returnTime = DispatchTime.now().uptimeNanoseconds
                                let outcome = response.returnValue.map(ObservedResponse<Spec.Command>.Outcome.returned) ?? .returnedVoid
                                let observed = ObservedResponse<Spec.Command>(
                                    lane: laneID,
                                    command: command,
                                    outcome: outcome,
                                    interval: ObservedInterval(callTime: callTime, returnTime: returnTime)
                                )
                                results.append(observed)
                            } catch is ContractSkip {
                                let returnTime = DispatchTime.now().uptimeNanoseconds
                                let observed = ObservedResponse<Spec.Command>(
                                    lane: laneID,
                                    command: command,
                                    outcome: .skipped,
                                    interval: ObservedInterval(callTime: callTime, returnTime: returnTime)
                                )
                                results.append(observed)
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
                return .timedOut(concurrentSpec: concurrentSpec)
            }
        } else {
            group.wait()
        }

        if caughtException.value != nil || commandFailed.value {
            return timedOut.value ? .timedOut(concurrentSpec: concurrentSpec) : .failed(concurrentSpec: concurrentSpec)
        }

        nonisolated(unsafe) let invariantSpec = concurrentSpec
        guard let invariantsPassed = awaitOrTimeout("invariants", {
            do {
                try await invariantSpec.checkInvariants()
                return true
            } catch {
                return false
            }
        }) else {
            return .timedOut(concurrentSpec: concurrentSpec)
        }

        if invariantsPassed == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        // Void-only, no-skip commands carry no response data, so linearizability reduces to final-state equivalence.
        let hasResponseInfo = collectedResponses.contains { lane in lane.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped } }
        if hasResponseInfo == false {
            nonisolated(unsafe) let oracleSpec = concurrentSpec
            nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
            switch awaitOrTimeout("oracle", { await oracleSpec.oracleCheck(sequentialResult) }) {
                case .some(true):
                    return .passed
                case .none:
                    return .timedOut(concurrentSpec: concurrentSpec)
                case .some(false):
                    return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
            }
        }
        // Try the realized completion order as a single linearization witness before the full interleaving search. The prefix array is materialized only here — the passed and no-response-info paths never need it.
        let prefixCommands = partition.prefixIndices.map { taggedCommands[$0].1 }
        if realizedOrderIsLinearizable(prefix: prefixCommands, realizedOrder: realizedCompletionOrder(of: collectedResponses), concurrentSpec: concurrentSpec) {
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

    /// Runs the three sequential phases of a probe — the prefix on the concurrent spec, then the prefix and the concurrent commands on the sequential reference — under a single Task+semaphore bridge.
    ///
    /// One bridge replaces the three separate `blockingAwait` round-trips these phases used to pay per probe. On the drain-loop path (macOS 15 and later) the timeout semantics are unchanged, because the bound measures idle time since the last drained job and resets across phases. On the semaphore fallback, the bound is total wall-clock, so the three phases now share one window instead of getting one each; a slow-but-genuine sequential replay on an older platform trips the timeout (and counts as a pass) sooner than before.
    private func runSequentialPhases(
        _ taggedCommands: [(ScheduleMarker, Spec.Command)],
        partition: LanePartition,
        concurrentSpec: Spec,
        sequentialSpec: Spec
    ) -> SequentialOutcome {
        var exception: NSException?
        var failed = false
        var timedOut = false
        nonisolated(unsafe) let concurrentSpec = concurrentSpec
        nonisolated(unsafe) let sequentialSpec = sequentialSpec
        exhaust_runCatchingObjCException({
            let succeeded: Bool? = awaitOrTimeout("sequential") {
                func run(_ indices: [Int], on spec: Spec) async -> Bool {
                    for index in indices {
                        do {
                            try await spec.run(taggedCommands[index].1)
                        } catch is ContractSkip {
                            continue
                        } catch {
                            return false
                        }
                    }
                    return true
                }
                guard await run(partition.prefixIndices, on: concurrentSpec) else {
                    return false
                }
                guard await run(partition.prefixIndices, on: sequentialSpec) else {
                    return false
                }
                return await run(partition.concurrentIndices, on: sequentialSpec)
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
        let result: LinearizabilityChecker.Result = __ExhaustRuntime.blockingAwait {
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
                replayCommand: { laneIndex, commandIndex in
                    guard let spec = replaySpec else {
                        return nil
                    }
                    do {
                        let response = try await spec.run(laneResponses[laneIndex][commandIndex].command)
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

    // MARK: - Async Smoke and NSExceptions

    //
    // No ObjC exception guard (`exhaust_runCatchingObjCException`) here, unlike the synchronous `PreemptiveChecker.runSmoke(_:)`. The sync checker wraps each `spec.run(command)` in an ObjC `@try/@catch` because there are no Tasks involved, everything is plain function frames. In the async path, each command runs inside a Task drained by `blockingAwait`. An NSException that unwinds through a Task continuation bypasses the Swift runtime's task-local allocation cleanup (`swift_task_dealloc_specific`): the ObjC `@try/@catch` catches the exception, but the Task's internal state is already corrupted, and the runtime aborts on the next task-local operation. This is a Swift runtime limitation. NSExceptions and Task-local storage are fundamentally incompatible.

    /// Runs the smoke commands sequentially on a fresh spec, without the sync checker's ObjC exception guard.
    ///
    /// - Important: An async spec whose command deterministically raises an NSException will abort the test process. See the implementation note above.
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

    /// Replays the reduced commands sequentially on a fresh spec via ``runSequentially(_:on:)`` and returns its failure description, the expected race-free state for the report. Returns nil when the replay itself fails or times out, because the partial state would mislead debugging.
    func sequentialReplayDescription(of reduced: [(ScheduleMarker, Spec.Command)]) -> String? {
        let oracleSpec = Spec()
        guard runSequentially(reduced.map(\.1), on: oracleSpec).succeeded else {
            return nil
        }
        return oracleSpec.failureDescription()
    }
}
