// Runtime execution engine for state-machine property tests.
//
// Generates command sequences, executes them against a fresh spec instance,
// and detects postcondition / invariant violations. Integrates with the
// existing coverage + random + reduction pipeline.
import ExhaustCore
import IssueReporting

/// Runs a state-machine property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized `commandGenerator`, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
///
/// - Parameters:
///   - specType: The `@StateMachine`-annotated specification type.
///   - settings: Configuration options controlling sequence length, iteration count, coverage, and shrinking.
///   - fileID: The file ID of the call site (injected by macro expansion).
///   - filePath: The file path of the call site (injected by macro expansion).
///   - line: The line number of the call site (injected by macro expansion).
///   - column: The column number of the call site (injected by macro expansion).
@discardableResult
public func __runStateMachine<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    settings: [StateMachineSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
) -> StateMachineResult<Spec>? {
    var sequenceLength: ClosedRange<Int> = 5 ... 20
    var maxIterations: UInt64 = 100
    var coverageBudget: UInt64 = 2000
    var seed: UInt64?
    var shrinkConfig: ShrinkBudget = .fast
    var suppressIssueReporting = false
    var useRandomOnly = false

    for setting in settings {
        switch setting {
        case let .sequenceLength(range):
            sequenceLength = range
        case let .maxIterations(n):
            maxIterations = n
        case let .coverageBudget(n):
            coverageBudget = n
        case let .replay(s):
            seed = s
        case let .shrinkBudget(config):
            shrinkConfig = config
        case .suppressIssueReporting:
            suppressIssueReporting = true
        case .randomOnly:
            useRandomOnly = true
        }
    }

    // Build the sequence generator: an array of commands with bounded length.
    let commandGen = Spec.commandGenerator
    let seqGen: ReflectiveGenerator<[Spec.Command]> = commandGen.array(
        length: sequenceLength,
    )

    // The property: execute the command sequence against a fresh spec and check for failures.
    let property: @Sendable ([Spec.Command]) -> Bool = { commands in
        var spec = Spec.init()
        for command in commands {
            do {
                try spec.run(command)
                try spec.checkInvariants()
            } catch is StateMachineSkip {
                continue
            } catch is StateMachineCheckFailure {
                return false
            } catch {
                return false
            }
        }
        return true
    }

    // Delegate to the standard exhaust pipeline — suppress its reporting, we handle our own.
    let failingSequence = __ExhaustRuntime.__exhaust(
        seqGen,
        settings: buildExhaustSettings(
            maxIterations: maxIterations,
            coverageBudget: coverageBudget,
            seed: seed,
            shrinkConfig: shrinkConfig,
            suppressIssueReporting: true,
            useRandomOnly: useRandomOnly,
        ),
        sourceCode: nil,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column,
        property: property,
    )

    guard let failingSequence else {
        return nil
    }

    // Re-execute the shrunk sequence to build the trace and capture SUT state.
    let (trace, spec) = buildTrace(failingSequence, specType: specType)

    let result = StateMachineResult<Spec>(
        commands: failingSequence,
        trace: trace,
        sut: spec.sut,
        seed: seed,
    )

    if !suppressIssueReporting {
        let rendered = renderFailure(result, modelDescription: spec.modelDescription)
        ExhaustLog.error(
            category: .propertyTest,
            event: "state_machine_failed",
            rendered,
        )
        reportIssue(
            rendered,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
        )
    }

    return result
}

// MARK: - Trace building

/// Re-executes the failing command sequence to build a step-by-step trace.
///
/// Returns the trace and the spec instance in the state it was in when the failure occurred
/// (or after running all commands if the sequence passes on re-execution).
private func buildTrace<Spec: StateMachineSpec>(
    _ commands: [Spec.Command],
    specType _: Spec.Type,
) -> ([TraceStep], Spec) {
    var spec = Spec.init()
    var trace: [TraceStep] = []
    trace.reserveCapacity(commands.count)

    for (index, command) in commands.enumerated() {
        let step = index + 1
        let description = "\(command)"

        do {
            try spec.run(command)
        } catch is StateMachineSkip {
            trace.append(TraceStep(index: step, command: description, outcome: .skipped))
            continue
        } catch let failure as StateMachineCheckFailure {
            trace.append(TraceStep(index: step, command: description, outcome: .checkFailed(message: failure.message)))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(index: step, command: description, outcome: .checkFailed(message: "\(error)")))
            return (trace, spec)
        }

        do {
            try spec.checkInvariants()
        } catch let failure as StateMachineCheckFailure {
            let name = failure.message ?? "unknown"
            trace.append(TraceStep(index: step, command: description, outcome: .invariantFailed(name: name)))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(index: step, command: description, outcome: .invariantFailed(name: "\(error)")))
            return (trace, spec)
        }

        trace.append(TraceStep(index: step, command: description, outcome: .ok))
    }

    return (trace, spec)
}

// MARK: - Failure rendering

private func renderFailure<Spec: StateMachineSpec>(
    _ result: StateMachineResult<Spec>,
    modelDescription: String,
) -> String {
    var lines: [String] = []
    lines.append("State machine failure")
    lines.append("")

    lines.append("Command sequence (\(result.commands.count) steps):")
    for step in result.trace {
        lines.append("  \(step)")
    }

    lines.append("")
    lines.append("Model: \(modelDescription)")
    lines.append("SUT:   \(result.sut)")

    if let seed = result.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\(seed))")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Helpers

private func buildExhaustSettings<Output>(
    maxIterations: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    shrinkConfig: ShrinkBudget,
    suppressIssueReporting: Bool,
    useRandomOnly: Bool,
) -> [ExhaustSettings<Output>] {
    var settings: [ExhaustSettings<Output>] = [
        .maxIterations(maxIterations),
        .coverageBudget(coverageBudget),
        .shrinkBudget(shrinkConfig),
    ]
    if let seed {
        settings.append(.replay(seed))
    }
    if suppressIssueReporting {
        settings.append(.suppressIssueReporting)
    }
    if useRandomOnly {
        settings.append(.randomOnly)
    }
    return settings
}
