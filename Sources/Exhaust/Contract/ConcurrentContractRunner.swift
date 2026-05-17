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
    var commandLimit = 10
    var concurrencyLevel = 2
    var budget = ExhaustBudget.thorough
    var seed: UInt64?
    var idleTimeout = 1000
    var suppressIssueReporting = false
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
                break
            case .all:
                suppressIssueReporting = true
            }
        case let .idleTimeout(ms):
            idleTimeout = ms
        case let .logging(level, format):
            logLevel = level
            logFormat = format
        }
    }
    precondition((1 ... 8).contains(concurrencyLevel), "concurrencyLevel must be between 1 and 8")

    return ExhaustLog.withConfiguration(.init(minimumLevel: logLevel)) {
    let commandGen = Spec.commandGenerator.gen
    let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: concurrencyLevel)
    let sequenceGen = Gen.arrayOf(
        taggedCommandGen,
        within: 1 ... UInt64(commandLimit),
        scaling: .linear
    )

    let samplingBudget = budget.samplingBudget
    let reductionConfig = Interpreters.ReducerConfiguration(
        maxStalls: 2,
        wallClockDeadlineNanoseconds: UInt64(samplingBudget) * 5 * 1_000_000
    )

    // Safe: metatypes are stateless.
    nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

    let resolvedConcurrencyLevel = concurrencyLevel
    let resolvedIdleTimeout = idleTimeout
    let lastRunTimedOut = SendableBox(false)
    let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
        let result = drainSchedule(taggedCommands: taggedCommands, specInit: specInit, concurrencyLevel: resolvedConcurrencyLevel, recordTrace: false, idleTimeoutMilliseconds: resolvedIdleTimeout)
        lastRunTimedOut.value = result.timedOut
        return result.passed
    }

    var interpreter = ValueAndChoiceTreeInterpreter(
        sequenceGen,
        materializePicks: true,
        seed: seed,
        maxRuns: samplingBudget
    )
    let actualSeed = interpreter.baseSeed

    do {
        while let (input, tree) = try interpreter.next() {
            let passed = property(input)

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
                    let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                        gen: sequenceGen,
                        tree: tree,
                        output: input,
                        config: reductionConfig,
                        property: property
                    )

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
                        finalInput = input
                    }
                }

                let traceResult = drainSchedule(taggedCommands: finalInput, specInit: specInit, concurrencyLevel: concurrencyLevel, recordTrace: true, idleTimeoutMilliseconds: idleTimeout)
                let trace = traceResult.trace
                let result = ContractResult<Spec>(
                    commands: finalInput.map(\.1),
                    trace: trace,
                    systemUnderTest: Spec().systemUnderTest,
                    seed: actualSeed,
                    discoveryMethod: seed != nil ? .replay : .randomSampling
                )

                if !suppressIssueReporting {
                    let message = lastRunTimedOut.value
                        ? renderTimeout(finalInput, trace: trace)
                        : renderFailure(finalInput, trace: trace, reducedFrom: input.count)
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

    let markerGen: Generator<ScheduleMarker> = if concurrencyLevel == 1 {
        Gen.just(ScheduleMarker.prefix)
    } else {
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
            let otherLane = entry.lane == "a" ? "b" : "a"

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
                if steps[ahead].lane == otherLane {
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

private func renderFailure(
    _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
    trace: [TraceStep],
    reducedFrom originalCount: Int
) -> String {
    let reducedCount = tagged.count
    var lines: [String] = []

    if reducedCount < originalCount {
        lines.append("Reduced from \(originalCount) to \(reducedCount) commands.")
        lines.append("")
    }

    renderCommandPartition(tagged, into: &lines)

    lines.append("Execution trace:")
    for step in trace {
        lines.append("  \(step)")
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
