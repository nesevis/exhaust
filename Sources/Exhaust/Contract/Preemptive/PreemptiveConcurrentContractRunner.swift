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

        let innerBackend = PreemptiveChecker<Spec>(idleTimeoutMilliseconds: config.resolvedIdleTimeoutMilliseconds)
        let commandLimit = config.commandLimit ?? PreemptiveReduction.defaultCommandLimit
        warnIfInterleavingSpaceIsLarge(commandLimit: commandLimit, laneCount: config.concurrencyLevel, fileID: fileID, filePath: filePath, line: line, column: column)

        let timedOutProbeCount = UnsafeSendableBox(0)
        // Gate + offload: acquire a lane reservation, then run the (synchronous) machine on a GCD worker. The gate bounds how many preemptive runs execute at once so their lanes are not starved of threads under `--parallel`; the GCD hop frees the cooperative thread. Reporting is deferred to the async return context where Swift Testing's task-locals are available.
        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = await dispatchToGCD(reserving: LaneReservation.threads(config.concurrencyLevel)) {
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

// MARK: - Machine Pipeline

extension __ExhaustRuntime {
    static func runPreemptiveMachine<Inner: PreemptiveBackend>(
        innerBackend: Inner,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        timedOutProbeCount: UnsafeSendableBox<Int>,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: ContractResult<Inner.Spec>?, deferredIssues: [String]) {
        typealias Spec = Inner.Spec
        var deferredIssues: [String] = []

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? PreemptiveReduction.defaultCommandLimit

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

        let backend = PreemptiveContractBackend(
            inner: innerBackend,
            concurrencyLevel: config.concurrencyLevel
        )

        let invocationCounter = UnsafeSendableBox(0)
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let partition = LanePartition(markers: taggedCommands.map(\.0))
            let outcome = innerBackend.execute(taggedCommands, partition: partition)
            if case .timedOut = outcome {
                // A timed-out probe is inconclusive, not a counterexample: under host contention the lanes simply did not finish in time. Count it as a pass so discovery keeps sampling, and tally it so the runner can warn when timeouts dominate the budget.
                timedOutProbeCount.value += 1
                return true
            }
            return classifyFailure(
                taggedCommands: taggedCommands,
                outcome: outcome,
                backend: innerBackend
            ) == nil
        }

        let smokeProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { tagged in
            invocationCounter.value += 1
            let smoke = innerBackend.runSmoke(tagged.map(\.1))
            if smoke.timedOut {
                timedOutProbeCount.value += 1
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
        let smokeSource: AnyContractCandidateSource<Spec.Command>? = .smoke(
            sequenceGen: smokeSequenceGen,
            property: smokeProperty
        )

        let pipeline = ContractPipeline(
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
        laneResponseValues: [UInt8: [String?]]? = nil,
        linearizabilityWitness: ResponseWitness? = nil
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
private struct PreemptiveChecker<Spec: ContractSpec>: PreemptiveBackend {
    /// Idle bound for the concurrent lanes, or `nil` to wait indefinitely. Without a bound, a synchronous SUT deadlock (the exact bug class preemptive testing targets) would wedge a lane forever and hang the test process with no diagnostic.
    let idleTimeoutMilliseconds: Int?

    /// Executes a tagged command sequence with real GCD concurrency using a pre-computed lane partition.
    ///
    /// Returns ``Preemptive/Outcome/failed(concurrentSpec:)`` when a command throws, an invariant fails, or an ObjC exception is caught. Returns ``Preemptive/Outcome/timedOut(concurrentSpec:)`` when the concurrent lanes do not finish within ``idleTimeoutMilliseconds``, so the ``ContractMachine`` can skip reduction and report a hang rather than a deterministic failure.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], partition: LanePartition) -> Preemptive.Outcome<Spec> {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        if runCommandsCatchingObjC(at: partition.prefixIndices, in: taggedCommands, on: concurrentSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }
        if runCommandsCatchingObjC(at: partition.prefixIndices, in: taggedCommands, on: sequentialSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        if runCommandsCatchingObjC(at: partition.concurrentIndices, in: taggedCommands, on: sequentialSpec) == false {
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
                        } catch is ContractSkip {
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

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return .failed(concurrentSpec: concurrentSpec)
        }

        let collectedResponses: [[ObservedResponse<Spec.Command>]] = perLaneResponses.map(\.value)
        // Void-only, no-skip commands carry no response data, so linearizability reduces to final-state equivalence.
        let hasResponseInfo = collectedResponses.contains { lane in lane.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped } }
        if hasResponseInfo == false {
            if concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest) {
                return .passed
            }
            return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
        }
        // Try the realized completion order as a single linearization witness before the full interleaving search. The prefix array is materialized only here — the passed and no-response-info paths never need it.
        let prefixCommands = partition.prefixIndices.map { taggedCommands[$0].1 }
        if realizedOrderIsLinearizable(prefix: prefixCommands, realizedOrder: realizedCompletionOrder(of: collectedResponses), concurrentSpec: concurrentSpec) {
            return .passed
        }
        return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Whether the realized completion order is a valid linearization: a sequential replay of the concurrent commands in the order the lanes finished, on a fresh spec, that reproduces every observed response and the oracle's final state.
    ///
    /// A match means the execution is linearizable (this order is a concrete witness), so the ``ContractMachine`` can pass without the full interleaving search.
    /// Any divergence (a differing response, an oracle mismatch, a replay throw, or an ObjC exception) returns `false`, and the ``ContractMachine`` hands the per-lane responses to ``checkLinearizability(taggedCommands:laneResponses:concurrentSpec:)``.
    /// The check is sound: it only reports a pass when an actual sequential order reproduces the observation.
    private func realizedOrderIsLinearizable(
        prefix: [Spec.Command],
        realizedOrder: [ObservedResponse<Spec.Command>],
        concurrentSpec: Spec
    ) -> Bool {
        let witnessSpec = Spec()
        var matched = false
        var exception: NSException?
        let completed = exhaust_runCatchingObjCException({
            for command in prefix {
                do {
                    try witnessSpec.run(command)
                } catch is ContractSkip {
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
                } catch is ContractSkip {
                    if observed.outcome.isSkipped == false {
                        return
                    }
                } catch {
                    return
                }
            }
            matched = concurrentSpec.oracleCheck(witnessSpec.systemUnderTest)
        }, &exception)
        return completed && exception == nil && matched
    }

    /// Runs all commands on a spec under a single ObjC exception guard, treating ``ContractSkip`` as a pass.
    private func runAllCommandsCatchingObjC(_ commands: [Spec.Command], on spec: Spec) -> Bool {
        var commandFailed = false
        let objcSucceeded = runCatchingObjC {
            for command in commands {
                do {
                    try spec.run(command)
                } catch is ContractSkip {
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
                } catch is ContractSkip {
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
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        Self.runLinearizabilityCheck(
            taggedCommands: taggedCommands,
            laneResponses: laneResponses,
            concurrentSpec: concurrentSpec
        )
    }

    /// Constructs the replay closures and drives the linearizability checker for a synchronous spec.
    static func runLinearizabilityCheck(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult {
        // Materialized, not lazy: `replayPrefix` runs once per sibling retry in the DFS, and a lazy view would re-filter the full tagged array on every call.
        let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
        var replaySpec: Spec?
        let checker = LinearizabilityChecker(laneResponses: laneResponses)
        let result = checker.check(
            replayPrefix: {
                let fresh = Spec()
                for command in prefixCommands {
                    do {
                        try fresh.run(command)
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
                return Self.replaySync(laneResponses[laneIndex][commandIndex].command, on: spec)
            },
            checkOracle: {
                guard let spec = replaySpec else {
                    return false
                }
                return concurrentSpec.oracleCheck(spec.systemUnderTest)
            },
            failureDescription: {
                concurrentSpec.failureDescription()
            }
        )
        return makeLinearizabilityResult(result, laneObservations: laneResponses)
    }

    private static func replaySync(
        _ command: Spec.Command,
        on spec: Spec
    ) -> LinearizabilityChecker.ReplayResponse? {
        do {
            let response = try spec.run(command)
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
    }

    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> {
        let rawIdentifySkips = Spec.skipIdentifier
        return { taggedCommands in
            // Skip identification replays the commands sequentially on a fresh spec, outside the ObjC guard that wraps lane execution. Protect it so a command that throws an NSException degrades to "no skips identified" (pruning is then a no-op and the actual execution catches and reports the exception) rather than aborting the process.
            var skipped: Set<Int> = []
            let completed = runCatchingObjC {
                skipped = rawIdentifySkips(taggedCommands.map(\.1))
            }
            return completed ? skipped : []
        }
    }

    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, timedOut: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?) {
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
        if failed {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        // A .threads spec expresses its self-consistency check through the @Oracle, because the macro rejects @Invariant under .threads, and smoke never runs the concurrent phase.
        // Replay the sequence on a fresh reference and call the oracle once at the end, so a spec that is already broken under sequential execution fails here before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let reference = Spec()
        guard runAllCommandsCatchingObjC(commands, on: reference) else {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        if spec.oracleCheck(reference.systemUnderTest) == false {
            return (trace, true, false, spec.systemUnderTest, spec.failureDescription())
        }
        return (trace, false, false, spec.systemUnderTest, nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec and returns its failure description, the expected race-free state for the report. Returns nil when the replay itself fails, because the partial state would mislead debugging.
    func sequentialReplayDescription(of reduced: [(ScheduleMarker, Spec.Command)]) -> String? {
        let oracleSpec = Spec()
        guard runAllCommandsCatchingObjC(reduced.map(\.1), on: oracleSpec) else {
            return nil
        }
        return oracleSpec.failureDescription()
    }
}
