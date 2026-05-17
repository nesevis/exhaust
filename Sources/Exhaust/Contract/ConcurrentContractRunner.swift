// Generate / test / reduce loop for concurrent contract testing.
//
// Inspired by Claessen, Palka, Smallbone, Hughes, Svensson, Arts, and Wiger, "Finding Race Conditions in Erlang with QuickCheck and PULSE" (ICFP 2009). That work combines QuickCheck's eqc_par_statem with a user-level scheduler (PULSE) that records and replays Erlang process schedules for deterministic concurrency testing.
//
// This implementation adapts the approach to Swift Concurrency:
// - Schedule markers encoded as reducible chooseBits replace PULSE's external schedule;
// - A cooperative TaskExecutor-based drain loop replaces the Erlang VM instrumentation.
// - The key architectural difference is that the schedule is part of the generated input (not an external random choice), so reduction operates on schedule and commands jointly; no separate ?ALWAYS(N, Prop) wrapper is needed for shrinking stability.
import ExhaustCore
import IssueReporting

/// Runs a concurrent contract property test for the given async specification type.
///
/// Generates random tagged command sequences where each command carries a schedule marker assigning it to one of N concurrent lanes or the sequential prefix. The cooperative scheduler (``drainSchedule(taggedCommands:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``) executes the sequence with deterministic interleaving controlled by the marker order. When a failure is found, the choice-graph reducer shrinks both the command sequence and the lane assignments.
///
/// The same seed always produces the same interleaving and the same counterexample.
@discardableResult
public func __runContractConcurrent<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    var commandLimit: Int?
    var concurrencyLevel = 2
    var budget = ExhaustBudget.thorough
    var seed: UInt64?
    var idleTimeout = 1000
    var suppressIssueReporting = false
    var suppressLogs = false
    var useRandomOnly = false
    var collectOpenPBTStats = false
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error
    var logFormat: LogFormat = .keyValue
    for setting in settings {
        switch setting {
        case let .concurrency(level):
            concurrencyLevel = level
        case let .budget(b):
            budget = b
        case let .commandLimit(limit):
            commandLimit = limit
        case let .replay(replaySeed):
            seed = replaySeed.resolve()
            if seed == nil {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return nil
            }
        case let .suppress(option):
            switch option {
            case .issueReporting:
                suppressIssueReporting = true
            case .logs:
                suppressLogs = true
            case .all:
                suppressIssueReporting = true
                suppressLogs = true
            }
        case .randomOnly:
            useRandomOnly = true
        case .collectOpenPBTStats:
            collectOpenPBTStats = true
        case let .onReport(closure):
            if let existing = onReportClosure {
                let chained = existing
                onReportClosure = { report in
                    chained(report)
                    closure(report)
                }
            } else {
                onReportClosure = closure
            }
        case let .idleTimeoutMs(ms):
            idleTimeout = ms
        case let .logging(level, format):
            logLevel = level
            logFormat = format
        }
    }
    precondition((1 ... 8).contains(concurrencyLevel), "concurrencyLevel must be between 1 and 8")

    #if canImport(Testing)
        if let traitConfig = ExhaustTraitConfiguration.current {
            let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
            if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                budget = traitBudget
            }
        }
    #endif

    return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
    let runStart = ContinuousClock.now
    nonisolated(unsafe) var report = ExhaustReport()
    nonisolated(unsafe) var coverageInvocations = 0
    let statsAccumulator: OpenPBTStatsAccumulator? = collectOpenPBTStats
        ? OpenPBTStatsAccumulator(propertyName: "\(fileID)")
        : nil

    var failureContext = FailureContext()
    failureContext.specName = "\(Spec.self)"

    let commandGen = Spec.commandGenerator.gen
    let samplingBudget = budget.samplingBudget
    let coverageBudget = budget.coverageBudget
    let resolvedCommandLimit = commandLimit ?? min(estimateCommandLimit(
        commandGen: commandGen,
        coverageBudget: coverageBudget
    ), 40)
    let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: concurrencyLevel)
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
    let resolvedConcurrencyLevel = concurrencyLevel
    let resolvedIdleTimeout = idleTimeout
    let lastRunTimedOut = SendableBox(false)
    let invocationCounter = SendableBox(0)
    let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
        invocationCounter.value += 1
        let result = drainSchedule(taggedCommands: taggedCommands, specInit: specInit, concurrencyLevel: resolvedConcurrencyLevel, recordTrace: false, idleTimeoutMilliseconds: resolvedIdleTimeout)
        lastRunTimedOut.value = result.timedOut
        return result.passed
    }

    defer {
        let samplingInvocations = invocationCounter.value - coverageInvocations
        report.totalMilliseconds = Double((ContinuousClock.now - runStart).components.attoseconds) / 1e15
        report.setInvocations(coverage: coverageInvocations, randomSampling: samplingInvocations, reduction: report.reductionInvocations)
        report.seed = seed
        if let statsAccumulator {
            let lines = statsAccumulator.finalize()
            if lines.isEmpty == false {
                report.openPBTStatsLines = lines
            }
        }
        onReportClosure?(report)
    }

    // --- Phase 0: Regression seeds from .exhaust(regressions:) trait ---
    #if canImport(Testing)
        if let traitConfig = ExhaustTraitConfiguration.current, traitConfig.regressions.isEmpty == false {
            for encodedSeed in traitConfig.regressions {
                guard let regressionSeed = CrockfordBase32.decode(encodedSeed) else {
                    reportIssue(
                        "Invalid regression seed: \(encodedSeed)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
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
                        let traceResult = drainSchedule(taggedCommands: input, specInit: specInit, concurrencyLevel: concurrencyLevel, recordTrace: true, idleTimeoutMilliseconds: idleTimeout)
                        let specState = captureSpecState(taggedCommands: input, specInit: specInit)
                        let result = ContractResult<Spec>(
                            commands: input.map(\.1),
                            trace: traceResult.trace,
                            systemUnderTest: specState.systemUnderTest,
                            seed: regressionSeed,
                            discoveryMethod: .replay
                        )
                        if suppressIssueReporting == false {
                            var ctx = failureContext
                            ctx.discoveryMethod = .replay
                            ctx.seed = regressionSeed
                            ctx.originalCount = input.count
                            ctx.sequencesTested = 1
                            ctx.modelDescription = specState.modelDescription
                            ctx.sutDescription = "\(specState.systemUnderTest)"
                            let message = renderFailure(input, trace: traceResult.trace, context: ctx)
                            reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
                        }
                        return result
                    } else if suppressIssueReporting == false {
                        reportIssue(
                            "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                    }
                }
            }
        }
    #endif

    // --- Phase 1: SCA coverage (command-type orderings with random lane assignments) ---
    let coverageStart = ContinuousClock.now
    if seed == nil && coverageBudget > 0 && useRandomOnly == false {
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
            let traceResult = drainSchedule(taggedCommands: scaResult.finalInput, specInit: specInit, concurrencyLevel: concurrencyLevel, recordTrace: true, idleTimeoutMilliseconds: idleTimeout)
            let trace = traceResult.trace
            let specState = scaResult.timedOut ? nil : captureSpecState(taggedCommands: scaResult.finalInput, specInit: specInit)
            let result = ContractResult<Spec>(
                commands: scaResult.finalInput.map(\.1),
                trace: trace,
                systemUnderTest: specState?.systemUnderTest ?? Spec().systemUnderTest,
                seed: nil,
                discoveryMethod: .coverage
            )

            if suppressIssueReporting == false {
                var ctx = failureContext
                ctx.discoveryMethod = .coverage
                ctx.originalCount = scaResult.originalCount
                ctx.iteration = Int(scaResult.iteration)
                ctx.budget = coverageBudget
                ctx.sequencesTested = invocationCounter.value + scaResult.reductionInvocations
                ctx.timedOut = scaResult.timedOut
                if let specState {
                    ctx.modelDescription = specState.modelDescription
                    ctx.sutDescription = "\(specState.systemUnderTest)"
                }
                let message = renderFailure(scaResult.finalInput, trace: trace, context: ctx)
                reportIssue(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            coverageInvocations = invocationCounter.value
            report.coverageMilliseconds = Double((ContinuousClock.now - coverageStart).components.attoseconds) / 1e15
            return result
        }
    }
    coverageInvocations = invocationCounter.value
    report.coverageMilliseconds = Double((ContinuousClock.now - coverageStart).components.attoseconds) / 1e15

    // --- Phase 2: Random sampling ---
    var interpreter = ValueAndChoiceTreeInterpreter(
        sequenceGen,
        materializePicks: true,
        seed: seed,
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

                let traceResult = drainSchedule(taggedCommands: finalInput, specInit: specInit, concurrencyLevel: concurrencyLevel, recordTrace: true, idleTimeoutMilliseconds: idleTimeout)
                let trace = traceResult.trace
                let specState = lastRunTimedOut.value ? nil : captureSpecState(taggedCommands: finalInput, specInit: specInit)
                let result = ContractResult<Spec>(
                    commands: finalInput.map(\.1),
                    trace: trace,
                    systemUnderTest: specState?.systemUnderTest ?? Spec().systemUnderTest,
                    seed: actualSeed,
                    discoveryMethod: seed != nil ? .replay : .randomSampling
                )

                if suppressIssueReporting == false {
                    var ctx = failureContext
                    ctx.discoveryMethod = seed != nil ? .replay : .randomSampling
                    ctx.seed = actualSeed
                    ctx.originalCount = input.count
                    ctx.iteration = samplingIteration
                    ctx.budget = samplingBudget
                    ctx.sequencesTested = invocationCounter.value + report.reductionInvocations
                    ctx.timedOut = lastRunTimedOut.value
                    if let specState {
                        ctx.modelDescription = specState.modelDescription
                        ctx.sutDescription = "\(specState.systemUnderTest)"
                    }
                    let message = renderFailure(finalInput, trace: trace, context: ctx)
                    reportIssue(
                        message,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                }

                return result
            }
        }
    } catch {
        reportIssue(
            "Concurrent contract runner error: \(error)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    return nil
    } // withConfiguration
}

// MARK: - Generator Construction

/// Zips a schedule marker generator onto each branch of the command pick.
///
/// Takes the spec's command generator (a `pick` over weighted command branches) and prepends a `chooseBits(0...N)` schedule marker to each branch via `zip`, where N is the concurrency level. The resulting generator produces `(ScheduleMarker, Command)` tuples where the marker controls lane assignment and the command is the original spec command with all its argument generators intact. The array order of non-prefix markers defines the interleaving schedule. The reducer shrinks counterexamples by deleting elements (shorter sequence) and minimizing markers toward 0 (moving commands from concurrent lanes into the sequential prefix).
///
/// The structure after transformation:
/// ```
/// pick([
///     (w, zip(marker, genCommandA)),
///     (w, zip(marker, genCommandB)),
///     ...
/// ])
/// ```
///
/// This gives each array element a pick-at-top structure that the choice-graph reducer handles naturally: structural deletion removes entire elements (shorter counterexample), and value minimization on the marker's chooseBits drives it toward 0/prefix (less concurrency).
private extension Gen {
    static func chooseLaneControl(in range: ClosedRange<UInt8>) -> Generator<UInt8> {
        let operation = ReflectiveOperation.chooseBits(
            min: UInt64(range.lowerBound),
            max: UInt64(range.upperBound),
            tag: .laneControl,
            isRangeExplicit: true
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                fatalError("chooseLaneControl: unexpected result type")
            }
            return .pure(UInt8(convertible.bitPattern64))
        }
    }
}

private func zipScheduleMarker<Command>(
    onto commandGen: Generator<Command>,
    concurrencyLevel: Int
) -> Generator<(ScheduleMarker, Command)> {
    guard let choices = extractPickChoices(from: commandGen) else {
        fatalError("Command generator is in unexpected format")
    }

    // The marker tag controls whether lane assignments appear as parameters in the covering array. At concurrencyLevel <= 3, the per-position domain grows by a factor of (lanes + 1):
    //   2 lanes: x3 (prefix/A/B)   → 3 commands x 3 markers =  9, ~81 rows at t=2
    //   3 lanes: x4 (prefix/A/B/C) → 3 commands x 4 markers = 12, ~144 rows at t=2
    // This keeps the combinatorial growth bounded while including lane assignments in the covering array alongside command types and their arguments.
    //
    // At concurrencyLevel 4+, the multiplier grows to x5...x9 and rows scale quadratically with domain size: 3 commands x 5 markers = 15 → ~225 rows; x9 = 27 → ~729 rows. The .laneControl tag excludes the marker from coverage, keeping row count at commandTypes² and leaving lane exploration to random sampling.
    let markerGen: Generator<ScheduleMarker> = switch concurrencyLevel {
    case 1:
        Gen.just(ScheduleMarker.prefix)
    case 2 ... 3:
        Gen.choose(in: UInt8(0) ... UInt8(concurrencyLevel))
            .map { ScheduleMarker(rawValue: $0) }
    default:
        Gen.chooseLaneControl(in: 0 ... UInt8(concurrencyLevel))
            .map { ScheduleMarker(rawValue: $0) }
    }
    let taggedChoices = choices.map { choice in
        let branchGen: Generator<Command> = choice.generator.map { $0 as! Command }
        let zipped = Gen.zip(markerGen, branchGen)
        return (weight: choice.weight, generator: zipped)
    }

    return Gen.pick(choices: taggedChoices)
}

// MARK: - Spec State Capture

/// Replays a tagged command sequence sequentially on a fresh spec to capture the model and SUT descriptions at the point of failure.
///
/// Runs all commands as prefix (ignoring lane assignments) so the model state reflects the full sequence in array order. Returns the spec's ``modelDescription`` and ``systemUnderTest`` from the diverged state.
private func captureSpecState<Spec: AsyncContractSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec
) -> (modelDescription: String, systemUnderTest: Spec.SystemUnderTest) {
    let commands = taggedCommands.map(\.1)
    let spec = SendableBox(specInit())
    let runQueue = RunQueue(laneCount: 1)
    let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
    let done = SendableBox(false)

    Task(executorPreference: executor) { @Sendable [spec] in
        for command in commands {
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
            } catch {
                break
            }
        }
        done.value = true
    }

    while done.value == false {
        guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else { continue }
        job.runSynchronously(on: executor.asUnownedTaskExecutor())
    }

    return (modelDescription: spec.value.modelDescription, systemUnderTest: spec.value.systemUnderTest)
}

