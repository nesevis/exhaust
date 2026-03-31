// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import IssueReporting

/// Runs a contract property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized `commandGenerator`, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
///
/// - Parameters:
///   - specType: The `@Contract`-annotated specification type.
///   - commandLimit: The maximum number of commands per generated sequence.
///   - settings: Configuration options controlling iteration count, coverage, and reduction.
///   - fileID: The file ID of the call site (injected by macro expansion).
///   - filePath: The file path of the call site (injected by macro expansion).
///   - line: The line number of the call site (injected by macro expansion).
///   - column: The column number of the call site (injected by macro expansion).
@discardableResult
public func __runContract<Spec: ContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int,
    settings: [ContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    var budget = ExhaustBudget.expensive
    var seed: UInt64?
    var suppressIssueReporting = false
    var useRandomOnly = false
    var useArgumentAwareCoverage = false
    for setting in settings {
        switch setting {
        case let .budget(b):
            budget = b
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
        case .suppressIssueReporting:
            suppressIssueReporting = true
        case .randomOnly:
            useRandomOnly = true
        case .argumentAwareCoverage:
            useArgumentAwareCoverage = true
        }
    }
    let samplingBudget = budget.samplingBudget
    let coverageBudget = budget.coverageBudget
    let reductionConfig = budget.reducerBudget

    // Build the sequence generator: an array of commands with bounded length. Use 0 as the lower bound so the reducer can shrink sequences below the user's minimum — the minimum is a generation hint, not a shrinking floor.
    let commandGen = Spec.commandGenerator
    let seqGen: ReflectiveGenerator<[Spec.Command]> = commandGen.array(
        length: 0 ... commandLimit,
        scaling: .constant
    )

    // The property: execute the command sequence against a fresh spec and check for failures.
    let property: @Sendable ([Spec.Command]) -> Bool = { commands in
        var spec = Spec()
        for command in commands {
            do {
                try spec.run(command)
                try spec.checkInvariants()
            } catch is ContractSkip {
                continue
            } catch is ContractCheckFailure {
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
    var scaResult: SCAResult<Spec.Command>?
    if useRandomOnly {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "SCA coverage skipped (randomOnly mode)"
        )
    } else if seed != nil {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "SCA coverage skipped (deterministic replay)"
        )
    }
    if !useRandomOnly, seed == nil {
        scaResult = runSCACoverage(
            seqGen: seqGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            coverageBudget: coverageBudget,
            reductionConfig: reductionConfig,
            argumentAware: useArgumentAwareCoverage,
            property: property
        )
    }

    // --- Phase 2: Random sampling (full budget) ---
    let failingSequence: [Spec.Command]?
    let failureInfo: ContractFailureInfo<Spec.Command>
    if let scaResult {
        failingSequence = scaResult.commands
        failureInfo = ContractFailureInfo(
            originalCommands: scaResult.original,
            discoveryMethod: .coverage
        )
    } else {
        // Skip generic coverage — SCA already covered command orderings.
        // If SCA wasn't applicable, __exhaust's generic coverage runs.
        let skipGenericCoverage =
            !useRandomOnly && seed == nil
                && extractPickChoices(from: commandGen) != nil
        failingSequence = __ExhaustRuntime.__exhaust(
            seqGen,
            settings: buildExhaustSettings(
                samplingBudget: samplingBudget,
                coverageBudget: coverageBudget,
                seed: seed,
                reductionConfig: reductionConfig,
                suppressIssueReporting: true,
                useRandomOnly: useRandomOnly || skipGenericCoverage
            ),
            sourceCode: nil,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            property: property
        )
        failureInfo = ContractFailureInfo(
            originalCommands: nil,
            discoveryMethod: seed != nil ? .replay : .randomSampling
        )
    }

    guard let failingSequence else {
        return nil
    }

    // Re-execute the shrunk sequence to build the trace and capture SUT state.
    let (trace, spec) = buildTrace(failingSequence, specType: specType)

    let result = ContractResult<Spec>(
        commands: failingSequence,
        trace: trace,
        sut: spec.sut,
        seed: seed,
        discoveryMethod: failureInfo.discoveryMethod
    )

    if !suppressIssueReporting {
        let rendered = renderFailure(
            result,
            failureInfo: failureInfo,
            modelDescription: spec.modelDescription
        )
        ExhaustLog.error(
            category: .propertyTest,
            event: "contract_failed",
            rendered
        )
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

// MARK: - Trace building

/// Re-executes the failing command sequence to build a step-by-step trace.
///
/// Returns the trace and the spec instance in the state it was in when the failure occurred (or after running all commands if the sequence passes on re-execution).
private func buildTrace<Spec: ContractSpec>(
    _ commands: [Spec.Command],
    specType _: Spec.Type
) -> ([TraceStep], Spec) {
    var spec = Spec()
    var trace: [TraceStep] = []
    trace.reserveCapacity(commands.count)

    for (index, command) in commands.enumerated() {
        let step = index + 1
        let description = "\(command)"

        do {
            try spec.run(command)
        } catch is ContractSkip {
            trace.append(TraceStep(index: step, command: description, outcome: .skipped))
            continue
        } catch let failure as ContractCheckFailure {
            trace.append(TraceStep(
                index: step,
                command: description,
                outcome: .checkFailed(message: failure.message)
            ))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(
                index: step,
                command: description,
                outcome: .checkFailed(message: "\(error)")
            ))
            return (trace, spec)
        }

        do {
            try spec.checkInvariants()
        } catch let failure as ContractCheckFailure {
            let name = failure.message ?? "unknown"
            trace.append(TraceStep(
                index: step,
                command: description,
                outcome: .invariantFailed(name: name)
            ))
            return (trace, spec)
        } catch {
            trace.append(TraceStep(
                index: step,
                command: description,
                outcome: .invariantFailed(name: "\(error)")
            ))
            return (trace, spec)
        }

        trace.append(TraceStep(index: step, command: description, outcome: .ok))
    }

    return (trace, spec)
}

// MARK: - Failure rendering

func renderFailure<Spec: ContractSpecBase>(
    _ result: ContractResult<Spec>,
    failureInfo: ContractFailureInfo<Spec.Command>,
    modelDescription: String
) -> String {
    var lines: [String] = []
    lines.append("Contract failure (found via \(failureInfo.discoveryMethod))")
    lines.append("")

    // Show sequence header with reduction info when available.
    if let original = failureInfo.originalCommands, original.count > result.commands.count {
        let header =
            "Command sequence (\(result.commands.count) steps, reduced from \(original.count)):"
        lines.append(header)
    } else {
        lines.append("Command sequence (\(result.commands.count) steps):")
    }

    for step in result.trace {
        lines.append("  \(step)")
    }

    // Show reduction diff when the original sequence is available and differs.
    if let original = failureInfo.originalCommands, original.count > result.commands.count {
        let originalDescriptions = original.map { "\($0)" }
        let shrunkDescriptions = result.commands.map { "\($0)" }
        if let reductionDiff = diff(originalDescriptions, shrunkDescriptions) {
            lines.append("")
            lines.append("Reduction diff:")
            for line in reductionDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("  \(line)")
            }
        }
    }

    lines.append("")
    lines.append("Model: \(modelDescription)")
    lines.append("SUT:   \(result.sut)")

    if let seed = result.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Failure metadata

/// Metadata about how a failing contract sequence was found, for reporting.
struct ContractFailureInfo<Command> {
    /// The original failing command sequence before reduction, if available.
    var originalCommands: [Command]?
    /// How the failure was discovered.
    var discoveryMethod: ContractDiscoveryMethod
}

// MARK: - Sequence Covering Array (SCA) coverage

/// Extracts pick choices from a command generator if it's a top-level `Gen.pick`.
func extractPickChoices(
    from gen: ReflectiveGenerator<some Any>
) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
    guard case let .impure(operation, _) = gen,
          case let .pick(choices) = operation
    else { return nil }
    return choices
}

/// Runs SCA coverage for contract command sequences.
///
/// By default, builds a covering array over command-type orderings only, keeping domains small enough for higher interaction strengths (t=3, t=4). When `argumentAware` is true, each position's domain is the flattened union of `(commandType × argumentCombinations)`, giving pairwise coverage of argument value interactions at the cost of capping at t=2.
///
/// If `bestFitting` rejects the domain as too large, SCA is skipped and the caller falls through to random sampling.
/// Return type for SCA coverage: the shrunk (or unshrunk) failing sequence plus the original.
typealias SCAResult<Command> = (commands: [Command], original: [Command])

func runSCACoverage<Command>(
    seqGen: ReflectiveGenerator<[Command]>,
    commandGen: ReflectiveGenerator<Command>,
    commandLimit: Int,
    coverageBudget: UInt64,
    reductionConfig: ReducerBudget,
    argumentAware: Bool,
    property: @escaping @Sendable ([Command]) -> Bool
) -> SCAResult<Command>? {
    guard let pickChoices = extractPickChoices(from: commandGen) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Command generator is not a top-level pick — SCA not applicable"
        )
        return nil
    }

    let seqLen = commandLimit
    guard seqLen >= 2, pickChoices.count >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            metadata: [
                "sequence_length": "\(commandLimit)",
                "command_types": "\(pickChoices.count)",
                "reason": "too few positions or command types for SCA (need >= 2 of each)",
            ]
        )
        return nil
    }

    // Cap interaction strength so IPOG stays under ~100ms for any sequence length.
    // IPOG's vertical growth enumerates C(seqLen, t) parameter combinations, which
    // explodes at high t: C(20, 6) = 38,760 vs C(20, 3) = 1,140.
    //
    // Measured on M4 with 2 command types (BuggyCounterSpec):
    //   seqLen  5 @ t≤6:  2ms    seqLen 15 @ t≤3: 35ms
    //   seqLen  8 @ t≤5: 31ms    seqLen 20 @ t≤3: 94ms
    //   seqLen 10 @ t≤4: 40ms    seqLen 30 @ t≤2: 18ms
    let strengthCap = switch seqLen {
    case ...6: 6
    case ...8: 5
    case ...12: 4
    case ...20: 3
    default: 2
    }

    let builder: any SCADomainBuilder = argumentAware
        ? ArgumentAwareSCABuilder()
        : CommandTypeSCABuilder()

    guard let domain = builder.buildDomain(
        sequenceLength: seqLen,
        pickChoices: pickChoices,
        coverageBudget: coverageBudget,
        strengthCap: strengthCap
    ) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Domain construction failed — branches may have parameterized sub-generators without argumentAwareCoverage"
        )
        return nil
    }

    guard let covering = CoveringArray.bestFitting(
        budget: coverageBudget,
        profile: domain.profile,
        maxStrength: domain.maxStrength
    ) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            metadata: [
                "reason": "covering array exceeds budget",
                "budget": "\(coverageBudget)",
                "command_types": "\(pickChoices.count)",
                "sequence_length": "\(seqLen)",
            ]
        )
        return nil
    }

    let lengthRange = UInt64(0) ... UInt64(commandLimit)

    var iterations = 0
    for row in covering.rows {
        let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
        guard let tree else { continue }

        guard let value: [Command] = try? Interpreters.replay(seqGen, using: tree) else {
            continue
        }

        iterations += 1
        if property(value) == false {
            // Reflect to get a structurally correct tree with materialized picks,
            // since coverage-built trees lack unselected branches needed by reducer strategies.
            let shrinkTree = (try? Interpreters.reflect(seqGen, with: value)) ?? tree
            // Reduce the failing sequence
            if let (_, shrunkValue) = try? Interpreters.bonsaiReduce(
                gen: seqGen,
                tree: shrinkTree,
                output: value,
                config: .init(from: reductionConfig),
                property: property
            ) {
                return (shrunkValue, value)
            }
            return (value, value)
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "sca_coverage",
        metadata: [
            "strength": "\(covering.strength)",
            "rows": "\(covering.rows.count)",
            "iterations": "\(iterations)",
            "sequence_length": "\(seqLen)",
            "command_types": "\(pickChoices.count)",
        ]
    )

    return nil
}

func buildExhaustSettings<Output>(
    samplingBudget: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    reductionConfig: ReducerBudget,
    suppressIssueReporting: Bool,
    useRandomOnly: Bool
) -> [ExhaustSettings<Output>] {
    var settings: [ExhaustSettings<Output>] = [
        .budget(.custom(
            coverage: coverageBudget,
            sampling: samplingBudget,
            reduction: reductionConfig
        )),
    ]
    if let seed {
        settings.append(.replay(.numeric(seed)))
    }
    if suppressIssueReporting {
        settings.append(.suppressIssueReporting)
    }
    if useRandomOnly {
        settings.append(.randomOnly)
    }
    return settings
}
