// MARK: - Generate / Test / Reduce Loop for Concurrent Contracts
//
// Orchestrates the property-testing loop: generate a tagged command sequence, drain it through the cooperative scheduler, and if a failure is found, reduce it with the choice-graph reducer.
//
// The generator produces [(ScheduleMarker, Command)] arrays. Each element has a schedule marker (chooseBits in 0...N) zipped with a command from the spec's weighted pick. The array order defines both the lane partition and the interleaving schedule. The reducer shrinks the counterexample by deleting elements (shorter sequence) and minimizing markers toward 0 (moving commands from concurrent lanes into the sequential prefix).
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
                        if !suppressIssueReporting {
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
                    } else if !suppressIssueReporting {
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

            if !suppressIssueReporting {
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

                if !suppressIssueReporting {
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
/// Takes the spec's command generator (a `pick` over weighted command branches) and prepends a `chooseBits(0...N)` schedule marker to each branch via `zip`, where N is the concurrency level. The resulting generator produces `(ScheduleMarker, Command)` tuples where the marker controls lane assignment and the command is the original spec command with all its argument generators intact.
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

// MARK: - Trace parsing

/// Converts raw trace markers into presentable TraceSteps with phase annotations.
///
/// Performs three post-processing passes: (1) parses colon-delimited markers into steps with structured lane metadata, (2) removes suspended/resumed pairs where no interleaving actually occurred between them, and (3) collapses adjacent started+completed pairs into a single entry.
func parseTrace(_ raw: [String]) -> [TraceStep] {
    var steps: [(step: TraceStep, lane: String)] = []
    var openCommand: [String: String] = [:]
    var stepNumber = 0

    for entry in raw {
        let parts = entry.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count >= 2 else { continue }
        let kind = parts[0]
        let lane = parts[1]
        let label = parts.count >= 3 ? parts[2] : parts[1]

        switch kind {
        case "STARTED":
            if lane != "prefix" {
                openCommand[lane] = label
            }
            stepNumber += 1
            let phase = lane == "prefix" ? "(prefix)" : "(started)"
            steps.append((TraceStep(index: stepNumber, command: "\(label) \(phase)", outcome: .ok), lane))
        case "COMPLETED":
            openCommand[lane] = nil
            if lane == "prefix" {
                if let lastIndex = steps.lastIndex(where: { $0.step.command == "\(label) (prefix)" }) {
                    steps.remove(at: lastIndex)
                    stepNumber -= 1
                }
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(label) (prefix)", outcome: .ok), lane))
            } else {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(label) (completed)", outcome: .ok), lane))
            }
        case "FAILED":
            openCommand[lane] = nil
            let message = parts.count >= 4 ? parts[3] : "failed"
            stepNumber += 1
            let phase = lane == "prefix" ? "(prefix)" : "(completed)"
            steps.append((TraceStep(index: stepNumber, command: "\(label) \(phase)", outcome: .invariantFailed(name: message)), lane))
        case "SUSPENDED":
            if let current = openCommand[lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (suspended)", outcome: .ok), lane))
            }
        case "RESUMED":
            if let current = openCommand[lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (resumed)", outcome: .ok), lane))
            }
        default:
            break
        }
    }

    // Remove suspended/resumed pairs where no other lane ran between them.
    var filtered: [(step: TraceStep, lane: String)] = []
    var index = 0
    while index < steps.count {
        let entry = steps[index]
        if entry.step.command.hasSuffix("(suspended)") {
            let commandBase = entry.step.command.replacingOccurrences(of: " (suspended)", with: "")
            var hasInterleaving = false
            var resumeIndex: Int?
            for ahead in (index + 1) ..< steps.count {
                let aheadCmd = steps[ahead].step.command
                if aheadCmd.hasPrefix(commandBase) &&
                    (aheadCmd.hasSuffix("(resumed)") || aheadCmd.hasSuffix("(completed)"))
                {
                    resumeIndex = ahead
                    break
                }
                if steps[ahead].lane != entry.lane {
                    hasInterleaving = true
                }
            }

            if hasInterleaving {
                filtered.append(entry)
            } else if let ri = resumeIndex, steps[ri].step.command.hasSuffix("(resumed)") {
                index = ri + 1
                continue
            } else {
                filtered.append(entry)
            }
        } else {
            filtered.append(entry)
        }
        index += 1
    }

    // Collapse: started immediately followed by completed for the same command
    var collapsed: [TraceStep] = []
    index = 0
    while index < filtered.count {
        if index + 1 < filtered.count,
           filtered[index].step.command.hasSuffix("(started)"),
           filtered[index + 1].step.command.hasSuffix("(completed)")
        {
            let startCmd = filtered[index].step.command.replacingOccurrences(of: " (started)", with: "")
            let nextCmd = filtered[index + 1].step.command.replacingOccurrences(of: " (completed)", with: "")
            if startCmd == nextCmd {
                collapsed.append(TraceStep(
                    index: collapsed.count + 1,
                    command: "\(startCmd) (completed)",
                    outcome: filtered[index + 1].step.outcome
                ))
                index += 2
                continue
            }
        }
        collapsed.append(TraceStep(
            index: collapsed.count + 1,
            command: filtered[index].step.command,
            outcome: filtered[index].step.outcome
        ))
        index += 1
    }

    return collapsed
}

// MARK: - Failure rendering

private struct FailureContext {
    var specName: String = ""
    var discoveryMethod: ContractDiscoveryMethod = .randomSampling
    var seed: UInt64?
    var iteration: Int = 0
    var budget: UInt64 = 0
    var originalCount: Int = 0
    var sequencesTested: Int = 0
    var modelDescription: String = "(unavailable)"
    var sutDescription: String = "(unavailable)"
    var timedOut: Bool = false
}

private func renderFailure(
    _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
    trace: [TraceStep],
    context: FailureContext
) -> String {
    if context.timedOut {
        return renderTimeout(tagged, trace: trace)
    }

    var lines: [String] = []
    if let seed = context.seed {
        lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod), seed \(CrockfordBase32.encode(seed)))")
    } else {
        lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod))")
    }
    lines.append("")

    if tagged.count < context.originalCount {
        lines.append("Reduced from \(context.originalCount) to \(tagged.count) commands.")
        lines.append("")
    }

    renderCommandPartition(tagged, into: &lines)

    lines.append("Execution trace:")
    for step in trace {
        lines.append("  \(step)")
    }

    lines.append("")
    lines.append("Model: \(context.modelDescription)")
    lines.append("SUT:   \(context.sutDescription)")

    lines.append("")
    lines.append("Command sequences tested: \(context.sequencesTested)")

    if let seed = context.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
    }

    return lines.joined(separator: "\n")
}