// MARK: - Skip Pruning

/// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree that still fail the property.
///
/// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree, the tree is rematerialized, and the property is re-checked. If the pruned sequence still fails, the pruned value and tree are returned; otherwise the originals are returned unchanged.
private func pruneSkippedCommands<Value>(
    value: Value,
    tree: ChoiceTree,
    generator: Generator<Value>,
    seed: UInt64,
    property: @Sendable (Value) -> Bool,
    identifySkips: (Value) -> Set<Int>,
    logEvent: String
) -> (value: Value, tree: ChoiceTree) {
    let skippedIndices = identifySkips(value)
    guard skippedIndices.isEmpty == false else {
        return (value, tree)
    }

    ExhaustLog.notice(
        category: .reducer,
        event: logEvent,
        metadata: ["skipped_count": "\(skippedIndices.count)"]
    )
    let prunedTree = pruneSequenceElements(from: tree, at: skippedIndices)
    let prunedSequence = ChoiceSequence.flatten(prunedTree)
    let prunedMode = Materializer.Mode.guided(seed: seed, fallbackTree: nil)
    if case let .success(rematerialized, rematerializedTree, _) = Materializer.materialize(
        generator, prefix: prunedSequence, mode: prunedMode, fallbackTree: prunedTree
    ),
        property(rematerialized) == false
    {
        return (rematerialized, rematerializedTree)
    }
    return (value, tree)
}

