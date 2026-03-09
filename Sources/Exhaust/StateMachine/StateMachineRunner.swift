// Runtime execution engine for state-machine property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import ExhaustCore
import IssueReporting

/// Runs a state-machine property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized `commandGenerator`, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
///
/// - Parameters:
///   - specType: The `@StateMachine`-annotated specification type.
///   - settings: Configuration options controlling sequence length, iteration count, coverage, and reduction.
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
    var reductionConfig: TCRBudget = .fast
    var suppressIssueReporting = false
    var useRandomOnly = false
    var useArgumentAwareCoverage = false

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
        case let .reductionBudget(config):
            reductionConfig = config
        case .suppressIssueReporting:
            suppressIssueReporting = true
        case .randomOnly:
            useRandomOnly = true
        case .argumentAwareCoverage:
            useArgumentAwareCoverage = true
        }
    }

    // Build the sequence generator: an array of commands with bounded length. Use 0 as the lower bound so the reducer can shrink sequences below the user's minimum — the minimum is a generation hint, not a shrinking floor.
    let commandGen = Spec.commandGenerator
    let seqGen: ReflectiveGenerator<[Spec.Command]> = commandGen.array(
        length: 0 ... sequenceLength.upperBound,
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

    // --- Phase 1: Sequence Covering Array (SCA) coverage ---
    //
    // If the command generator is a simple pick with parameter-free branches, build a covering array where each sequence position is a parameter and each command type is a domain value. This guarantees every t-way ordered permutation of command types is tested.
    var scaFoundFailure: [Spec.Command]?
    if !useRandomOnly, seed == nil {
        scaFoundFailure = runSCACoverage(
            seqGen: seqGen,
            commandGen: commandGen,
            sequenceLength: sequenceLength,
            coverageBudget: coverageBudget,
            reductionConfig: reductionConfig,
            argumentAware: useArgumentAwareCoverage,
            property: property,
        )
    }

    // --- Phase 2: Random sampling (full budget) ---
    let failingSequence: [Spec.Command]?
    if let scaFoundFailure {
        failingSequence = scaFoundFailure
    } else {
        // Skip generic coverage — SCA already covered command orderings.
        // If SCA wasn't applicable, __exhaust's generic coverage runs.
        let skipGenericCoverage = !useRandomOnly && seed == nil && extractPickChoices(from: commandGen) != nil
        failingSequence = __ExhaustRuntime.__exhaust(
            seqGen,
            settings: buildExhaustSettings(
                maxIterations: maxIterations,
                coverageBudget: coverageBudget,
                seed: seed,
                reductionConfig: reductionConfig,
                suppressIssueReporting: true,
                useRandomOnly: useRandomOnly || skipGenericCoverage,
            ),
            sourceCode: nil,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            property: property,
        )
    }

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
/// Returns the trace and the spec instance in the state it was in when the failure occurred (or after running all commands if the sequence passes on re-execution).
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

// MARK: - Sequence Covering Array (SCA) coverage

/// Extracts pick choices from a command generator if it's a top-level `Gen.pick`.
private func extractPickChoices<Command>(
    from gen: ReflectiveGenerator<Command>,
) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
    guard case let .impure(operation, _) = gen,
          case let .pick(choices) = operation
    else { return nil }
    return choices
}

/// Runs SCA coverage for state-machine command sequences.
///
/// By default, builds a covering array over command-type orderings only, keeping domains small enough for higher interaction strengths (t=3, t=4). When `argumentAware` is true, each position's domain is the flattened union of `(commandType × argumentCombinations)`, giving pairwise coverage of argument value interactions at the cost of capping at t=2.
///
/// If `bestFitting` rejects the domain as too large, SCA is skipped and the caller falls through to random sampling.
private func runSCACoverage<Command>(
    seqGen: ReflectiveGenerator<[Command]>,
    commandGen: ReflectiveGenerator<Command>,
    sequenceLength: ClosedRange<Int>,
    coverageBudget: UInt64,
    reductionConfig: TCRBudget,
    argumentAware: Bool,
    property: @escaping @Sendable ([Command]) -> Bool,
) -> [Command]? {
    guard let pickChoices = extractPickChoices(from: commandGen) else { return nil }

    let seqLen = sequenceLength.upperBound
    guard seqLen >= 2, pickChoices.count >= 2 else { return nil }

    let profile: FiniteDomainProfile
    let mapping: SCADomainMapping?
    let maxStrength: Int

    if argumentAware {
        let threshold = SequenceCoveringArray.computeThreshold(
            budget: coverageBudget, sequenceLength: seqLen, branchCount: pickChoices.count,
        )
        let branchProfiles = SequenceCoveringArray.analyzeBranches(pickChoices, threshold: threshold)
        let (p, m) = SequenceCoveringArray.buildProfile(
            sequenceLength: seqLen,
            pickChoices: pickChoices,
            branchProfiles: branchProfiles,
        )
        profile = p
        mapping = m
        // Cap at t=2 for argument-aware domains to avoid combinatorially expensive IPOG runs.
        let hasArgumentDomains = branchProfiles.contains { if case .analyzed = $0 { return true }; return false }
        maxStrength = hasArgumentDomains ? 2 : 6
    } else {
        // Command-type-only SCA produces .just("") sub-trees that can't replay parameterized branches.
        guard SequenceCoveringArray.allBranchesParameterFree(pickChoices) else { return nil }
        profile = SequenceCoveringArray.buildProfile(
            sequenceLength: seqLen, pickChoices: pickChoices,
        )
        mapping = nil
        maxStrength = 6
    }

    guard let covering = CoveringArray.bestFitting(budget: coverageBudget, profile: profile, maxStrength: maxStrength) else {
        return nil
    }

    let lengthRange = UInt64(0) ... UInt64(sequenceLength.upperBound)

    for row in covering.rows {
        let tree: ChoiceTree?
        if let mapping {
            tree = SequenceCoveringArray.buildTree(
                row: row,
                profile: profile,
                mapping: mapping,
                sequenceLengthRange: lengthRange,
            )
        } else {
            tree = SequenceCoveringArray.buildTree(
                row: row,
                profile: profile,
                sequenceLengthRange: lengthRange,
            )
        }
        guard let tree else { continue }

        guard let value: [Command] = try? Interpreters.replay(seqGen, using: tree) else {
            continue
        }

        if property(value) == false {
            // Reduce the failing sequence
            if let (_, shrunkValue) = try? Interpreters.reduce(
                gen: seqGen,
                tree: tree,
                config: reductionConfig,
                property: property,
            ) {
                return shrunkValue
            }
            return value
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "sca_coverage",
        metadata: [
            "strength": "\(covering.strength)",
            "rows": "\(covering.rows.count)",
            "sequence_length": "\(seqLen)",
            "command_types": "\(pickChoices.count)",
        ],
    )

    return nil
}

private func buildExhaustSettings<Output>(
    maxIterations: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    reductionConfig: TCRBudget,
    suppressIssueReporting: Bool,
    useRandomOnly: Bool,
) -> [ExhaustSettings<Output>] {
    var settings: [ExhaustSettings<Output>] = [
        .maxIterations(maxIterations),
        .coverageBudget(coverageBudget),
        .reductionBudget(reductionConfig),
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
