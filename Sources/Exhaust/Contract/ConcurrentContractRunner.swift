// Generate/test/reduce loop for concurrent contract testing.
//
// Generates a flat [(UInt8, Command)] array where each command has a thread marker (1=A, 2=B).
// The array order defines the interleaving schedule. Reduction minimizes markers toward 0 (prefix),
// naturally discovering which commands must be concurrent. Fully async, no GCD.
import ExhaustCore
import IssueReporting

/// Runs a concurrent contract property test for the given async specification type.
///
/// Generates tagged command sequences and executes them through the controlled executor.
/// The interleaving is deterministic: same seed produces same result.
@discardableResult
public func __runContractConcurrent<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int = 10,
    budget: ExhaustBudget = .thorough,
    seed: UInt64? = nil,
    suppressIssueReporting: Bool = false,
    logLevel: LogLevel = .error,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    ExhaustLog.withConfiguration(.init(minimumLevel: logLevel)) {
    let commandGen = Spec.commandGenerator.gen
    let taggedCommandGen = buildTaggedCommandGenerator(from: commandGen)
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

    let property: @Sendable ([(ContractThread, Spec.Command)]) -> Bool = { taggedCommands in
        executeConcurrent(taggedCommands: taggedCommands, specInit: specInit, recordTrace: false).passed
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
                    metadata: ["commands": "\(input.count)"]
                )
                for (marker, cmd) in input {
                    ExhaustLog.debug(
                        category: .propertyTest,
                        event: "concurrent_initial_command",
                        "[\(marker.description)] \(cmd)"
                    )
                }

                let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                    gen: sequenceGen,
                    tree: tree,
                    output: input,
                    config: reductionConfig,
                    property: property
                )

                let finalInput: [(ContractThread, Spec.Command)]
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

                let traceResult = executeConcurrent(taggedCommands: finalInput, specInit: specInit, recordTrace: true)
                let trace = traceResult.trace
                let result = ContractResult<Spec>(
                    commands: finalInput.map(\.1),
                    trace: trace,
                    systemUnderTest: Spec().systemUnderTest,
                    seed: actualSeed,
                    discoveryMethod: seed != nil ? .replay : .randomSampling
                )

                if !suppressIssueReporting {
                    reportIssue(
                        renderFailure(finalInput, trace: trace, reducedFrom: input.count),
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

// MARK: - Generator construction

/// Rebuilds the command generator with a thread marker per branch.
///
/// Transforms `pick([(w, genA), (w, genB), ...])` into
/// `pick([(w, zip(threadMarker, genA)), (w, zip(threadMarker, genB)), ...])`.
/// This gives each array element a pick-at-top structure that the reducer handles naturally —
/// deletion removes entire elements, value minimization drives the thread marker toward 0.
private func buildTaggedCommandGenerator<Command>(
    from commandGen: Generator<Command>
) -> Generator<(ContractThread, Command)> {
    guard let choices = extractPickChoices(from: commandGen) else {
        fatalError("Command generator is in unexpected format")
    }

    let threadMarkerGen = Gen.choose(in: UInt8(0) ... UInt8(2))
        .map { ContractThread(rawValue: $0)! }
    let taggedChoices = choices.map { choice in
        let branchGen: Generator<Command> = choice.generator.map { $0 as! Command }
        let zipped = Gen.zip(threadMarkerGen, branchGen)
        return (weight: choice.weight, generator: zipped)
    }

    return Gen.pick(choices: taggedChoices)
}

// MARK: - Trace parsing

/// Converts raw trace markers into presentable TraceSteps with phase annotations.
///
/// Performs three post-processing passes: (1) parses colon-delimited markers into steps with
/// structured lane metadata, (2) removes suspended/resumed pairs where no interleaving actually
/// occurred between them, and (3) collapses adjacent started+completed pairs into a single entry.
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
    _ tagged: [(ContractThread, some CustomStringConvertible)],
    trace: [TraceStep],
    reducedFrom originalCount: Int
) -> String {
    let reducedCount = tagged.count
    var lines: [String] = []

    if reducedCount < originalCount {
        lines.append("Reduced from \(originalCount) to \(reducedCount) commands.")
        lines.append("")
    }

    let prefixCommands = tagged.filter { $0.0 == .prefix }.map(\.1)
    let threadACommands = tagged.filter { $0.0 == .threadA }.map(\.1)
    let threadBCommands = tagged.filter { $0.0 == .threadB }.map(\.1)

    if prefixCommands.isEmpty == false {
        lines.append("Sequential prefix:")
        for (index, command) in prefixCommands.enumerated() {
            lines.append("  \(index + 1). \(command)")
        }
        lines.append("")
    }

    if threadACommands.isEmpty == false {
        lines.append("Thread A:")
        for (index, command) in threadACommands.enumerated() {
            lines.append("  \(index + 1)A. \(command)")
        }
        lines.append("")
    }

    if threadBCommands.isEmpty == false {
        lines.append("Thread B:")
        for (index, command) in threadBCommands.enumerated() {
            lines.append("  \(index + 1)B. \(command)")
        }
        lines.append("")
    }

    lines.append("Execution trace:")
    for step in trace {
        lines.append("  \(step)")
    }

    return lines.joined(separator: "\n")
}
