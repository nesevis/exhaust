// Generate/test/reduce loop for concurrent contract testing.
//
// Generates ConcurrentTestInput values (two command arrays + schedule), evaluates them
// via the ControlledExecutor drain loop, and reduces failures via ChoiceGraph. Fully async,
// no GCD.
import ExhaustCore
import IssueReporting

/// Runs a concurrent contract property test for the given async specification type.
///
/// Generates pairs of command sequences and interleaving schedules, executes them through the
/// controlled executor, and reduces any failures to minimal counterexamples. The interleaving
/// is deterministic: same seed produces same schedule produces same result.
@discardableResult
public func __runContractConcurrent<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int = 10,
    scheduleLength: Int = 40,
    budget: ExhaustBudget = .thorough,
    seed: UInt64? = nil,
    suppressIssueReporting: Bool = false,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    let commandGen = Spec.commandGenerator.gen
    let commandsAGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .linear)
    let commandsBGen = Gen.arrayOf(commandGen, within: 1 ... UInt64(commandLimit), scaling: .linear)
    let scheduleGen = Gen.arrayOf(
        Gen.choose(in: UInt8(0) ... UInt8(1)),
        within: 1 ... UInt64(scheduleLength),
        scaling: .constant
    )

    let inputGen = Gen.zip(commandsAGen, commandsBGen, scheduleGen).map { values -> ConcurrentTestInput<Spec.Command> in
        let tuple = values as! ([Spec.Command], [Spec.Command], [UInt8])
        return ConcurrentTestInput(commandsA: tuple.0, commandsB: tuple.1, schedule: tuple.2)
    }

    let samplingBudget = budget.samplingBudget
    let reductionDeadline = UInt64(samplingBudget) * 5 * 1_000_000
    let reductionConfig = Interpreters.ReducerConfiguration(
        maxStalls: 2,
        wallClockDeadlineNanoseconds: reductionDeadline
    )

    let specInit: @Sendable () -> Spec = { Spec() }

    let property: @Sendable (ConcurrentTestInput<Spec.Command>) -> Bool = { input in
        evaluateConcurrentProperty(input: input, specInit: specInit)
    }

    var interpreter = ValueAndChoiceTreeInterpreter(
        inputGen,
        materializePicks: true,
        seed: seed,
        maxRuns: samplingBudget
    )
    let actualSeed = interpreter.baseSeed

    do {
        while let (input, tree) = try interpreter.next() {
            let passed = property(input)

            if passed == false {
                let reduceResult = try Interpreters.choiceGraphReduceCollectingStats(
                    gen: inputGen,
                    tree: tree,
                    output: input,
                    config: reductionConfig,
                    property: property
                )

                let finalInput: ConcurrentTestInput<Spec.Command>
                if let (_, reduced) = reduceResult.reduced {
                    finalInput = reduced
                } else {
                    finalInput = input
                }

                let trace = buildConcurrentTrace(finalInput, specInit: specInit)

                let result = ContractResult<Spec>(
                    commands: finalInput.commandsA + finalInput.commandsB,
                    trace: trace,
                    systemUnderTest: Spec().systemUnderTest,
                    seed: actualSeed,
                    discoveryMethod: seed != nil ? .replay : .randomSampling
                )

                if !suppressIssueReporting {
                    let rendered = renderConcurrentFailure(result, input: finalInput)
                    reportIssue(
                        rendered,
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
}

// MARK: - Drain-level trace

/// The lifecycle state of a command at a drain step.
enum DrainPhase: Sendable, CustomStringConvertible {
    case started
    case suspended
    case resumed
    case completed

    var description: String {
        switch self {
        case .started: "started"
        case .suspended: "suspended"
        case .resumed: "resumed"
        case .completed: "completed"
        }
    }
}

/// One step in the drain-level execution trace.
struct DrainStep: Sendable {
    var commandIndex: Int
    var lane: LaneID
    var command: String
    var phase: DrainPhase
    var failure: String?
}

/// Result of a traced concurrent execution.
struct ConcurrentTraceResult: Sendable {
    var passed: Bool
    var drainTrace: [DrainStep]
}

/// Re-executes with trace recording at the drain level.
private func buildConcurrentTrace<Spec: AsyncContractSpec>(
    _ input: ConcurrentTestInput<Spec.Command>,
    specInit: @Sendable () -> Spec
) -> [TraceStep] {
    let result = evaluateConcurrentPropertyWithTrace(input: input, specInit: specInit)
    return result.drainTrace.enumerated().map { index, step in
        let laneLabel = step.lane == .a ? "A" : "B"
        let phaseLabel: String = switch step.phase {
        case .started: " (started)"
        case .suspended: " (suspended)"
        case .resumed: " (resumed)"
        case .completed: " (completed)"
        }
        let commandName = step.command.split(separator: "(").first.map(String.init) ?? step.command
        let description = "\(step.commandIndex)\(laneLabel) \(commandName)\(phaseLabel)"
        let outcome: TraceStep.Outcome = if let failure = step.failure {
            .invariantFailed(name: failure)
        } else {
            .ok
        }
        return TraceStep(index: index + 1, command: description, outcome: outcome)
    }
}

/// Evaluates the concurrent property with hybrid trace recording.
///
/// Tasks record `started` and `completed` entries from within their execution context (capturing
/// commands that don't suspend). The drain loop inserts `suspended` and `resumed` markers at
/// interleaving points. Since the executor is serial, all entries are in correct execution order.
private func evaluateConcurrentPropertyWithTrace<Spec: AsyncContractSpec>(
    input: ConcurrentTestInput<Spec.Command>,
    specInit: @Sendable () -> Spec
) -> ConcurrentTraceResult {
    let shared = SharedDrainState()
    let executorA = LaneExecutor(lane: .a, shared: shared)
    let executorB = LaneExecutor(lane: .b, shared: shared)
    let spec = SendableBox(specInit())
    let failed = SendableBox<String?>(nil)
    let trace = SendableBox<[DrainStep]>([])
    let commandIndexA = SendableBox(0)
    let commandIndexB = SendableBox(0)

    Task(executorPreference: executorA) { @Sendable [spec, failed, shared, trace, commandIndexA] in
        for (index, command) in input.commandsA.enumerated() {
            guard failed.value == nil else { return }
            commandIndexA.value = index + 1
            let name = "\(command)"
            trace.value.append(DrainStep(commandIndex: index + 1, lane: .a, command: name, phase: .started, failure: nil))
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .a, command: name, phase: .completed, failure: nil))
            } catch is ContractSkip {
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .a, command: name, phase: .completed, failure: nil))
                continue
            } catch let failure as ContractCheckFailure {
                let message = failure.message ?? "check failed"
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .a, command: name, phase: .completed, failure: message))
                failed.value = message
                return
            } catch {
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .a, command: name, phase: .completed, failure: "\(error)"))
                failed.value = "\(error)"
                return
            }
        }
        shared.markComplete(lane: .a)
    }

    Task(executorPreference: executorB) { @Sendable [spec, failed, shared, trace, commandIndexB] in
        for (index, command) in input.commandsB.enumerated() {
            guard failed.value == nil else { return }
            commandIndexB.value = index + 1
            let name = "\(command)"
            trace.value.append(DrainStep(commandIndex: index + 1, lane: .b, command: name, phase: .started, failure: nil))
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .b, command: name, phase: .completed, failure: nil))
            } catch is ContractSkip {
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .b, command: name, phase: .completed, failure: nil))
                continue
            } catch let failure as ContractCheckFailure {
                let message = failure.message ?? "check failed"
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .b, command: name, phase: .completed, failure: message))
                failed.value = message
                return
            } catch {
                trace.value.append(DrainStep(commandIndex: index + 1, lane: .b, command: name, phase: .completed, failure: "\(error)"))
                failed.value = "\(error)"
                return
            }
        }
        shared.markComplete(lane: .b)
    }

    // Drain loop: execute jobs and insert suspended/resumed markers only at lane switches.
    // Continuations on the same lane (e.g., checkInvariants after run) don't produce markers
    // because no interleaving occurred — the user's command wasn't interrupted.
    var lastDrainedLane: LaneID?
    var laneHasOpenCommand: [LaneID: Bool] = [.a: false, .b: false]
    var scheduleIndex = 0
    var failureDetected = false

    while shared.isFinished == false {
        guard shared.hasPendingJobs else { break }
        let preferred: LaneID = if scheduleIndex < input.schedule.count {
            input.schedule[scheduleIndex] == 0 ? .a : .b
        } else {
            scheduleIndex % 2 == 0 ? .a : .b
        }
        scheduleIndex += 1
        guard let (lane, job) = shared.takeJob(preferring: preferred) else { break }
        let executor = lane == .a ? executorA : executorB

        let switchedLanes = lastDrainedLane != nil && lastDrainedLane != lane

        if switchedLanes, let previousLane = lastDrainedLane, laneHasOpenCommand[previousLane] == true {
            let commandIndex = previousLane == .a ? commandIndexA.value : commandIndexB.value
            let commandName = trace.value.last(where: { $0.lane == previousLane })?.command ?? ""
            trace.value.append(DrainStep(commandIndex: commandIndex, lane: previousLane, command: commandName, phase: .suspended, failure: nil))
        }

        if switchedLanes && laneHasOpenCommand[lane] == true {
            let commandIndex = lane == .a ? commandIndexA.value : commandIndexB.value
            let commandName = trace.value.last(where: { $0.lane == lane })?.command ?? ""
            trace.value.append(DrainStep(commandIndex: commandIndex, lane: lane, command: commandName, phase: .resumed, failure: nil))
        }

        job.runSynchronously(on: executor.asUnownedTaskExecutor())

        laneHasOpenCommand[lane] = shared.hasPendingJob(for: lane)
        lastDrainedLane = lane

        if failed.value != nil {
            if failureDetected { break }
            failureDetected = true
        }
    }

    // Post-process: each command's final appearance is completed, not resumed/suspended.
    var finalTrace = trace.value
    var lastIndexForCommand: [String: Int] = [:]
    for (index, step) in finalTrace.enumerated() {
        let key = "\(step.commandIndex)\(step.lane == .a ? "A" : "B")"
        lastIndexForCommand[key] = index
    }
    for index in lastIndexForCommand.values where finalTrace[index].phase != .started {
        finalTrace[index].phase = .completed
    }

    return ConcurrentTraceResult(passed: failed.value == nil, drainTrace: finalTrace)
}

// MARK: - Failure rendering

private func renderConcurrentFailure<Spec: AsyncContractSpec>(
    _ result: ContractResult<Spec>,
    input: ConcurrentTestInput<Spec.Command>
) -> String {
    var lines: [String] = []
    lines.append("Concurrent contract failure in \(Spec.self)")
    lines.append("")
    lines.append("Thread A:")
    for (index, command) in input.commandsA.enumerated() {
        lines.append("  \(index + 1)A. \(truncatedCommand("\(command)"))")
    }
    lines.append("")
    lines.append("Thread B:")
    for (index, command) in input.commandsB.enumerated() {
        lines.append("  \(index + 1)B. \(truncatedCommand("\(command)"))")
    }
    lines.append("")
    lines.append("Execution trace:")
    for step in result.trace {
        lines.append("  \(step)")
    }
    if let seed = result.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\(seed))")
    }
    return lines.joined(separator: "\n")
}

private func truncatedCommand(_ command: String) -> String {
    guard command.count > 15 else { return command }
    return String(command.prefix(15)) + "\u{2026}"
}
