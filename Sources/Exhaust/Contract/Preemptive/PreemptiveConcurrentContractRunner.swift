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

        let (result, deferredIssues): (ContractResult<Spec>?, [String]) = DispatchQueue.global().sync {
            ExhaustLog.withConfiguration(config.logConfiguration) {
                runPreemptiveMachine(
                    innerBackend: innerBackend,
                    config: config,
                    regressionSeeds: regressionSeeds,
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
        return result
    }
}

// MARK: - Machine Pipeline

extension __ExhaustRuntime {
    static func runPreemptiveMachine<Inner: PreemptiveBackend>(
        innerBackend: Inner,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
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
        let lastRunTimedOut = UnsafeSendableBox(false)
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let partition = LanePartition(taggedCommands)
            let outcome = innerBackend.execute(taggedCommands, partition: partition)
            if case .timedOut = outcome {
                lastRunTimedOut.value = true
            }
            return classifyFailure(
                taggedCommands: taggedCommands,
                outcome: outcome,
                backend: innerBackend
            ) == nil
        }

        func runMachine(
            config machineConfig: ResolvedConcurrentConfig
        ) -> (result: ContractResult<Spec>?, issues: [String]) {
            let runContext = ContractRunContext<Spec>(
                config: machineConfig,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                identifySkips: identifySkips,
                invocationCounter: invocationCounter,
                lastRunTimedOut: lastRunTimedOut,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )

            let sources = buildPreemptiveSources(
                config: machineConfig,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                concurrencyLevel: config.concurrencyLevel,
                taggedCommandGen: taggedCommandGen,
                innerBackend: innerBackend,
                property: property
            )

            var machine = ContractMachine(backend: backend, context: runContext, sources: sources)
            let result = machine.run()
            return (result, runContext.deferredIssues)
        }

        // Regression seeds
        if config.coverageReplayRow == nil, config.seed == nil {
            for encodedSeed in regressionSeeds {
                guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                    deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                    continue
                }

                var replayConfig = config
                switch decoded {
                    case let .coverage(row):
                        replayConfig.coverageReplayRow = row
                        let needed = UInt64(row) + 1
                        if replayConfig.budget.coverageBudget < needed {
                            replayConfig.budget = .custom(
                                coverage: needed,
                                sampling: replayConfig.budget.samplingBudget
                            )
                        }
                    case let .sampling(seed, iteration):
                        replayConfig.seed = seed
                        replayConfig.replayIteration = iteration
                }

                let (result, issues) = runMachine(config: replayConfig)
                deferredIssues.append(contentsOf: issues)
                if let result {
                    return (result, deferredIssues)
                } else if config.suppressIssueReporting == false {
                    deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes. Consider removing it.")
                }
            }
        }

        let (result, issues) = runMachine(config: config)
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }

    static func buildPreemptiveSources<Inner: PreemptiveBackend>(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Inner.Spec.Command)]>,
        commandGen: Generator<Inner.Spec.Command>,
        commandLimit: Int,
        concurrencyLevel: Int,
        taggedCommandGen: Generator<(ScheduleMarker, Inner.Spec.Command)>,
        innerBackend: Inner,
        property: @escaping @Sendable ([(ScheduleMarker, Inner.Spec.Command)]) -> Bool
    ) -> [AnyContractCandidateSource<Inner.Spec.Command>] {
        var sources: [AnyContractCandidateSource<Inner.Spec.Command>] = []

        if let row = config.coverageReplayRow {
            sources.append(.coverageReplay(
                row: row,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: max(config.budget.coverageBudget, UInt64(row) + 1),
                concurrencyLevel: concurrencyLevel,
                property: property
            ))
        }

        if let replayIteration = config.replayIteration, let seed = config.seed {
            sources.append(.samplingReplay(
                replaySeed: seed,
                replayIteration: replayIteration,
                sequenceGen: sequenceGen,
                property: property
            ))
        }

        if let smokeTaggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: 1) {
            let smokeGen = Gen.arrayOf(smokeTaggedCommandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
            let smokeProperty: @Sendable ([(ScheduleMarker, Inner.Spec.Command)]) -> Bool = { tagged in
                innerBackend.runSmoke(tagged.map(\.1)).failed == false
            }
            sources.append(.smoke(sequenceGen: smokeGen, property: smokeProperty))
        }

        if config.shouldRunCoverage {
            sources.append(.coverage(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: config.budget.coverageBudget,
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: { range in
                    Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant)
                },
                property: property
            ))
        }

        if config.replayIteration == nil, config.coverageReplayRow == nil {
            let seed = config.seed ?? Xoshiro256().seed
            sources.append(.sampling(
                sequenceGen: sequenceGen,
                seed: seed,
                samplingBudget: config.budget.samplingBudget,
                property: property
            ))
        }

        return sources
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
    /// Returns ``Preemptive/Outcome/failed(concurrentSpec:)`` when a command throws, an invariant fails, or an ObjC exception is caught. Returns ``Preemptive/Outcome/timedOut(concurrentSpec:)`` when the concurrent lanes do not finish within ``idleTimeoutMilliseconds``, so the caller can skip reduction and report a hang rather than a deterministic failure.
    func execute(_: [(ScheduleMarker, Spec.Command)], partition: LanePartition<Spec.Command>) -> Preemptive.Outcome<Spec> {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        if runAllCommandsCatchingObjC(partition.prefixCommands, on: concurrentSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }
        if runAllCommandsCatchingObjC(partition.prefixCommands, on: sequentialSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        if runAllCommandsCatchingObjC(partition.concurrentCommands, on: sequentialSpec) == false {
            return .failed(concurrentSpec: concurrentSpec)
        }

        let perLaneResponses = partition.laneIDs.map { _ in UnsafeSendableBox<[ObservedResponse<Spec.Command>]>([]) }
        let commandFailed = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        // `withValue`'s lock serializes appends into realized completion order.
        let completionOrdered = SendableBox<[ObservedResponse<Spec.Command>]>([])
        let group = DispatchGroup()

        nonisolated(unsafe) let unsafeConcurrentSpec = concurrentSpec
        for (offset, laneID) in partition.laneIDs.enumerated() {
            let laneCommands = partition.laneBuckets[laneID] ?? []
            let responseBox = perLaneResponses[offset]
            group.enter()
            DispatchQueue.global().async {
                var localResponses: [ObservedResponse<Spec.Command>] = []
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    for command in laneCommands {
                        if commandFailed.value {
                            break
                        }
                        do {
                            let response = try unsafeConcurrentSpec.run(command)
                            let outcome = response.returnValue.map(ObservedResponse<Spec.Command>.Outcome.returned) ?? .returnedVoid
                            let observed = ObservedResponse<Spec.Command>(lane: laneID, command: command, outcome: outcome)
                            localResponses.append(observed)
                            completionOrdered.withValue { $0.append(observed) }
                        } catch is ContractSkip {
                            let observed = ObservedResponse<Spec.Command>(lane: laneID, command: command, outcome: .skipped)
                            localResponses.append(observed)
                            completionOrdered.withValue { $0.append(observed) }
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
        let hasResponseInfo = completionOrdered.value.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped }
        if hasResponseInfo == false {
            if concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest) {
                return .passed
            }
            return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
        }
        // Try the realized completion order as a single linearization witness before the full interleaving search.
        if realizedOrderIsLinearizable(prefix: partition.prefixCommands, realizedOrder: completionOrdered.value, concurrentSpec: concurrentSpec) {
            return .passed
        }
        return .oracleMismatch(laneResponses: collectedResponses, concurrentSpec: concurrentSpec)
    }

    /// Whether the realized completion order is a valid linearization: a sequential replay of the concurrent commands in the order the lanes finished, on a fresh spec, that reproduces every observed response and the oracle's final state.
    ///
    /// A match means the execution is linearizable (this order is a concrete witness), so the caller can pass without the full interleaving search.
    /// Any divergence (a differing response, an oracle mismatch, a replay throw, or an ObjC exception) returns `false`, and the caller hands the per-lane responses to ``checkLinearizability(taggedCommands:laneResponses:concurrentSpec:)``.
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
        let prefixCommands = taggedCommands.lazy.filter(\.0.isPrefix).map(\.1)
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
            replayCommand: { command in
                guard let spec = replaySpec else {
                    return nil
                }
                return Self.replaySync(command, on: spec)
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
    ) -> LinearizabilityChecker<Spec.Command>.ReplayResponse? {
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
        if failed {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        // A .threads spec expresses its self-consistency check through the @Oracle, because the macro rejects @Invariant under .threads, and smoke never runs the concurrent phase.
        // Replay the sequence on a fresh reference and call the oracle once at the end, so a spec that is already broken under sequential execution fails here before any concurrent probing.
        // The reference is a distinct spec so the oracle's relational comparison is between two independent runs rather than the SUT against itself.
        let reference = Spec()
        guard runAllCommandsCatchingObjC(commands, on: reference) else {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        if spec.oracleCheck(reference.systemUnderTest) == false {
            return (trace, true, spec.systemUnderTest, spec.failureDescription())
        }
        return (trace, false, spec.systemUnderTest, nil)
    }

    /// Replays the reduced commands sequentially on a fresh spec to capture the oracle SUT state. Returns nil ``ContractResult/systemUnderTest`` when the sequential replay itself fails, because the partial state would mislead debugging.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod,
        timedOut: Bool
    ) -> (result: ContractResult<Spec>, failureDescription: String?) {
        let oracleSpec = Spec()
        let commands = reduced.map(\.1)
        let replaySucceeded = runAllCommandsCatchingObjC(commands, on: oracleSpec)
        let result = ContractResult<Spec>(
            status: timedOut ? .timeout : .fail,
            commands: commands,
            originalCommands: originalCommands,
            trace: __ExhaustRuntime.buildPreemptiveTrace(reduced),
            systemUnderTest: replaySucceeded ? oracleSpec.systemUnderTest : nil,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
        return (result, replaySucceeded ? oracleSpec.failureDescription() : nil)
    }
}
