// Async preemptive concurrent spec runner.
//
// Async variant of the preemptive runner for AsyncStateMachineSpec conformances.
// Bridges async command execution to GCD threads via Task+semaphore to catch races in synchronous primitives hidden behind async facades.
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(ObjectiveC)
    import ExhaustObjCSupport
#endif

// MARK: - Async Entry Point

public extension __ExhaustRuntime {
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

        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runPreemptiveMachine(
                    innerBackend: innerBackend,
                    config: config,
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

// MARK: - Async Checker

/// Bridges async command execution to GCD threads via Task+semaphore.
///
/// Each lane gets a real OS thread, and within that thread async commands are driven synchronously. The cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncStateMachineSpec>: PreemptiveBackend {
    /// Idle-timeout bound (milliseconds) for the blocking drain loop, or `nil` to wait unbounded. A command that suspends onto a foreign executor never returns to the drain lane; without this bound the loop spins a CPU core forever.
    let idleTimeoutMilliseconds: Int?

    /// Interleaving searches this run abandoned for exceeding their replay budget, counted so the runner can warn about probes it passed without judging.
    var searchAbandonments = UnsafeSendableBox(0)

    /// Interleaving searches this run gave up on because their drain loop stalled, kept apart from the run's probe tally.
    ///
    /// A stall here happens inside failure classification, which runs during reduction and final confirmation as well as during discovery, and only discovery increments the probe tally. Counting these as timed-out probes could therefore report more timeouts than probes, so they are reported as their own count alongside the budget-exhausted searches.
    var searchStalls = UnsafeSendableBox(0)

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

    /// Executes a tagged command sequence with real GCD concurrency and checks the oracle.
    ///
    /// The sequential phases (setup on both instances, the prefix on the concurrent spec, and the prefix and concurrent commands on the sequential reference with invariants checked after each command) are bridged through a single Task+semaphore. Concurrent commands are dispatched to real GCD threads, one per lane, each bridging async execution independently, and all of them run on the one concurrent instance.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], setupStep: Spec.SetupStep?, partition: LanePartition) -> Preemptive.Outcome<Spec> {
        // Construction is synchronous here because both instances are needed for outcome evidence; the async setup application happens inside the sequential-phases bridge below, before any prefix command, so both instances receive the same setup ahead of the lanes.
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let sequentialPhases = runSequentialPhases(
            taggedCommands,
            setupStep: setupStep,
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
        let rendezvous = LaneRendezvous(laneCount: partition.laneIDs.count)
        nonisolated(unsafe) let spec = concurrentSpec
        for (offset, laneID) in partition.laneIDs.enumerated() {
            let laneIndices = partition.laneBuckets[laneID] ?? []
            let responseBox = perLaneResponses[offset]
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    let responses: [ObservedResponse<Spec.Command>]? = awaitOrTimeout("lane") {
                        // Rendezvous inside the bridged task rather than at the top of the GCD block, so the per-lane drain-loop setup skew is also absorbed before the first command. On the macOS 15+ drain-loop path the task runs on this lane's own GCD thread, so the spin never occupies the cooperative pool.
                        rendezvous.arriveAndWait()
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
                            } catch is StateMachineSkip {
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

        // No invariant check on the concurrent instance here. After the lanes have raced, a model-versus-system comparison on that instance is order-dependent by construction, whether or not the model is synchronized: an invariant is a claim that holds whatever order the commands ran in, and this state is one particular order's outcome that nothing has established was a valid one. Invariants under thread-based execution are judged only where a single command runs at a time (ADR 0004): the reference replay in the sequential phases, and the replays inside the interleaving search below.
        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        // Void-only, no-skip commands carry no response data, so linearizability reduces to final-state equivalence.
        let hasResponseInfo = collectedResponses.contains { lane in lane.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped } }
        if hasResponseInfo == false {
            nonisolated(unsafe) let oracleSpec = concurrentSpec
            nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
            switch awaitOrTimeout("oracle", { await oracleSpec.equivalenceCheck(sequentialResult) }) {
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
        if realizedOrderIsLinearizable(prefix: prefixCommands, setupStep: setupStep, realizedOrder: realizedCompletionOrder(of: collectedResponses), concurrentSpec: concurrentSpec) {
            return .passed
        }
        return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Async counterpart of the synchronous witness check: replays the concurrent commands in realized completion order through the drain loop on a fresh spec.
    ///
    /// Returns `true` only when that single sequential order reproduces every observed response and the oracle's final state, which makes it a concrete linearization witness and lets the ``SpecMachine`` pass without the full interleaving search. A differing response, an oracle mismatch, a replay throw, an ObjC exception, or a drain timeout all return `false`, so the ``SpecMachine`` falls through to ``checkLinearizability(taggedCommands:laneResponses:concurrentSpec:)``.
    private func realizedOrderIsLinearizable(
        prefix: [Spec.Command],
        setupStep: Spec.SetupStep?,
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
                guard await unsafeWitness.applySetup(setupStep) == nil else {
                    return false
                }
                for command in prefix {
                    do {
                        try await unsafeWitness.run(command)
                    } catch is StateMachineSkip {
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
                        // An invariant that fails on this order disqualifies it as an explanation of what the lanes did, the same as a response that does not match. The full search then decides whether any other order explains the run.
                        try await unsafeWitness.checkInvariants()
                    } catch is StateMachineSkip {
                        if observed.outcome.isSkipped == false {
                            return false
                        }
                    } catch {
                        return false
                    }
                }
                return await unsafeConcurrent.equivalenceCheck(unsafeWitness.systemUnderTest)
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
    func runSequentially(_ commands: [Spec.Command], setupStep: Spec.SetupStep?, on spec: Spec) -> SequentialOutcome {
        var exception: NSException?
        var failed = false
        var timedOut = false
        nonisolated(unsafe) let spec = spec
        exhaust_runCatchingObjCException({
            let succeeded: Bool? = awaitOrTimeout("sequential") {
                guard await spec.applySetup(setupStep) == nil else {
                    return false
                }
                for command in commands {
                    do {
                        try await spec.run(command)
                    } catch is StateMachineSkip {
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

    /// Runs the sequential phases of a probe — setup on the concurrent and reference instances, the prefix on the concurrent spec, then the prefix and the concurrent commands on the sequential reference with invariants checked after each command — under a single Task+semaphore bridge.
    ///
    /// One bridge replaces the separate `blockingAwait` round-trips these phases used to pay per probe. On the drain-loop path (macOS 15 and later) the timeout semantics are unchanged, because the bound measures idle time since the last drained job and resets across phases. On the semaphore fallback, the bound is total wall-clock, so the phases share one window instead of getting one each; a slow-but-genuine sequential replay on an older platform trips the timeout (and counts as a pass) sooner than before.
    ///
    /// The reference replay checks invariants after every command, and the prefix on the concurrent instance does not: the same commands run in the same order on the reference, so a second pass would reach the same verdict twice. An invariant that fails on the reference is a sequentially-reproducible failure, which the caller reports directly without an oracle comparison or an interleaving search.
    private func runSequentialPhases(
        _ taggedCommands: [(ScheduleMarker, Spec.Command)],
        setupStep: Spec.SetupStep?,
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
                        } catch is StateMachineSkip {
                            continue
                        } catch {
                            return false
                        }
                    }
                    return true
                }
                func runCheckingInvariants(_ indices: [Int], on spec: Spec) async -> Bool {
                    for index in indices {
                        do {
                            try await spec.run(taggedCommands[index].1)
                            try await spec.checkInvariants()
                        } catch is StateMachineSkip {
                            continue
                        } catch {
                            return false
                        }
                    }
                    return true
                }
                guard await concurrentSpec.applySetup(setupStep) == nil else {
                    return false
                }
                guard await sequentialSpec.applySetup(setupStep) == nil else {
                    return false
                }
                guard await run(partition.prefixIndices, on: concurrentSpec) else {
                    return false
                }
                guard await runCheckingInvariants(partition.prefixIndices, on: sequentialSpec) else {
                    return false
                }
                return await runCheckingInvariants(partition.concurrentIndices, on: sequentialSpec)
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
        setupStep: Spec.SetupStep?,
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        let prefixCommands: [Spec.Command] = taggedCommands.filter(\.0.isPrefix).map(\.1)
        nonisolated(unsafe) let unsafeSpec = concurrentSpec
        // The search replays setup and commands on fresh specs, so a continuation that escapes to a foreign executor parks this lane exactly as it would in any other phase. The multiplier is generous because one bound covers the whole search rather than a single probe: on the drain-loop path it measures idle time since the last drained job, so a long-but-progressing search never trips it. On the semaphore fallback the bound is total wall clock, so a search that legitimately runs past it is abandoned.
        let result: LinearizabilityResult? = awaitOrTimeout("linearizability", timeoutMultiplier: 10) {
            await searchForExplainingOrder(
                concurrentSpec: unsafeSpec,
                setupStep: setupStep,
                prefixCommands: prefixCommands,
                laneResponses: laneResponses,
                replay: .asynchronous
            )
        }
        guard let result else {
            // The drain loop idled out mid-search, which is a stall rather than an exhausted budget. Report linearizable so the probe counts as a pass, matching the rule that an inconclusive probe never manufactures a failure, and tally it so the unjudged-search warning can report it.
            searchStalls.value += 1
            return .linearizable
        }
        if result.isAbandoned {
            searchAbandonments.value += 1
        }
        return result
    }

    func makeIdentifySkips() -> @Sendable (SpecCandidateValue<Spec>) -> Set<Int> {
        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let rawIdentifySkips = Spec.skipIdentifier(
            specInit: specInit,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        return { candidate in
            // Skip identification replays the commands on a fresh spec via a blocking drain, outside the ObjC guard that wraps lane execution. A synchronously-thrown NSException would otherwise propagate out of the drain and abort, so degrade to "no skips identified" (pruning becomes a no-op and the actual execution catches and reports it).
            var skipped: Set<Int> = []
            var exception: NSException?
            let completed = exhaust_runCatchingObjCException({
                skipped = rawIdentifySkips(candidate.setupStep, candidate.taggedCommands.map(\.1))
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
    func runSmoke(_ commands: [Spec.Command], setupStep: Spec.SetupStep?) -> (trace: [TraceStep], failed: Bool, timedOut: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
        let spec = Spec()
        nonisolated(unsafe) let unsafeSpec = spec
        let work: @Sendable () async -> ([TraceStep], Bool) = {
            let (setupTrace, setupFailed) = await __ExhaustRuntime.applySetupRecordingTrace(unsafeSpec, setupStep: setupStep)
            if setupFailed {
                return (setupTrace, true)
            }
            let (commandTrace, commandsFailed) = await __ExhaustRuntime.buildAsyncSequentialTrace(
                commands,
                run: { try await unsafeSpec.run($0) },
                checkInvariants: { try await unsafeSpec.checkInvariants() }
            )
            return (__ExhaustRuntime.joinTrace(setup: setupTrace, commands: commandTrace), commandsFailed)
        }
        guard let (trace, failed) = awaitOrTimeout("smoke", timeoutMultiplier: 5, work) else {
            return ([], true, true, spec.systemUnderTest, spec.failureDescription())
        }
        if failed {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        // The trace above already checked invariants after every command. The oracle is the other half of what a spec can claim, and smoke never runs the concurrent phase, so it is called here: replay the sequence on a fresh reference and compare once at the end, so a spec that is already broken under sequential execution fails before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let reference = Spec()
        nonisolated(unsafe) let unsafeReference = reference
        let referenceFailed: Bool? = awaitOrTimeout("smoke-reference", timeoutMultiplier: 5) {
            if await unsafeReference.applySetup(setupStep) != nil {
                return true
            }
            for command in commands {
                do {
                    try await unsafeReference.run(command)
                } catch is StateMachineSkip {
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
            await oracleSpec.equivalenceCheck(referenceResult)
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

    /// Replays the reduced commands sequentially on a fresh spec (with setup applied) via ``runSequentially(_:setupStep:on:)`` and returns its failure description, the expected race-free state for the report. Returns nil when the replay itself fails or times out, because the partial state would mislead debugging.
    func sequentialReplayDescription(of reduced: [(ScheduleMarker, Spec.Command)], setupStep: Spec.SetupStep?) -> String? {
        let oracleSpec = Spec()
        guard runSequentially(reduced.map(\.1), setupStep: setupStep, on: oracleSpec).succeeded else {
            return nil
        }
        return oracleSpec.failureDescription()
    }

    func setupTraceSteps(_ setupStep: Spec.SetupStep?) -> [TraceStep] {
        guard let setupStep else {
            return []
        }
        let spec = Spec()
        nonisolated(unsafe) let unsafeSpec = spec
        let steps: [TraceStep]? = awaitOrTimeout("setup-trace") {
            await __ExhaustRuntime.applySetupRecordingTrace(unsafeSpec, setupStep: setupStep).steps
        }
        // On a drain timeout the outcome is unknown; keep the row without a failure claim rather than dropping it.
        return steps ?? [__ExhaustRuntime.setupTraceStep(setupStep, setupError: nil)]
    }
}
