// Preemptive concurrent contract runner.
//
// Based on eqc_par_statem from Claessen et al., "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work generates a sequential prefix followed by concurrent command groups, then compares the concurrent outcome against a sequential oracle. PULSE adds deterministic replay via a user-level scheduler; this runner omits replay and relies on OS thread scheduling for non-deterministic interleaving, compensating with repetition across the sampling budget.
//
// The cooperative runner (CooperativeConcurrentContractRunner) implements the PULSE half — a TaskExecutor-based drain loop that makes interleavings deterministic and reducible. This runner targets bugs that require real thread-level preemption: races in locks, dispatch queues, and atomics that are invisible at `await` suspension points.
import ExhaustCore
import ExhaustObjCSupport
import Foundation
import IssueReporting

// MARK: - Runner Entry Point

public extension __ExhaustRuntime {
    /// Runs a preemptive concurrent contract test for the given synchronous specification type.
    ///
    /// Dispatches commands across real GCD threads and uses the spec's ``ContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving — bug detection is probabilistic, relying on repetition across the sampling budget.
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
            case let .invalidConcurrencyLevel(level):
                reportIssue(
                    "concurrencyLevel must be between 1 and 8, but was \(level)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return nil
        }

        let logConfiguration = ExhaustLog.Configuration(isEnabled: config.suppressLogs == false, minimumLevel: config.logLevel, format: config.logFormat)
        return DispatchQueue.global().sync {
            ExhaustLog.withConfiguration(logConfiguration) {
                runPreemptivePipeline(
                    Spec.self,
                    config: config,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        }
    }
}

// MARK: - Pipeline

private extension __ExhaustRuntime {
    /// Executes the full preemptive contract pipeline on a GCD thread: smoke test, SCA coverage, random sampling with three-pass reduction. Reports issues inline via `reportIssue` since Swift Testing task-locals are available on the calling thread.
    static func runPreemptivePipeline<Spec: ContractSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ContractResult<Spec>? {
        let runStopwatch = Stopwatch()
        var report = ExhaustReport()
        report.seed = config.seed

        defer {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
            config.onReportClosure?(report)
        }

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? 8
        let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let samplingBudget = config.budget.samplingBudget
        let coverageBudget = config.budget.coverageBudget
        let idleTimeoutMilliseconds: Int? = (config.idleTimeout > 0 && config.idleTimeout < Int.max)
            ? config.idleTimeout
            : nil
        let check = PreemptiveChecker<Spec>(idleTimeoutMilliseconds: idleTimeoutMilliseconds)
        var coverageInvocations = 0
        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)

