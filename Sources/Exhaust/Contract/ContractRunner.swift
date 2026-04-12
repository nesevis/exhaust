// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
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
    commandLimit: Int?,
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
    var collectOpenPBTStats = false
    var logLevel: LogLevel = .error
    var logFormat: LogFormat = .keyValue
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
        case .collectOpenPBTStats:
            collectOpenPBTStats = true
        case let .logging(level, format):
            logLevel = level
            logFormat = format
        }
    }
    return ExhaustLog.withConfiguration(.init(minimumLevel: logLevel, format: logFormat)) {
        let samplingBudget = budget.samplingBudget
        let coverageBudget = budget.coverageBudget

        let commandGen = Spec.commandGenerator
        let resolvedCommandLimit = commandLimit ?? estimateCommandLimit(
            commandGen: commandGen,
            coverageBudget: coverageBudget
        )

        // Build the sequence generator: an array of commands with bounded length. Use 0 as the lower bound so the reducer can reduce sequences below the user's minimum — the minimum is a generation hint, not a reduction floor.
        let seqGen = commandGen.array(
            length: 0 ... resolvedCommandLimit,
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
                commandLimit: resolvedCommandLimit,
                coverageBudget: coverageBudget,
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
                    suppressIssueReporting: true,
                    useRandomOnly: useRandomOnly || skipGenericCoverage,
                    collectOpenPBTStats: collectOpenPBTStats,
                    logLevel: logLevel,
                    logFormat: logFormat
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

        // Re-execute the reduced sequence to build the trace and capture SUT state.
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
    } // withConfiguration
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
        let reducedDescriptions = result.commands.map { "\($0)" }
        if let reductionDiff = diff(originalDescriptions, reducedDescriptions) {
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

/// Estimates a default command limit from the command generator's structure and the coverage budget.
///
/// Pre-analyzes pick branches to determine the per-position domain size, then computes the sequence length at which SCA rows (at t=2) would exhaust the budget. The result is the larger of this budget ceiling and an exploration floor based on the number of command types, ensuring sequences are long enough for each command to appear several times.
func estimateCommandLimit(
    commandGen: ReflectiveGenerator<some Any>,
    coverageBudget: UInt64
) -> Int {
    guard let pickChoices = extractPickChoices(from: commandGen) else {
        return 10
    }

    let branchCount = pickChoices.count

    // Pre-analyze branch argument domains to estimate the per-position domain size.
    // Use sequenceLength=10 as initial estimate for threshold computation;
    // the threshold is under a sqrt so it is not very sensitive to this value.
    let threshold = SequenceCoveringArray.computeThreshold(
        budget: coverageBudget,
        sequenceLength: 10,
        branchCount: branchCount
    )
    let branchProfiles = SequenceCoveringArray.analyzeBranches(
        pickChoices,
        threshold: threshold
    )
    var domainSize: UInt64 = 0
    for profile in branchProfiles {
        let contribution: UInt64 = switch profile {
        case .parameterFree, .unanalyzable:
            1
        case let .analyzed(params):
            params.reduce(UInt64(1)) { acc, param in
                let (product, overflow) = acc.multipliedReportingOverflow(by: param.domainSize)
                return overflow ? .max : product
            }
        }
        let (sum, overflow) = domainSize.addingReportingOverflow(contribution)
        domainSize = overflow ? .max : sum
    }

    // Budget ceiling: at t=2, covering array rows ≈ d² × ln(L).
    // Solving for L: L = e^(B / d²).
    // For small domains this is huge (budget is not the bottleneck);
    // for large domains it can be < 2.
    let d = Double(min(domainSize, UInt64(Int.max)))
    let d2 = max(d * d, 1.0)
    let ratio = Double(coverageBudget) / d2
    let budgetCeiling = ratio > 1 ? Int(min(exp(ratio), 1000)) : 2

    // Exploration floor: enough for each command type to appear several times,
    // ensuring the random phase can reach meaningful state depths.
    let explorationFloor = max(branchCount * 3, 6)

    let limit = max(explorationFloor, budgetCeiling)

    ExhaustLog.notice(
        category: .propertyTest,
        event: "estimated_command_limit",
        metadata: [
            "command_limit": "\(limit)",
            "command_types": "\(branchCount)",
            "domain_size": "\(domainSize)",
            "budget_ceiling": "\(budgetCeiling)",
            "exploration_floor": "\(explorationFloor)",
        ]
    )

    return limit
}

/// Runs SCA coverage for contract command sequences.
///
/// Builds a covering array where each position's domain is the flattened union of `(commandType × argumentCombinations)`. Parameter-free branches contribute one domain value each; analyzed branches contribute the product of their parameter domain sizes. When any branch has analyzed arguments, interaction strength caps at t=2 to keep covering array sizes manageable; otherwise higher strengths (up to t=6 for short sequences) are used.
///
/// If domain construction fails or the domain is too small for pairwise coverage, SCA is skipped and the caller falls through to random sampling.
/// Return type for SCA coverage: the reduced (or unreduced) failing sequence plus the original.
typealias SCAResult<Command> = (commands: [Command], original: [Command])

func runSCACoverage<Command>(
    seqGen: ReflectiveGenerator<[Command]>,
    commandGen: ReflectiveGenerator<Command>,
    commandLimit: Int,
    coverageBudget: UInt64,
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
    guard seqLen >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            metadata: [
                "sequence_length": "\(commandLimit)",
                "reason": "sequence length must be >= 2 for SCA",
            ]
        )
        return nil
    }

    // Cap interaction strength based on sequence length. Higher strength gives better
    // coverage but the number of covering array rows grows with C(seqLen, t).
    // Short sequences can afford high strength; long sequences fall back to pairwise.
    let strengthCap = switch seqLen {
    case ...6: 6
    case ...8: 5
    case ...12: 4
    case ...20: 3
    default: 2
    }

    guard let domain = SCADomain.build(
        sequenceLength: seqLen,
        pickChoices: pickChoices,
        coverageBudget: coverageBudget,
        strengthCap: strengthCap
    ) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Domain construction failed — branches could not be analyzed"
        )
        return nil
    }

    let domainSizes = domain.profile.domainSizes
    let strength = min(domain.maxStrength, domainSizes.count, 4)
    guard strength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Too few parameters for covering array (need >= 2)"
        )
        return nil
    }

    var generator = PullBasedCoveringArrayGenerator(
        domainSizes: domainSizes,
        strength: strength
    )
    defer { generator.deallocate() }

    let lengthRange = UInt64(0) ... UInt64(commandLimit)

    var iterations = 0
    while iterations < coverageBudget, let row = generator.next() {
        let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
        guard let tree else { continue }

        guard let value: [Command] = try? Interpreters.replay(seqGen, using: tree) else {
            continue
        }

        iterations += 1
        if property(value) == false {
            // Reflect to get a structurally correct tree with materialized picks,
            // since coverage-built trees lack unselected branches needed by reducer strategies.
            let reduceTree = (try? Interpreters.reflect(seqGen, with: value)) ?? tree
            // Reduce the failing sequence
            if let (_, reducedValue) = try? Interpreters.choiceGraphReduce(
                gen: seqGen,
                tree: reduceTree,
                output: value,
                config: .init(maxStalls: 2),
                property: property
            ) {
                return (reducedValue, value)
            }
            return (value, value)
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "sca_coverage",
        metadata: [
            "command_types": "\(pickChoices.count)",
            "iterations": "\(iterations)",
            "rows": "\(iterations)",
            "sequence_length": "\(seqLen)",
            "strength": "\(strength)",
        ]
    )

    return nil
}

func buildExhaustSettings<Output>(
    samplingBudget: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    suppressIssueReporting: Bool,
    useRandomOnly: Bool,
    collectOpenPBTStats: Bool = false,
    logLevel: LogLevel = .error,
    logFormat: LogFormat = .keyValue
) -> [ExhaustSettings<Output>] {
    var settings: [ExhaustSettings<Output>] = [
        .budget(.custom(
            coverage: coverageBudget,
            sampling: samplingBudget
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
    if collectOpenPBTStats {
        settings.append(.collectOpenPBTStats)
    }
    settings.append(.logging(logLevel, logFormat))
    return settings
}
