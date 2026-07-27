// Preemptive concurrent spec runner.
//
// Based on eqc_par_statem from Claessen et al., "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work generates a sequential prefix followed by concurrent command groups, then compares the concurrent outcome against a sequential oracle. PULSE adds deterministic replay via a user-level scheduler; this runner omits replay and relies on OS thread scheduling for non-deterministic interleaving, compensating with repetition across the sampling budget.
//
// The cooperative runner (CooperativeConcurrentStateMachineRunner) implements the PULSE half, a TaskExecutor-based drain loop that makes interleavings deterministic and reducible. This runner targets bugs that require real thread-level preemption: races in locks, dispatch queues, and atomics that are invisible at `await` suspension points.
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(ObjectiveC)
    import ExhaustObjCSupport
#endif

// MARK: - Runner Entry Point

public extension __ExhaustRuntime {
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
        let (result, deferredIssues): (StateMachineResult<Spec>?, [String]) = await dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) {
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
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return result
    }
}

// MARK: - Machine Pipeline

extension __ExhaustRuntime {
    static func runPreemptiveMachine<Inner: PreemptiveBackend>(
        innerBackend: Inner,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        timeoutProbeCounts: UnsafeSendableBox<(attempts: Int, timedOut: Int)>,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: StateMachineResult<Inner.Spec>?, deferredIssues: [String]) {
        typealias Spec = Inner.Spec
        var deferredIssues: [String] = []

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? ConcurrentSpecTunables.defaultCommandLimit

        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            return (nil, deferredIssues)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let identifySkips = innerBackend.makeIdentifySkips()

        let backend = PreemptiveStateMachineBackend(
            inner: innerBackend,
            concurrencyLevel: config.concurrencyLevel
        )

        let invocationCounter = UnsafeSendableBox(0)
        let property: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            invocationCounter.value += 1
            timeoutProbeCounts.value.attempts += 1
            let partition = LanePartition(markers: candidate.taggedCommands.map(\.0))
            let outcome = innerBackend.execute(candidate.taggedCommands, setupStep: candidate.setupStep, partition: partition)
            if case .timedOut = outcome {
                // A timed-out probe is inconclusive, not a counterexample: under host contention the lanes simply did not finish in time. Count it as a pass so discovery keeps sampling, and tally it so the runner can warn when timeouts dominate the budget.
                timeoutProbeCounts.value.timedOut += 1
                return true
            }
            return classifyFailure(
                taggedCommands: candidate.taggedCommands,
                setupStep: candidate.setupStep,
                outcome: outcome,
                backend: innerBackend
            ) == nil
        }