        let rawIdentifySkips = Spec.skipIdentifier
        let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
            rawIdentifySkips(taggedCommands.map(\.1))
        }
        let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            invocationCounter.value += 1
            let outcome = check.execute(taggedCommands)
            lastRunTimedOut.value = outcome.timedOut
            return outcome.passed
        }

        // Phase 0: Smoke test
        if config.seed == nil, config.replayIteration == nil {
            let smokeGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
            var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, maxRuns: coverageBudget)
            var smokeRow = 0
            do { while let (commands, _) = try smokeIterator.next() {
                if let coverageReplayRow = config.coverageReplayRow, smokeRow < coverageReplayRow {
                    smokeRow += 1
                    continue
                }
                let spec = Spec()
                let (trace, failed) = buildSequentialTrace(
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
                    let result = ContractResult<Spec>(
                        commands: commands,
                        trace: trace,
                        systemUnderTest: spec.systemUnderTest,
                        seed: nil,
                        replaySeed: CrockfordBase32.encodeCoverageRow(smokeRow),
                        discoveryMethod: .smokeTest
                    )
                    if config.suppressIssueReporting == false {
                        let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                        let message = renderFailure(result, failureInfo: failureInfo, modelDescription: spec.modelDescription)
                        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                    }
                    return result
                }
                smokeRow += 1
                if config.coverageReplayRow != nil { break }
            } } catch {
                reportIssue(
                    "Generator failed during smoke test: \(error)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            }
        }

        // Ordered coverage
        if config.shouldRunCoverage {
            if let scaResult = runConcurrentSCACoverage(
                seqGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                concurrencyLevel: config.concurrencyLevel,
                idleTimeout: config.idleTimeout,
                skipToRow: config.coverageReplayRow,
                property: property,
                identifySkips: identifySkips,
                lastRunTimedOut: lastRunTimedOut,
                invocationCounter: invocationCounter
            ) {
                if let stats = scaResult.reductionStats {
                    report.applyReductionStats(stats)
                }
                report.reductionInvocations = scaResult.reductionInvocations

                let scaReplaySeed = CrockfordBase32.encodeCoverageRow(Int(scaResult.iteration) - 1)
                let result = buildPreemptiveResult(
                    Spec.self,
                    reduced: scaResult.finalInput,
                    seed: nil,
                    replaySeed: scaReplaySeed,
                    discoveryMethod: .coverage
                )
                report.setConcurrentInvocations(
                    totalInvocations: invocationCounter.value,
                    coverageThroughReduction: invocationCounter.value,
                    reduction: scaResult.reductionInvocations,
                    discoveredDuringCoverage: true
                )

                if config.suppressIssueReporting == false {
                    var failureContext = FailureContext()
                    failureContext.isPreemptive = true
                    failureContext.specName = "\(Spec.self)"
                    failureContext.discoveryMethod = .coverage
                    failureContext.iteration = Int(scaResult.iteration)
                    failureContext.budget = coverageBudget
                    failureContext.sequencesTested = invocationCounter.value
                    failureContext.reductionInvocations = scaResult.reductionInvocations
                    failureContext.originalCount = scaResult.originalCount
                    failureContext.replaySeed = CrockfordBase32.encodeCoverageRow(Int(scaResult.iteration) - 1)
                    failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                    let message = renderFailure(scaResult.finalInput, trace: result.trace, context: failureContext)
                    reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                }

                return result
            }
        }
        coverageInvocations = invocationCounter.value

        // Random sampling
        if config.coverageReplayRow == nil {
            let startIndex = config.replayIteration.map { UInt64($0 - 1) } ?? 0
            let maxRuns = config.replayIteration.map { UInt64($0) } ?? samplingBudget
            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: config.seed,
                maxRuns: maxRuns,
                initialRunIndex: startIndex
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do { while let (taggedCommands, tree) = try interpreter.next() {
                samplingIteration += 1
                let absoluteIteration = Int(startIndex) + samplingIteration
                let outcome = check.execute(taggedCommands)
                if outcome.passed == false {
                    // Reduction stays correct on a timeout — the reducer only ever returns a failing schedule — but on a hang every probe waits out the idle bound (idleTimeout × repetitions) and a timing-dependent timeout often will not reproduce, so it is slow and usually fruitless. Skip it and report the original schedule.
                    let reduced: [(ScheduleMarker, Spec.Command)]
                    let reductionInvocations: Int
                    if outcome.timedOut {
                        reduced = taggedCommands
                        reductionInvocations = 0
                    } else {
                        let reductionResult = check.reduce(
                            generator: sequenceGen,
                            tree: tree,
                            output: taggedCommands,
                            repetitions: 10
                        )
                        reduced = reductionResult.output
                        reductionInvocations = reductionResult.propertyInvocations
                        report.applyReductionStats(reductionResult.stats)
                    }

                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    let samplingReplaySeed = CrockfordBase32.encode(seed: actualSeed, iteration: absoluteIteration)
                    let result = buildPreemptiveResult(
                        Spec.self,
                        reduced: reduced,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )

                    report.setInvocations(
                        coverage: coverageInvocations,
                        randomSampling: samplingIteration,
                        reduction: reductionInvocations
                    )

                    if config.suppressIssueReporting == false {
                        var failureContext = FailureContext()
                        failureContext.isPreemptive = true
                        failureContext.specName = "\(Spec.self)"
                        failureContext.discoveryMethod = discoveryMethod
                        failureContext.seed = actualSeed
                        failureContext.iteration = absoluteIteration
                        failureContext.budget = samplingBudget
                        failureContext.sequencesTested = samplingIteration
                        failureContext.reductionInvocations = reductionInvocations
                        failureContext.originalCount = taggedCommands.count
                        failureContext.replaySeed = CrockfordBase32.encode(seed: actualSeed, iteration: absoluteIteration)
                        // When set, the renderer emits the timeout diagnostic and ignores the expected-state line below.
                        failureContext.timedOut = outcome.timedOut
                        failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                        let message = renderFailure(reduced, trace: result.trace, context: failureContext)
                        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                    }

                    return result
                }
            } } catch {
                reportIssue(
                    "Generator failed during sampling: \(error)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            }
        }

        report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: 0)
        return nil
    }
}

