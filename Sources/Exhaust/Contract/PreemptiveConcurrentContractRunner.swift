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

/// Runs a preemptive concurrent contract test for the given synchronous specification type.
///
/// Dispatches commands across real GCD threads and uses the spec's ``ConcurrentContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving — bug detection is probabilistic, relying on repetition across the sampling budget.
@discardableResult
public func __runPreemptiveConcurrentContract<Spec: ConcurrentContractSpec>(
    _: Spec.Type,
    settings: [ConcurrentContractSettings],
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
    }

    let logConfiguration = ExhaustLog.Configuration(isEnabled: config.suppressLogs == false, minimumLevel: config.logLevel, format: config.logFormat)
    return DispatchQueue.global().sync {
        ExhaustLog.withConfiguration(logConfiguration) {
            let runStartNanos = DispatchTime.now().uptimeNanoseconds
            var report = ExhaustReport()
            report.seed = config.seed

            defer {
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds - runStartNanos
                report.totalMilliseconds = Double(elapsedNanos) / 1_000_000
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
            let check = PreemptiveChecker<Spec>()
            var coverageInvocations = 0
            let invocationCounter = UnsafeSendableBox(0)
            let lastRunTimedOut = UnsafeSendableBox(false)

            let rawIdentifySkips = Spec.skipIdentifier
            let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
                rawIdentifySkips(taggedCommands.map(\.1))
            }
            let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
                invocationCounter.value += 1
                return check.execute(taggedCommands)
            }

            func buildPreemptiveResult(
                reduced: [(ScheduleMarker, Spec.Command)],
                seed: UInt64?,
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
                    discoveryMethod: discoveryMethod
                )
            }

            if config.seed == nil {
                let smokeGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .constant)
                var smokeIterator = ValueAndChoiceTreeInterpreter(smokeGen, materializePicks: false, maxRuns: coverageBudget)
                do { while let (commands, _) = try smokeIterator.next() {
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
                            discoveryMethod: .smokeTest
                        )
                        if config.suppressIssueReporting == false {
                            let failureInfo = ContractFailureInfo<Spec.Command>(discoveryMethod: .smokeTest)
                            let message = renderFailure(result, failureInfo: failureInfo, modelDescription: spec.modelDescription)
                            reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                        }
                        return result
                    }
                } } catch {
                    reportIssue(
                        "Generator failed during smoke test: \(error)",
                        fileID: fileID, filePath: filePath, line: line, column: column
                    )
                }
            }

            if config.seed == nil, coverageBudget > 0, config.useRandomOnly == false {
                if let scaResult = runConcurrentSCACoverage(
                    seqGen: sequenceGen,
                    commandGen: commandGen,
                    commandLimit: commandLimit,
                    coverageBudget: coverageBudget,
                    concurrencyLevel: config.concurrencyLevel,
                    idleTimeout: config.idleTimeout,
                    property: property,
                    identifySkips: identifySkips,
                    lastRunTimedOut: lastRunTimedOut
                ) {
                    if let stats = scaResult.reductionStats {
                        report.applyReductionStats(stats)
                    }
                    report.reductionInvocations = scaResult.reductionInvocations

                    let result = buildPreemptiveResult(
                        reduced: scaResult.finalInput,
                        seed: nil,
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
                        failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                        let message = renderFailure(scaResult.finalInput, trace: result.trace, context: failureContext)
                        reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                    }

                    return result
                }
            }
            coverageInvocations = invocationCounter.value

            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: config.seed,
                maxRuns: samplingBudget
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do { while let (taggedCommands, tree) = try interpreter.next() {
                samplingIteration += 1
                if check.execute(taggedCommands) == false {
                    let reductionResult = check.reduce(
                        generator: sequenceGen,
                        tree: tree,
                        output: taggedCommands,
                        repetitions: 10
                    )

                    let result = buildPreemptiveResult(
                        reduced: reductionResult.output,
                        seed: actualSeed,
                        discoveryMethod: .randomSampling
                    )

                    report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: reductionResult.propertyInvocations)
                    report.applyReductionStats(reductionResult.stats)

                    if config.suppressIssueReporting == false {
                        var failureContext = FailureContext()
                        failureContext.isPreemptive = true
                        failureContext.specName = "\(Spec.self)"
                        failureContext.discoveryMethod = .randomSampling
                        failureContext.seed = actualSeed
                        failureContext.iteration = samplingIteration
                        failureContext.budget = samplingBudget
                        failureContext.sequencesTested = samplingIteration
                        failureContext.reductionInvocations = reductionResult.propertyInvocations
                        failureContext.originalCount = taggedCommands.count
                        failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(result.systemUnderTest)"
                        let message = renderFailure(reductionResult.output, trace: result.trace, context: failureContext)
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

            report.setInvocations(coverage: coverageInvocations, randomSampling: samplingIteration, reduction: 0)
            return nil
        } // withConfiguration
    } // dispatchToGCD
}

