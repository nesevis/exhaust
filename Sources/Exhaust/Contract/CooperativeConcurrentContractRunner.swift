// Cooperative concurrent contract runner.
//
// Based on Claessen, Palka, Smallbone, Hughes, Svensson, Arts, and Wiger, "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work combines QuickCheck's eqc_par_statem with a user-level scheduler (PULSE) that records and replays Erlang process schedules for deterministic concurrency testing.
//
// This implementation adapts the approach to Swift Concurrency:
// - Schedule markers encoded as reducible chooseBits replace PULSE's external schedule.
// - A cooperative TaskExecutor-based drain loop replaces the Erlang VM instrumentation.
// - The schedule is part of the generated input (not an external random choice), so reduction operates on schedule and commands jointly — no separate ?ALWAYS(N, Prop) wrapper is needed for shrinking stability.
import ExhaustCore
import IssueReporting

// MARK: - Failure Result Assembly

// reportIssue must be called from the Swift Testing async context, not the GCD thread where
// this function executes — Swift Testing's task-locals are not available on GCD threads, so the
// caller must collect the rendered message and report it after awaiting dispatchToGCD.

/// Assembles the final ``ContractResult`` for a concurrent contract failure.
///
/// Re-drains the failing schedule with trace recording enabled, runs a sequential oracle to capture the expected (race-free) SUT state, and renders the failure report. Returns both the result and the rendered failure message for the caller to report.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func buildFailureResult<Spec: AsyncContractSpec>(
    finalInput: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec,
    concurrencyLevel: Int,
    idleTimeout: Int,
    seed: UInt64?,
    discoveryMethod: ContractDiscoveryMethod,
    timedOut: Bool,
    failureContext: inout FailureContext
) -> (result: ContractResult<Spec>, issueMessage: String) {
    let traceResult = drainSchedule(
        taggedCommands: finalInput,
        specInit: specInit,
        concurrencyLevel: concurrencyLevel,
        recordTrace: true,
        idleTimeoutMilliseconds: idleTimeout
    )
    let trace = traceResult.trace

    // Run the commands sequentially on a fresh spec. If the sequential replay passes, the resulting state is the expected outcome — what the system should have produced without the race.
    let oracle = timedOut ? nil : sequentialOracle(commands: finalInput.map(\.1), specInit: specInit, idleTimeoutMilliseconds: idleTimeout)

    let result = ContractResult<Spec>(
        commands: finalInput.map(\.1),
        trace: trace,
        systemUnderTest: oracle?.systemUnderTest ?? Spec().systemUnderTest,
        seed: seed,
        discoveryMethod: discoveryMethod
    )

    failureContext.discoveryMethod = discoveryMethod
    failureContext.timedOut = timedOut
    failureContext.oracleDescription = oracle.map { oracle in
        let hasModel = oracle.modelDescription != "(no model properties)"
        return hasModel
            ? "Expected result (from sequential replay of @Model):\n  \(oracle.modelDescription)"
            : "Expected result (from sequential replay of @SystemUnderTest):\n  \(oracle.sutDescription)"
    }
    let message = renderFailure(finalInput, trace: trace, context: failureContext)

    return (result, message)
}

// MARK: - Runner Entry Point

