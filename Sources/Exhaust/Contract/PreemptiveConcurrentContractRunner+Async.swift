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
    /// Dispatches commands across real GCD threads and bridges async command execution via Task+semaphore. This catches races in synchronous primitives (locks, dispatch queues, atomics) hidden behind async facades — the cooperative runner's deterministic interleaving only reaches `await` suspension points.
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
            case let .invalidConcurrencyLevel(level):
                reportIssue(
                    "concurrencyLevel must be between 1 and 8, but was \(level)",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                return nil
        }

        let logConfiguration = ExhaustLog.Configuration(isEnabled: config.suppressLogs == false, minimumLevel: config.logLevel, format: config.logFormat)
        let (result, deferredIssues, report): (ContractResult<Spec>?, [String], ExhaustReport) = await __ExhaustRuntime.dispatchToGCD {
            ExhaustLog.withConfiguration(logConfiguration) {
                runAsyncPreemptivePipeline(
                    Spec.self,
                    config: config
                )
            }
        }
        config.onReportClosure?(report)
        for issue in deferredIssues {
            reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
        }
        return result
    }
}

// MARK: - Async Pipeline

private extension __ExhaustRuntime {
    /// Executes the full async preemptive contract pipeline on a GCD thread: smoke test, SCA coverage, random sampling with three-pass reduction. Returns deferred issues for the caller to report in the async context where Swift Testing task-locals are available.
    static func runAsyncPreemptivePipeline<Spec: AsyncContractSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig
    ) -> (result: ContractResult<Spec>?, deferredIssues: [String], report: ExhaustReport) {
        let runStopwatch = Stopwatch()
        var report = ExhaustReport()
        report.seed = config.seed
        var deferredIssues: [String] = []

        func finalizeReport() {
            report.totalMilliseconds = runStopwatch.elapsedMilliseconds
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
        // A non-positive or sentinel-large idle timeout (e.g. `Int.max` to disable) means "wait unbounded".
        let idleTimeoutMilliseconds: Int? = (config.idleTimeout > 0 && config.idleTimeout < Int.max)
            ? config.idleTimeout
            : nil
        let check = AsyncPreemptiveChecker<Spec>(idleTimeoutMilliseconds: idleTimeoutMilliseconds)
        var coverageInvocations = 0
        let invocationCounter = UnsafeSendableBox(0)
        let lastRunTimedOut = UnsafeSendableBox(false)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
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
                nonisolated(unsafe) let unsafeSpec = spec
                let (trace, failed) = __ExhaustRuntime.blockingAwait {
                    await buildAsyncSequentialTrace(
                        commands,
                        run: { try await unsafeSpec.run($0) },
                        checkInvariants: { try await unsafeSpec.checkInvariants() }
                    )
                }
                if failed {
                    let result = ContractResult<Spec>(
                        commands: commands,
                        trace: trace,
                        systemUnderTest: spec.systemUnderTest,
                        seed: nil,
                        replaySeed: CrockfordBase32.encodeCoverageRow(smokeRow),
                        discoveryMethod: .smokeTest
                    )
                    let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                    let message = renderFailure(
                        result,
                        failureInfo: failureInfo,
                        modelDescription: spec.modelDescription
                    )
                    finalizeReport()
                    deferredIssues.append(message)
                    return (result, deferredIssues, report)
                }
                smokeRow += 1
                if config.coverageReplayRow != nil { break }
            }
            } catch {
                deferredIssues.append("Generator failed during smoke test: \(error)")
            }
        }

        // Phase 1: Coverage
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
                let result = buildAsyncPreemptiveResult(
                    reduced: scaResult.finalInput,
                    checker: check,
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
                    // When set, the renderer emits the timeout diagnostic and ignores the expected-state line below.
                    failureContext.timedOut = scaResult.timedOut
                    failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                    let message = renderFailure(scaResult.finalInput, trace: result.trace, context: failureContext)
                    deferredIssues.append(message)
                }

                finalizeReport()
                return (result, deferredIssues, report)
            }
        }
        coverageInvocations = invocationCounter.value

        // Phase 2: Sampling
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
                    let result = buildAsyncPreemptiveResult(
                        reduced: reduced,
                        checker: check,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )

                    report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: reductionInvocations)

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
                        deferredIssues.append(message)
                    }

                    finalizeReport()
                    return (result, deferredIssues, report)
                }
            } } catch {
                deferredIssues.append("Generator failed during sampling: \(error)")
            }
        }

        report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: 0)
        finalizeReport()
        return (nil, deferredIssues, report)
    }
}

// MARK: - Async Result Assembly

private extension __ExhaustRuntime {
    /// Builds a ``ContractResult`` for an async preemptive failure by running the reduced commands sequentially on a fresh spec via the checker's ``AsyncPreemptiveChecker/runSequentially(_:on:)`` bridge to capture the oracle SUT state.
    static func buildAsyncPreemptiveResult<Spec: AsyncContractSpec>(
        reduced: [(ScheduleMarker, Spec.Command)],
        checker: AsyncPreemptiveChecker<Spec>,
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> ContractResult<Spec> {
        let oracleSpec = Spec()
        checker.runSequentially(reduced.map(\.1), on: oracleSpec)
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

// MARK: - Async Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for an ``AsyncContractSpec``.
///
/// Bridges async command execution to GCD threads via Task+semaphore. Each lane gets a real OS thread, and within that thread async commands are driven synchronously — the cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncContractSpec> {
    /// Idle-timeout bound (milliseconds) for the blocking drain loop, or `nil` to wait unbounded. A command that suspends onto a foreign executor never returns to the drain lane; without this bound the loop spins a CPU core forever.
    let idleTimeoutMilliseconds: Int?

    /// Bridges async work to the calling thread, bailing with `nil` (and a log) if the drain loop idles past ``idleTimeoutMilliseconds``. Returns the work's result, or `nil` only on timeout.
    private func awaitOrTimeout<R>(_ label: String, _ work: @Sendable @escaping () async -> R) -> R? {
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

        for run in [
            runSequentially(prefixCommands.map(\.1), on: concurrentSpec),
            runSequentially(prefixCommands.map(\.1), on: sequentialSpec),
            runSequentially(concurrentCommands.map(\.1), on: sequentialSpec),
        ] where run.succeeded == false {
            return Preemptive.Outcome(passed: false, timedOut: run.timedOut)
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let commandFailed = SendableBox(false)
        let timedOut = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                nonisolated(unsafe) let spec = concurrentSpec
                let succeeded = exhaust_runCatchingObjCException({
                    let completed: Void? = awaitOrTimeout("lane") {
                        for (_, command) in laneCommands {
                            if commandFailed.value { break }
                            do {
                                try await spec.run(command)
                            } catch is ContractSkip {
                                continue
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
        group.wait()

        if caughtException.value != nil || commandFailed.value {
            return Preemptive.Outcome(passed: false, timedOut: timedOut.value)
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
            return Preemptive.Outcome(passed: false, timedOut: true)
        }

        if invariantsPassed == false {
            return Preemptive.Outcome(passed: false, timedOut: false)
        }

        nonisolated(unsafe) let oracleSpec = concurrentSpec
        nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
        // Timeout → treat as failed (cannot confirm the oracle), and flag it so the failure is reported as a hang.
        guard let oraclePassed = awaitOrTimeout("oracle", {
            await oracleSpec.oracleCheck(sequentialResult)
        }) else {
            return Preemptive.Outcome(passed: false, timedOut: true)
        }
        return Preemptive.Outcome(passed: oraclePassed, timedOut: false)
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