// MARK: - Trace Building

/// Builds a trace from a preemptive execution's reduced command sequence. No interleaving annotations — preemptive scheduling is non-deterministic, so the trace only records command completion order.
func buildPreemptiveTrace(
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

// MARK: - ObjC Exception Helper

/// Executes a closure inside the ObjC `@try`/`@catch` wrapper. Returns `true` if the closure completed normally, `false` if an `NSException` was caught. Discards the exception — use the lane-level `caughtException` box when the identity matters.
@discardableResult
private func runCatchingObjC(_ body: @convention(block) () -> Void) -> Bool {
    var exception: NSException?
    return exhaust_runCatchingObjCException(body, &exception)
}

// MARK: - Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for a ``ConcurrentContractSpec``.
private struct PreemptiveChecker<Spec: ConcurrentContractSpec> {
    /// Executes a tagged command sequence with real GCD concurrency and checks invariants and oracle.
    ///
    /// Returns `true` if the execution passes. Returns `false` if invariants fail or the oracle detects divergence from sequential behavior.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter(\.0.isPrefix)
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        for (_, command) in prefixCommands {
            runCatchingObjC { try? concurrentSpec.run(command) }
            runCatchingObjC { try? sequentialSpec.run(command) }
        }

        for (_, command) in concurrentCommands {
            runCatchingObjC { try? sequentialSpec.run(command) }
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let caughtException = SendableBox<NSException?>(nil)
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                var exception: NSException?
                let succeeded = exhaust_runCatchingObjCException({
                    for (_, command) in laneCommands {
                        try? concurrentSpec.run(command)
                    }
                }, &exception)
                if succeeded == false {
                    caughtException.value = exception
                }
                group.leave()
            }
        }
        group.wait()

        if caughtException.value != nil {
            return false
        }

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return false
        }

        return concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)
    }

    struct ReductionResult {
        let output: [(ScheduleMarker, Spec.Command)]
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Reduces a counterexample in three passes, each targeting a different encoder set.
    ///
    /// The three-pass structure is deliberate: PCCR evaluation is non-deterministic (GCD thread preemption), so each probe requires multiple repetitions to confirm. Phased reduction ensures the most impactful transformations run first before budget is spent on fine-tuning.
    ///
    /// **Pass 1 — Lane Collapse.** Drives lane markers to zero, moving commands into the sequential prefix. Prefix commands execute deterministically (no scheduling noise), so a longer prefix produces counterexamples that are easier to reproduce and reason about. Running lane collapse first also reduces the repetition cost of later passes — fewer concurrent commands means less non-deterministic scheduling per evaluation. (The cooperative runner skips this pre-pass because its schedule is choice-encoded and fully deterministic — the unified pass finds the minimal counterexample without prefix bias.)
    ///
    /// **Pass 2 — Structural.** Deletion, migration, and substitution. Removes unnecessary commands and simplifies arguments, operating on the already-collapsed trace so deletions target only commands genuinely needed for the failure.
    ///
    /// **Pass 3 — Value Minimization.** All remaining encoders (value minimization, reordering, and so on). Simplifies command arguments and values toward their semantic simplest form, improving counterexample readability. Runs with a tighter budget (1 stall, 5s) since the structural shape is already minimal.
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
            if let (sequence, reduced) = result.reduced {
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
            if let (sequence, reduced) = result.reduced {
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
            if let (_, reduced) = result.reduced {
                currentOutput = reduced
            }
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations, stats: aggregateStats)
    }
}