// MARK: - SCA Coverage Phase

private struct SCAFailureResult<Command> {
    var finalInput: [(ScheduleMarker, Command)]
    var originalCount: Int
    var iteration: UInt64
    var timedOut: Bool
    var reductionStats: ReductionStats?
    var reductionInvocations: Int = 0
}

/// Runs SCA coverage for concurrent contract command sequences.
///
/// Builds a covering array over command-type orderings (the schedule marker is tagged `.laneControl` and excluded from the covering array parameters). Each row materializes a specific command ordering with random lane assignments, testing the property under deterministic interleaving.
///
/// - Returns: A failure result if a counterexample is found during coverage, or nil if all rows pass.
private func runConcurrentSCACoverage<Command>(
    seqGen: Generator<[(ScheduleMarker, Command)]>,
    commandGen: Generator<Command>,
    commandLimit: Int,
    coverageBudget: UInt64,
    concurrencyLevel: Int,
    idleTimeout: Int,
    property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
    identifySkips: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Set<Int>,
    lastRunTimedOut: SendableBox<Bool>
) -> SCAFailureResult<Command>? {
    guard let pickChoices = extractPickChoices(from: commandGen) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Command generator is not a top-level pick — SCA not applicable"
        )
        return nil
    }

    let sequenceLength = commandLimit
    guard sequenceLength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Sequence length must be >= 2 for SCA"
        )
        return nil
    }

    let strengthCap = switch sequenceLength {
    case ...6: 6
    case ...8: 5
    case ...12: 4
    case ...20: 3
    default: 2
    }

    guard let domain = SCADomain.build(
        sequenceLength: sequenceLength,
        pickChoices: pickChoices,
        coverageBudget: coverageBudget,
        strengthCap: strengthCap
    ) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Domain construction failed"
        )
        return nil
    }

    let domainSizes = domain.profile.domainSizes
    let strength = min(domain.maxStrength, domainSizes.count, 4)
    guard strength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "concurrent_sca_skipped",
            "Too few parameters for covering array"
        )
        return nil
    }

    let generator = PullBasedCoveringArrayGenerator(
        domainSizes: domainSizes,
        strength: strength
    )
    let lengthRange = UInt64(0) ... UInt64(commandLimit)
    let reductionConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

    var iterations: UInt64 = 0
    while iterations < coverageBudget, let row = generator.next() {
        let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
        guard let tree else { continue }

        let mode = Materializer.Mode.guided(
            seed: iterations,
            fallbackTree: nil
        )
        guard case let .success(value, freshTree, _) = Materializer.materialize(
            seqGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree
        ) else {
            continue
        }

        iterations += 1
        if property(value) == false {
            let timedOut = lastRunTimedOut.value
            ExhaustLog.notice(
                category: .propertyTest,
                event: "concurrent_sca_failure",
                metadata: ["iteration": "\(iterations)", "commands": "\(value.count)", "timedOut": "\(timedOut)"]
            )

            if timedOut {
                return SCAFailureResult(finalInput: value, originalCount: value.count, iteration: iterations, timedOut: true)
            }

            let (reduceValue, reduceTree) = pruneSkippedCommands(
                value: value,
                tree: freshTree,
                generator: seqGen,
                seed: iterations,
                property: property,
                identifySkips: identifySkips,
                logEvent: "concurrent_sca_skip_pruning"
            )

            nonisolated(unsafe) var reductionPropertyInvocations = 0
            let countingProperty: @Sendable ([(ScheduleMarker, Command)]) -> Bool = { taggedCommands in
                reductionPropertyInvocations += 1
                return property(taggedCommands)
            }
            if let reduceResult = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: seqGen,
                tree: reduceTree,
                output: reduceValue,
                config: reductionConfig,
                property: countingProperty
            ) {
                if let (_, reduced) = reduceResult.reduced {
                    return SCAFailureResult(finalInput: reduced, originalCount: value.count, iteration: iterations, timedOut: false, reductionStats: reduceResult.stats, reductionInvocations: reductionPropertyInvocations)
                }
                return SCAFailureResult(finalInput: reduceValue, originalCount: value.count, iteration: iterations, timedOut: false, reductionStats: reduceResult.stats, reductionInvocations: reductionPropertyInvocations)
            }
            return SCAFailureResult(finalInput: reduceValue, originalCount: value.count, iteration: iterations, timedOut: false)
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "concurrent_sca_coverage",
        metadata: [
            "command_types": "\(pickChoices.count)",
            "iterations": "\(iterations)",
            "sequence_length": "\(sequenceLength)",
            "strength": "\(strength)",
        ]
    )

    return nil
}