// MARK: - Result Assembly

private extension __ExhaustRuntime {
    /// Builds a ``ContractResult`` for a preemptive failure by running the reduced commands sequentially on a fresh spec to capture the oracle SUT state.
    static func buildPreemptiveResult<Spec: ContractSpec>(
        _: Spec.Type,
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> ContractResult<Spec> {
        let oracleSpec = Spec()
        for (_, command) in reduced {
            runCatchingObjC { try? oracleSpec.run(command) }
        }
        return ContractResult<Spec>(
            commands: reduced.map(\.1),
            trace: buildPreemptiveTrace(reduced),
            systemUnderTest: oracleSpec.systemUnderTest,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )
    }
}

// MARK: - Trace Building

extension __ExhaustRuntime {
    /// Builds a trace from a preemptive execution's reduced command sequence in input order. No interleaving annotations — preemptive scheduling is non-deterministic, so actual execution order may differ from the listed order.
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

/// Executes a closure inside the ObjC `@try`/`@catch` wrapper. Returns `true` if the closure completed normally, `false` if an `NSException` was caught. Discards the exception — use the lane-level `caughtException` box when the identity matters.
@discardableResult
private func runCatchingObjC(_ body: @convention(block) () -> Void) -> Bool {
    var exception: NSException?
    return exhaust_runCatchingObjCException(body, &exception)
}

// MARK: - Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for a ``ContractSpec``.
private struct PreemptiveChecker<Spec: ContractSpec> {
    /// Idle bound for the concurrent lanes, or `nil` to wait indefinitely. A synchronous SUT deadlock — the exact bug class preemptive testing targets — would otherwise wedge a lane forever and hang the test process with no diagnostic.
    let idleTimeoutMilliseconds: Int?

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants and oracle.
    ///
    /// `passed` is `false` when a command throws, an invariant fails, or the oracle detects divergence from sequential behavior. `timedOut` is `true` when the concurrent lanes did not finish within ``idleTimeoutMilliseconds`` — surfaced separately so the caller can skip reduction (every probe would wait out the bound) and report a hang rather than a deterministic failure.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter(\.0.isPrefix)
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        for (_, command) in prefixCommands {
            guard runCommandCatchingObjC(command, on: concurrentSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false)
            }
            guard runCommandCatchingObjC(command, on: sequentialSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false)
            }
        }

        for (_, command) in concurrentCommands {
            guard runCommandCatchingObjC(command, on: sequentialSpec) else {
                return Preemptive.Outcome(passed: false, timedOut: false)
            }
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let commandFailed = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    for (_, command) in laneCommands {
                        if commandFailed.value { break }
                        do {
                            try concurrentSpec.run(command)
                        } catch is ContractSkip {
                            continue
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
                // A lane is wedged (a synchronous deadlock in the SUT). Stop the lanes we can and report a hang rather than blocking the test process forever. Orphaned lanes blocked on the deadlock cannot be reclaimed.
                commandFailed.value = true
                return Preemptive.Outcome(passed: false, timedOut: true)
            }
        } else {
            group.wait()
        }

        if caughtException.value != nil || commandFailed.value {
            return Preemptive.Outcome(passed: false, timedOut: false)
        }

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return Preemptive.Outcome(passed: false, timedOut: false)
        }

        return Preemptive.Outcome(passed: concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest), timedOut: false)
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

    /// Three-pass reduction. Delegates to the shared ``Preemptive/reduce(generator:tree:output:repetitions:execute:)``.
    func reduce(
        generator: Generator<[(ScheduleMarker, Spec.Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Spec.Command)],
        repetitions: Int
    ) -> Preemptive.ReductionResult<Spec.Command> {
        Preemptive.reduce(
            generator: generator,
            tree: tree,
            output: output,
            repetitions: repetitions,
            execute: execute
        )
    }
}