/// Runs a concurrent contract property test for the given async specification type.
///
/// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``drainSchedule(taggedCommands:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer shrinks both the command sequence and the lane assignments.
///
/// The same seed always produces the same interleaving and the same counterexample.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@discardableResult
public func __runContractConcurrent<Spec: AsyncContractSpec>(
    _: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    var config: ResolvedConcurrentConfig
    switch ResolvedConcurrentConfig.parse(settings) {
    case let .success(resolved):
        config = resolved
    case let .invalidReplaySeed(seed):
        reportIssue(
            "Invalid replay seed: \(seed)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
        return nil
    }
    precondition((1 ... 8).contains(config.concurrencyLevel), "concurrencyLevel must be between 1 and 8")

    #if canImport(Testing)
        let traitConfig = ExhaustTraitConfiguration.current
        let regressionSeeds = traitConfig?.regressions ?? []
        if let traitConfig {
            let hasInlineBudget = settings.contains {
                if case .budget = $0 { true } else { false }
            }
            if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                config.budget = traitBudget
            }
        }
    #endif

    // The drain loop inside drainSchedule calls runSynchronously in a tight polling loop on whatever thread hosts it. When that thread belongs to the cooperative pool, parallel test suites each occupy a cooperative thread with a spin-wait, starving the pool and preventing the Swift runtime from scheduling the Task continuations that feed the drain loop — a deadlock under parallel execution on machines with few cores. Dispatching the entire pipeline to a GCD thread moves all drain loops off the cooperative pool. GCD grows its thread pool dynamically, so concurrent drain loops cannot exhaust it.
    let logConfiguration = ExhaustLog.Configuration(isEnabled: config.suppressLogs == false, minimumLevel: config.logLevel, format: config.logFormat)
    let outcome: (ContractResult<Spec>?, [String]) = await __ExhaustRuntime.dispatchToGCD {
        ExhaustLog.withConfiguration(logConfiguration) { () -> (ContractResult<Spec>?, [String]) in
            let runStart = ContinuousClock.now
            nonisolated(unsafe) var report = ExhaustReport()
            nonisolated(unsafe) var coverageInvocations = 0
            var deferredIssues: [String] = []
            let statsAccumulator: OpenPBTStatsAccumulator? = config.collectOpenPBTStats
                ? OpenPBTStatsAccumulator(propertyName: "\(fileID)")
                : nil

            var failureContext = FailureContext()
            failureContext.specName = "\(Spec.self)"

            let commandGen = Spec.commandGenerator.gen
            let samplingBudget = config.budget.samplingBudget
            let coverageBudget = config.budget.coverageBudget
            let resolvedCommandLimit = config.commandLimit ?? min(estimateCommandLimit(
                commandGen: commandGen,
                coverageBudget: coverageBudget
            ), 40)
            let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
            let sequenceGen = Gen.arrayOf(
                taggedCommandGen,
                within: 1 ... UInt64(resolvedCommandLimit),
                scaling: .constant
            )
            let reductionConfig = Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: UInt64(samplingBudget) * 5 * 1_000_000
            )

            // Safe: metatypes are stateless.
            nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

            let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
            let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int> = { taggedCommands in
                rawIdentifySkips(taggedCommands.map(\.1))
            }
            let concurrencyLevel = config.concurrencyLevel
            let idleTimeout = config.idleTimeout
            let lastRunTimedOut = UnsafeSendableBox(false)
            let invocationCounter = UnsafeSendableBox(0)
            let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
                invocationCounter.value += 1
                let result = drainSchedule(taggedCommands: taggedCommands, specInit: specInit, concurrencyLevel: concurrencyLevel, recordTrace: false, idleTimeoutMilliseconds: idleTimeout)
                lastRunTimedOut.value = result.timedOut
                return result.passed
            }

            defer {
                let samplingInvocations = invocationCounter.value - coverageInvocations
                report.totalMilliseconds = Double((ContinuousClock.now - runStart).components.attoseconds) / 1e15
                report.setInvocations(coverage: coverageInvocations, randomSampling: samplingInvocations, reduction: report.reductionInvocations)
                report.seed = config.seed
                if let statsAccumulator {
                    let lines = statsAccumulator.finalize()
                    if lines.isEmpty == false {
                        report.openPBTStatsLines = lines
                    }
                }
                config.onReportClosure?(report)
            }

            #if canImport(Testing)
                if regressionSeeds.isEmpty == false {
                    for encodedSeed in regressionSeeds {
                        guard let regressionSeed = CrockfordBase32.decode(encodedSeed) else {
                            deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                            continue
                        }
                        var regressionInterpreter = ValueAndChoiceTreeInterpreter(
                            sequenceGen,
                            materializePicks: true,
                            seed: regressionSeed,
                            maxRuns: 1
                        )
                        if let (input, _) = try? regressionInterpreter.next() {
                            let passed = property(input)
                            if passed == false {
                                var ctx = failureContext
                                ctx.seed = regressionSeed
                                ctx.originalCount = input.count
                                ctx.sequencesTested = 1
                                let failure = buildFailureResult(
                                    finalInput: input,
                                    specInit: specInit,
                                    concurrencyLevel: concurrencyLevel,
                                    idleTimeout: idleTimeout,
                                    seed: regressionSeed,
                                    discoveryMethod: .replay,
                                    timedOut: false,
                                    failureContext: &ctx
                                )
                                if config.suppressIssueReporting == false {
                                    deferredIssues.append(failure.issueMessage)
                                }
                                return (failure.result, deferredIssues)
                            } else if config.suppressIssueReporting == false {
                                deferredIssues.append("Regression seed \"\(encodedSeed)\" now passes — consider removing it.")
                            }
                        }
                    }
                }
            #endif

            let coverageStart = ContinuousClock.now
            if config.seed == nil, coverageBudget > 0, config.useRandomOnly == false {
                if let scaResult = runConcurrentSCACoverage(
                    seqGen: sequenceGen,
                    commandGen: commandGen,
                    commandLimit: resolvedCommandLimit,
                    coverageBudget: coverageBudget,
                    concurrencyLevel: concurrencyLevel,
                    idleTimeout: idleTimeout,
                    property: property,
                    identifySkips: identifySkips,
                    lastRunTimedOut: lastRunTimedOut
                ) {
                    if let stats = scaResult.reductionStats {
                        report.applyReductionStats(stats)
                    }
                    report.reductionInvocations = scaResult.reductionInvocations

                    var ctx = failureContext
                    ctx.originalCount = scaResult.originalCount
                    ctx.iteration = Int(scaResult.iteration)
                    ctx.budget = coverageBudget
                    ctx.sequencesTested = invocationCounter.value + scaResult.reductionInvocations
                    let failure: (result: ContractResult<Spec>, issueMessage: String) = buildFailureResult(
                        finalInput: scaResult.finalInput,
                        specInit: specInit,
                        concurrencyLevel: concurrencyLevel,
                        idleTimeout: idleTimeout,
                        seed: nil,
                        discoveryMethod: .coverage,
                        timedOut: scaResult.timedOut,
                        failureContext: &ctx
                    )
                    if config.suppressIssueReporting == false {
                        deferredIssues.append(failure.issueMessage)
                    }

                    coverageInvocations = invocationCounter.value
                    report.coverageMilliseconds = Double((ContinuousClock.now - coverageStart).components.attoseconds) / 1e15
                    return (failure.result, deferredIssues)
                }
            }
            coverageInvocations = invocationCounter.value
            report.coverageMilliseconds = Double((ContinuousClock.now - coverageStart).components.attoseconds) / 1e15

            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                materializePicks: true,
                seed: config.seed,
                maxRuns: samplingBudget
            )
            let actualSeed = interpreter.baseSeed

            var samplingIteration = 0
            do {
                while let (input, tree) = try interpreter.next() {
                    samplingIteration += 1
                    let passed = property(input)
                    statsAccumulator?.record(
                        representation: "\(input.map { "[\($0.0)] \($0.1)" })",
                        passed: passed,
                        tree: tree,
                        phase: .random
                    )

                    if passed == false {
                        ExhaustLog.notice(
                            category: .propertyTest,
                            event: "concurrent_failure_found",
                            metadata: ["commands": "\(input.count)", "timedOut": "\(lastRunTimedOut.value)"]
                        )
                        for (marker, cmd) in input {
                            ExhaustLog.debug(
                                category: .propertyTest,
                                event: "concurrent_initial_command",
                                "[\(marker.description)] \(cmd)"
                            )
                        }

                        let finalInput: [(ScheduleMarker, Spec.Command)]

                        if lastRunTimedOut.value {
                            ExhaustLog.notice(
                                category: .propertyTest,
                                event: "concurrent_timeout_skipping_reduction"
                            )
                            finalInput = input
                        } else {
                            let (reduceValue, reduceTree) = pruneSkippedCommands(
                                value: input,
                                tree: tree,
                                generator: sequenceGen,
                                seed: 0,
                                property: property,
                                identifySkips: identifySkips,
                                logEvent: "concurrent_skip_pruning"
                            )

                            nonisolated(unsafe) var reductionPropertyInvocations = 0
                            let countingProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
                                reductionPropertyInvocations += 1
                                return property(taggedCommands)
                            }
                            let reductionStart = ContinuousClock.now
                            let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                                gen: sequenceGen,
                                tree: reduceTree,
                                output: reduceValue,
                                config: reductionConfig,
                                property: countingProperty
                            )
                            report.applyReductionStats(reduceResult.stats)
                            report.reductionMilliseconds = Double((ContinuousClock.now - reductionStart).components.attoseconds) / 1e15
                            report.reductionInvocations = reductionPropertyInvocations

                            if let (_, reduced) = reduceResult.reduced {
                                ExhaustLog.notice(
                                    category: .propertyTest,
                                    event: "concurrent_reduced",
                                    metadata: ["from": "\(input.count)", "to": "\(reduced.count)"]
                                )
                                for (marker, cmd) in reduced {
                                    ExhaustLog.debug(
                                        category: .propertyTest,
                                        event: "concurrent_reduced_command",
                                        "[\(marker.description)] \(cmd)"
                                    )
                                }
                                finalInput = reduced
                            } else {
                                ExhaustLog.notice(
                                    category: .propertyTest,
                                    event: "concurrent_reduction_no_improvement"
                                )
                                finalInput = reduceValue
                            }
                        }

                        let discoveryMethod: ContractDiscoveryMethod = config.seed != nil ? .replay : .randomSampling
                        var ctx = failureContext
                        ctx.seed = actualSeed
                        ctx.originalCount = input.count
                        ctx.iteration = samplingIteration
                        ctx.budget = samplingBudget
                        ctx.sequencesTested = invocationCounter.value + report.reductionInvocations
                        let failure = buildFailureResult(
                            finalInput: finalInput,
                            specInit: specInit,
                            concurrencyLevel: concurrencyLevel,
                            idleTimeout: idleTimeout,
                            seed: actualSeed,
                            discoveryMethod: discoveryMethod,
                            timedOut: lastRunTimedOut.value,
                            failureContext: &ctx
                        )
                        if config.suppressIssueReporting == false {
                            deferredIssues.append(failure.issueMessage)
                        }
                        return (failure.result, deferredIssues)
                    }
                }
            } catch {
                deferredIssues.append("Concurrent contract runner error: \(error)")
            }

            return (nil as ContractResult<Spec>?, deferredIssues)
        } // withConfiguration
    } // dispatchToGCD
    for issue in outcome.1 {
        reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
    }
    return outcome.0
}