private func renderTimeout(
    _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
    trace: [TraceStep]
) -> String {
    var lines: [String] = []
    lines.append("Concurrent contract timed out: the drain loop stalled with no pending continuations.")
    lines.append("This typically means a command body suspended to a foreign executor (custom-executor actor, Task.sleep, or blocking I/O) that does not flow through the cooperative scheduler.")
    lines.append("")

    renderCommandPartition(tagged, into: &lines)

    if trace.isEmpty == false {
        lines.append("Partial execution trace (up to stall point):")
        for step in trace {
            lines.append("  \(step)")
        }
    }

    return lines.joined(separator: "\n")
}

private func renderCommandPartition(
    _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
    into lines: inout [String]
) {
    let prefixCommands = tagged.filter { $0.0.isPrefix }.map(\.1)
    if prefixCommands.isEmpty == false {
        lines.append("Sequential prefix:")
        for (index, command) in prefixCommands.enumerated() {
            lines.append("  \(index + 1). \(command)")
        }
        lines.append("")
    }

    let maxLane = tagged.map(\.0.rawValue).max() ?? 0
    for laneValue in UInt8(1) ... max(maxLane, 1) {
        let marker = ScheduleMarker(rawValue: laneValue)
        let laneCommands = tagged.filter { $0.0 == marker }.map(\.1)
        if laneCommands.isEmpty == false {
            let label = marker.description.uppercased()
            lines.append("Lane \(label):")
            for (index, command) in laneCommands.enumerated() {
                lines.append("  \(index + 1)\(label). \(command)")
            }
            lines.append("")
        }
    }
}
