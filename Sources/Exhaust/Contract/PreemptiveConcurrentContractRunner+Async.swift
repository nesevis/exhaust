// Async preemptive concurrent contract runner.
//
// Async variant of the preemptive runner for AsyncConcurrentContractSpec conformances.
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
    static func __runPreemptiveConcurrentContractAsync<Spec: AsyncConcurrentContractSpec>(
        _: Spec.Type,
        settings: [ConcurrentContractSettings],
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
    static func runAsyncPreemptivePipeline<Spec: AsyncConcurrentContractSpec>(
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
        let check = AsyncPreemptiveChecker<Spec>()
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
            return check.execute(taggedCommands)
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
                coverageInvocations = invocationCounter.value
                report.setInvocations(coverage: coverageInvocations, randomSampling: 0, reduction: scaResult.reductionInvocations)

                if config.suppressIssueReporting == false {
                    var failureContext = FailureContext()
                    failureContext.isPreemptive = true
                    failureContext.specName = "\(Spec.self)"
                    failureContext.discoveryMethod = .coverage
                    failureContext.iteration = Int(scaResult.iteration)
                    failureContext.budget = coverageBudget
                    failureContext.sequencesTested = invocationCounter.value + scaResult.reductionInvocations
                    failureContext.reductionInvocations = scaResult.reductionInvocations
                    failureContext.originalCount = scaResult.originalCount
                    failureContext.replaySeed = CrockfordBase32.encodeCoverageRow(Int(scaResult.iteration) - 1)
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
                if check.execute(taggedCommands) == false {
                    let reductionResult = check.reduce(
                        generator: sequenceGen,
                        tree: tree,
                        output: taggedCommands,
                        repetitions: 10
                    )

                    let discoveryMethod: ContractDiscoveryMethod = config.replayIteration != nil ? .replay : .randomSampling
                    let samplingReplaySeed = CrockfordBase32.encode(seed: actualSeed, iteration: absoluteIteration)
                    let result = buildAsyncPreemptiveResult(
                        reduced: reductionResult.output,
                        checker: check,
                        seed: actualSeed,
                        replaySeed: samplingReplaySeed,
                        discoveryMethod: discoveryMethod
                    )

                    report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: reductionResult.propertyInvocations)
                    report.applyReductionStats(reductionResult.stats)

                    if config.suppressIssueReporting == false {
                        var failureContext = FailureContext()
                        failureContext.isPreemptive = true
                        failureContext.specName = "\(Spec.self)"
                        failureContext.discoveryMethod = discoveryMethod
                        failureContext.seed = actualSeed
                        failureContext.iteration = absoluteIteration
                        failureContext.budget = samplingBudget
                        failureContext.sequencesTested = samplingIteration
                        failureContext.reductionInvocations = reductionResult.propertyInvocations
                        failureContext.originalCount = taggedCommands.count
                        failureContext.replaySeed = CrockfordBase32.encode(seed: actualSeed, iteration: absoluteIteration)
                        failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                        let message = renderFailure(reductionResult.output, trace: result.trace, context: failureContext)
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
    static func buildAsyncPreemptiveResult<Spec: AsyncConcurrentContractSpec>(
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

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for an ``AsyncConcurrentContractSpec``.
///
/// Bridges async command execution to GCD threads via Task+semaphore. Each lane gets a real OS thread, and within that thread async commands are driven synchronously — the cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncConcurrentContractSpec> {
    /// Executes a tagged command sequence with real GCD concurrency and checks invariants and oracle.
    ///
    /// Prefix and sequential commands are bridged through a single Task+semaphore. Concurrent commands are dispatched to real GCD threads (one per lane), each bridging async execution independently.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter(\.0.isPrefix)
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        guard runSequentially(prefixCommands.map(\.1), on: concurrentSpec) else {
            return false
        }
        guard runSequentially(prefixCommands.map(\.1), on: sequentialSpec) else {
            return false
        }
        guard runSequentially(concurrentCommands.map(\.1), on: sequentialSpec) else {
            return false
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let commandFailed = SendableBox(false)
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                nonisolated(unsafe) let spec = concurrentSpec
                let succeeded = exhaust_runCatchingObjCException({
                    __ExhaustRuntime.blockingAwait {
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
                }, &exception)
                if succeeded == false {
                    caughtException.value = exception
                }
                group.leave()
            }
        }
        group.wait()

        if caughtException.value != nil || commandFailed.value {
            return false
        }

        nonisolated(unsafe) let invariantSpec = concurrentSpec
        let invariantsPassed = __ExhaustRuntime.blockingAwait {
            do {
                try await invariantSpec.checkInvariants()
                return true
            } catch {
                return false
            }
        }

        if invariantsPassed == false {
            return false
        }

        nonisolated(unsafe) let oracleSpec = concurrentSpec
        nonisolated(unsafe) let sequentialResult = sequentialSpec.systemUnderTest
        return __ExhaustRuntime.blockingAwait {
            await oracleSpec.oracleCheck(sequentialResult)
        }
    }

    /// Runs commands sequentially on a spec, bridging async execution via ``__ExhaustRuntime/blockingAwait(_:)``. Wraps in ObjC exception handling so NSExceptions from underlying C/ObjC code are caught rather than crashing the process.
    ///
    /// Returns `true` if all commands succeeded or were skipped, `false` if any command threw a non-skip error or an NSException was caught.
    @discardableResult
    func runSequentially(_ commands: [Spec.Command], on spec: Spec) -> Bool {
        var exception: NSException?
        let failed = SendableBox(false)
        nonisolated(unsafe) let spec = spec
        exhaust_runCatchingObjCException({
            __ExhaustRuntime.blockingAwait {
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
        }, &exception)
        return exception == nil && failed.value == false
    }

    struct ReductionResult {
        let output: [(ScheduleMarker, Spec.Command)]
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Three-pass reduction (lane collapse, structural, value minimization). See ``PreemptiveChecker/reduce(generator:tree:output:repetitions:)`` for rationale.
    func reduce(
        generator: Generator<[(ScheduleMarker, Spec.Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Spec.Command)],
        repetitions: Int
    ) -> ReductionResult {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if execute(taggedCommands) == false {
                    return false
                }
            }
            return true
        }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let valueMinimization = Set(EncoderName.allCases).subtracting(structural).subtracting([.laneCollapse])

        var currentOutput = output
        var currentTree = tree
        var aggregateStats = ReductionStats()

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10_000_000_000, enabledEncoders: [.laneCollapse]),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(sequence, reduced) = result.outcome {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 30_000_000_000, enabledEncoders: structural),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(sequence, reduced) = result.outcome {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 5_000_000_000, enabledEncoders: valueMinimization),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if case let .reduced(_, reduced) = result.outcome {
                currentOutput = reduced
            }
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations, stats: aggregateStats)
    }
}