        let smokeProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            invocationCounter.value += 1
            timeoutProbeCounts.value.attempts += 1
            let smoke = innerBackend.runSmoke(candidate.taggedCommands.map(\.1), setupStep: candidate.setupStep)
            if smoke.timedOut {
                timeoutProbeCounts.value.timedOut += 1
                return true
            }
            return smoke.failed == false
        }
        // Smoke runs commands sequentially, so generate concurrency-1 (all-prefix) sequences. The candidate then carries this generator and reduces sequentially even when the run uses multiple lanes.
        let smokeSequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
        if let sequentialCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: 1) {
            smokeSequenceGen = Gen.arrayOf(sequentialCommandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
        } else {
            smokeSequenceGen = sequenceGen
        }
        let smokeSource: AnyStateMachineCandidateSource<Spec>? = .smoke(
            sequenceGen: smokeSequenceGen,
            property: smokeProperty
        )

        let pipeline = SpecPipeline(
            backend: backend,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            concurrencyLevel: config.concurrencyLevel,
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

// MARK: - Trace Building

extension __ExhaustRuntime {
    /// Builds a trace from a preemptive execution's reduced command sequence in input order.
    ///
    /// Lane commands are annotated with the value they returned (from `laneResponseValues`, keyed by lane and per-lane order) rather than a completion marker: the runner does not track suspension points, so a `(completed)` marker would assert ordering information it does not have, whereas the return value is observable and is where a response-level violation shows.
    ///
    /// When `linearizabilityWitness` identifies a lane command, that step is marked as the one whose response no valid ordering reproduces.
    static func buildPreemptiveTrace(
        _ reduced: [(ScheduleMarker, some CustomStringConvertible)],
        setupSteps: [TraceStep] = [],
        laneResponseValues: [UInt8: [String?]]? = nil,
        linearizabilityWitness: ResponseWitness? = nil
    ) -> [TraceStep] {
        var laneCounts: [UInt8: Int] = [:]
        let commandSteps = reduced.enumerated().map { index, tagged -> TraceStep in
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
                let values = laneResponseValues?[marker.rawValue]
                let annotation = if let values, laneIndex - 1 < values.count, let value = values[laneIndex - 1] {
                    " → \(value)"
                } else {
                    ""
                }
                let isWitness = linearizabilityWitness?.lane == marker.rawValue && linearizabilityWitness?.index == laneIndex - 1
                let witnessMarker = isWitness ? linearizabilityWitnessMarker : ""
                return TraceStep(
                    index: index + 1,
                    command: "\(laneIndex)\(laneLabel) \(command)\(annotation)\(witnessMarker)",
                    outcome: .ok
                )
            }
        }
        return joinTrace(setup: setupSteps, commands: commandSteps)
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

/// Runs each probe directly on GCD threads and compares against a sequential oracle.
///
/// Internal rather than private so tests can drive one probe and read its outcome, the way the cooperative tests call `drainSchedule` directly. A thread-based probe's verdict is not recoverable from a pipeline run: the pipeline reduces, repeats, and reports, and the distinction between a sequentially-reproducible failure and an ordering violation is visible only in the outcome this type returns.
struct PreemptiveChecker<Spec: StateMachineSpec>: PreemptiveBackend {
    /// Idle bound for the concurrent lanes, or `nil` to wait indefinitely. Without a bound, a synchronous SUT deadlock (the exact bug class preemptive testing targets) would wedge a lane forever and hang the test process with no diagnostic.
    let idleTimeoutMilliseconds: Int?

    /// Interleaving searches this run abandoned for exceeding their replay budget, counted so the runner can warn about probes it passed without judging. Tests that drive a probe directly supply their own.
    var searchAbandonments = UnsafeSendableBox(0)

    /// Executes a tagged command sequence with real GCD concurrency using a pre-computed lane partition.
    ///
    /// Returns ``Preemptive/Outcome/failed(concurrentSpec:)`` when a command throws, an invariant fails, or an ObjC exception is caught. Returns ``Preemptive/Outcome/timedOut(concurrentSpec:)`` when the concurrent lanes do not finish within ``idleTimeoutMilliseconds``, so the ``SpecMachine`` can skip reduction and report a hang rather than a deterministic failure.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], setupStep: Spec.SetupStep?, partition: LanePartition) -> Preemptive.Outcome<Spec> {
        // Both instances receive the same setup ahead of the prefix commands, or the oracle comparison is meaningless. A setup throw fails the probe.
        let (concurrentSpec, concurrentSetupError) = Spec.makeSpec(setupStep: setupStep)
        if concurrentSetupError != nil {
            return .failed(concurrentSpec: concurrentSpec)
        }
        let (sequentialSpec, sequentialSetupError) = Spec.makeSpec(setupStep: setupStep)
        if sequentialSetupError != nil {
            return .failed(concurrentSpec: concurrentSpec)
        }

        if runCommandsCatchingObjC(at: partition.prefixIndices, in: taggedCommands, on: concurrentSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }
        // The reference replay checks invariants after every command; the prefix on the concurrent instance above does not, because these same commands run here in the same order and a second pass would report the same verdict twice.
        if runCommandsCheckingInvariants(at: partition.prefixIndices, in: taggedCommands, on: sequentialSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        if runCommandsCheckingInvariants(at: partition.concurrentIndices, in: taggedCommands, on: sequentialSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        let perLaneResponses = partition.laneIDs.map { _ in UnsafeSendableBox<[ObservedResponse<Spec.Command>]>([]) }
        let commandFailed = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()

        // Observation stays lane-local on purpose: a shared, locked log on the command path would serialize the lanes between commands and flush caches, which both narrows the interleavings the probe can realize and can mask the memory-visibility bugs this runner exists to catch (Lowe, "Testing for Linearizability", section 7.1). Cross-lane ordering is reconstructed afterwards from the per-command timestamps.
        nonisolated(unsafe) let unsafeConcurrentSpec = concurrentSpec
        let rendezvous = LaneRendezvous(laneCount: partition.laneIDs.count)
        for (offset, laneID) in partition.laneIDs.enumerated() {
            let laneIndices = partition.laneBuckets[laneID] ?? []
            let responseBox = perLaneResponses[offset]
            group.enter()
            DispatchQueue.global().async {
                rendezvous.arriveAndWait()
                var localResponses: [ObservedResponse<Spec.Command>] = []
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    for laneIndex in laneIndices {
                        if commandFailed.value {
                            break
                        }
                        let command = taggedCommands[laneIndex].1
                        let callTime = DispatchTime.now().uptimeNanoseconds
                        do {
                            let response = try unsafeConcurrentSpec.run(command)
                            let returnTime = DispatchTime.now().uptimeNanoseconds
                            let outcome = response.returnValue.map(ObservedResponse<Spec.Command>.Outcome.returned) ?? .returnedVoid
                            let observed = ObservedResponse<Spec.Command>(
                                lane: laneID,
                                command: command,
                                outcome: outcome,
                                interval: ObservedInterval(callTime: callTime, returnTime: returnTime)
                            )
                            localResponses.append(observed)
                        } catch is StateMachineSkip {
                            let returnTime = DispatchTime.now().uptimeNanoseconds
                            let observed = ObservedResponse<Spec.Command>(
                                lane: laneID,
                                command: command,
                                outcome: .skipped,
                                interval: ObservedInterval(callTime: callTime, returnTime: returnTime)
                            )
                            localResponses.append(observed)
                        } catch {
                            commandFailed.value = true
                            break
                        }
                    }
                }, &exception)
                if succeeded == false {
                    caughtException.value = exception
                }
                responseBox.value = localResponses
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
            return .failed(concurrentSpec: concurrentSpec)
        }

        // No invariant check on the concurrent instance here. After the lanes have raced, a model-versus-system comparison on that instance is order-dependent by construction, whether or not the model is synchronized: an invariant is a claim that holds whatever order the commands ran in, and this state is one particular order's outcome that nothing has established was a valid one. Invariants under thread-based execution are judged only where a single command runs at a time (ADR 0004): the reference replay above, and the replays inside the interleaving search below.
        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        // Void-only, no-skip commands carry no response data, so linearizability reduces to final-state equivalence.
        let hasResponseInfo = collectedResponses.contains { lane in lane.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped } }
        if hasResponseInfo == false {
            if concurrentSpec.equivalenceCheck(sequentialSpec.systemUnderTest) {
                return .passed
            }
            return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
        }
        // Try the realized completion order as a single linearization witness before the full interleaving search. The prefix array is materialized only here — the passed and no-response-info paths never need it.
        let prefixCommands = partition.prefixIndices.map { taggedCommands[$0].1 }
        if realizedOrderIsLinearizable(prefix: prefixCommands, setupStep: setupStep, realizedOrder: realizedCompletionOrder(of: collectedResponses), concurrentSpec: concurrentSpec) {
            return .passed
        }
        return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Whether the realized completion order is a valid linearization: a sequential replay of the concurrent commands in the order the lanes finished, on a fresh spec, that reproduces every observed response and the oracle's final state.
    ///
    /// A match means the execution is linearizable (this order is a concrete witness), so the ``SpecMachine`` can pass without the full interleaving search.
    /// Any divergence (a differing response, an oracle mismatch, a replay throw, an ObjC exception, or a setup error) returns `false`, and the ``SpecMachine`` hands the per-lane responses to ``checkLinearizability(taggedCommands:setupStep:laneResponses:concurrentSpec:)``.
    /// The check is sound: it only reports a pass when an actual sequential order reproduces the observation.
    private func realizedOrderIsLinearizable(
        prefix: [Spec.Command],
        setupStep: Spec.SetupStep?,
        realizedOrder: [ObservedResponse<Spec.Command>],
        concurrentSpec: Spec
    ) -> Bool {
        let (witnessSpec, witnessSetupError) = Spec.makeSpec(setupStep: setupStep)
        guard witnessSetupError == nil else {
            return false
        }
        var matched = false
        var exception: NSException?
        let completed = exhaust_runCatchingObjCException({
            for command in prefix {
                do {
                    try witnessSpec.run(command)
                } catch is StateMachineSkip {
                    continue
                } catch {
                    return
                }
            }
            for observed in realizedOrder {
                do {
                    let response = try witnessSpec.run(observed.command)
                    if preemptiveResponseMatches(observed: observed.outcome, replayValue: response.returnValue, replaySkipped: false) == false {
                        return
                    }
                    // An invariant that fails on this order disqualifies it as an explanation of what the lanes did, the same as a response that does not match. The full search then decides whether any other order explains the run.
                    try witnessSpec.checkInvariants()
                } catch is StateMachineSkip {
                    if observed.outcome.isSkipped == false {
                        return
                    }
                } catch {
                    return
                }
            }
            matched = concurrentSpec.equivalenceCheck(witnessSpec.systemUnderTest)
        }, &exception)
        return completed && exception == nil && matched
    }

    /// Runs all commands on a spec under a single ObjC exception guard, treating ``StateMachineSkip`` as a pass.
    private func runAllCommandsCatchingObjC(_ commands: [Spec.Command], on spec: Spec) -> Bool {
        var commandFailed = false
        let objcSucceeded = runCatchingObjC {
            for command in commands {
                do {
                    try spec.run(command)
                } catch is StateMachineSkip {
                    continue
                } catch {
                    commandFailed = true
                    return
                }
            }
        }
        return objcSucceeded && commandFailed == false
    }

    /// Index-bucket twin of ``runAllCommandsCatchingObjC(_:on:)``: runs the commands at the partition-supplied positions without materializing a command array.
    private func runCommandsCatchingObjC(
        at indices: [Int],
        in taggedCommands: [(ScheduleMarker, Spec.Command)],
        on spec: Spec
    ) -> Bool {
        var commandFailed = false
        let objcSucceeded = runCatchingObjC {
            for index in indices {
                do {
                    try spec.run(taggedCommands[index].1)
                } catch is StateMachineSkip {
                    continue
                } catch {
                    commandFailed = true
                    return
                }
            }
        }
        return objcSucceeded && commandFailed == false
    }

    /// Runs the commands at the partition-supplied positions on the sequential reference, checking invariants after each one.
    ///
    /// This replay has one command running at a time, so the spec is settled after every command and an invariant has a state to judge. An invariant that fails here fails without any interleaving, which makes the sequence a deterministic counterexample: the caller reports it directly, with no equivalence comparison and no interleaving search. That is what makes a thread-based run answerable to the spec's own claims rather than only to a difference between two runs.
    ///
    /// A command that skips runs nothing and leaves the state where the previous check found it, so its check is skipped with it.
    private func runCommandsCheckingInvariants(
        at indices: [Int],
        in taggedCommands: [(ScheduleMarker, Spec.Command)],
        on spec: Spec
    ) -> Bool {
        var commandFailed = false
        let objcSucceeded = runCatchingObjC {
            for index in indices {
                do {
                    try spec.run(taggedCommands[index].1)
                    try spec.checkInvariants()
                } catch is StateMachineSkip {
                    continue
                } catch {
                    commandFailed = true
                    return
                }
            }
        }
        return objcSucceeded && commandFailed == false
    }

    func checkLinearizability(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        setupStep: Spec.SetupStep?,
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        let result = Self.runLinearizabilityCheck(
            taggedCommands: taggedCommands,
            setupStep: setupStep,
            laneResponses: laneResponses,
            concurrentSpec: concurrentSpec
        )
        if result.isAbandoned {
            searchAbandonments.value += 1
        }
        return result
    }

    /// Drives the shared interleaving search for a synchronous spec.
    ///
    /// The search's replay interface is asynchronous only, so the whole check crosses one bridge; the closures inside never suspend. The bridge sits after the concurrent phase, so it adds nothing to the command path the lanes race on — the reason it can be tolerated here and nowhere near the lanes, and the reason ``realizedOrderIsLinearizable(prefix:setupStep:realizedOrder:concurrentSpec:)`` above stays synchronous instead of sharing this path: that check runs on every probe, this one only on the probes it rejected.
    static func runLinearizabilityCheck(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        setupStep: Spec.SetupStep?,
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        // Materialized, not lazy: the prefix replay runs once per sibling retry in the DFS, and a lazy view would re-filter the full tagged array on every call.
        let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
        nonisolated(unsafe) let concurrentSpec = concurrentSpec
        return __ExhaustRuntime.blockingAwait {
            await searchForExplainingOrder(
                concurrentSpec: concurrentSpec,
                setupStep: setupStep,
                prefixCommands: prefixCommands,
                laneResponses: laneResponses,
                replay: .synchronous
            )
        }
    }

    func makeIdentifySkips() -> @Sendable (SpecCandidateValue<Spec>) -> Set<Int> {
        { candidate in
            // Skip identification replays the commands sequentially on a fresh spec, outside the ObjC guard that wraps lane execution. Protect it so a command that throws an NSException degrades to "no skips identified" (pruning is then a no-op and the actual execution catches and reports the exception) rather than aborting the process.
            var skipped: Set<Int> = []
            let completed = runCatchingObjC {
                skipped = Spec.identifySkips(setupStep: candidate.setupStep, commands: candidate.taggedCommands.map(\.1))
            }
            return completed ? skipped : []
        }
    }

    func runSmoke(_ commands: [Spec.Command], setupStep: Spec.SetupStep?) -> (trace: [TraceStep], failed: Bool, timedOut: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
        let (spec, setupTrace, setupFailed) = __ExhaustRuntime.makeSpecRecordingSetupTrace(Spec.self, setupStep: setupStep)
        if setupFailed {
            return (setupTrace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        let (commandTrace, failed) = __ExhaustRuntime.buildSequentialTrace(
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
                    throw StateMachineCheckFailure(message: "NSException during command execution")
                }
            },
            checkInvariants: { try spec.checkInvariants() }
        )
        let trace = __ExhaustRuntime.joinTrace(setup: setupTrace, commands: commandTrace)
        if failed {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        // The trace above already checked invariants after every command. The oracle is the other half of what a spec can claim, and smoke never runs the concurrent phase, so it is called here: replay the sequence on a fresh reference and compare once at the end, so a spec that is already broken under sequential execution fails before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let (reference, referenceSetupError) = Spec.makeSpec(setupStep: setupStep)
        guard referenceSetupError == nil, runAllCommandsCatchingObjC(commands, on: reference) else {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        if spec.equivalenceCheck(reference.systemUnderTest) == false {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        return (trace, false, false, spec.systemUnderTest, nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec (with setup applied) and returns its failure description, the expected race-free state for the report. Returns nil when the replay itself fails, because the partial state would mislead debugging.
    func sequentialReplayDescription(of reduced: [(ScheduleMarker, Spec.Command)], setupStep: Spec.SetupStep?) -> String? {
        let (oracleSpec, setupError) = Spec.makeSpec(setupStep: setupStep)
        guard setupError == nil, runAllCommandsCatchingObjC(reduced.map(\.1), on: oracleSpec) else {
            return nil
        }
        return oracleSpec.failureDescription()
    }

    func setupTraceSteps(_ setupStep: Spec.SetupStep?) -> [TraceStep] {
        __ExhaustRuntime.makeSpecRecordingSetupTrace(Spec.self, setupStep: setupStep).steps
    }
}
