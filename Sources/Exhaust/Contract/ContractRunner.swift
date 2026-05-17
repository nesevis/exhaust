// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

/// Runs a contract property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
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
    settings: [ContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    var commandLimit: Int?
    var budget = ExhaustBudget.thorough
    var seed: UInt64?
    var suppressIssueReporting = false
    var suppressLogs = false
    var useRandomOnly = false
    var collectOpenPBTStats = false
    var includeDiff = false
    var logLevel: LogLevel = .error
    var logFormat: LogFormat = .keyValue
    for setting in settings {
        switch setting {
        case let .commandLimit(limit):
            commandLimit = limit
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
        case .includeDiff:
            includeDiff = true
        case let .logging(level, format):
            logLevel = level
            logFormat = format
        }
    }

    #if canImport(Testing)
        if let traitConfig = ExhaustTraitConfiguration.current {
            let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
            if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                budget = traitBudget
            }
        }
    #endif

    return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
        let samplingBudget = budget.samplingBudget
        let coverageBudget = budget.coverageBudget

        let commandGen = Spec.commandGenerator
        let resolvedCommandLimit = commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            coverageBudget: coverageBudget
        )

        // Build the sequence generator: an array of commands with bounded length. Use 0 as the lower bound so the reducer can reduce sequences below the user's minimum — the minimum is a generation hint, not a reduction floor.
        let commandSequenceGenerator = commandGen.array(
            length: 0 ... resolvedCommandLimit,
            scaling: .constant
        ).gen

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
                        commandSequenceGenerator,
                        materializePicks: true,
                        seed: regressionSeed,
                        maxRuns: 1
                    )
                    if let (input, _) = try? regressionInterpreter.next() {
                        if property(input) == false {
                            let (trace, spec) = buildTrace(input, specType: specType)
                            let result = ContractResult<Spec>(
                                commands: input,
                                trace: trace,
                                systemUnderTest: spec.systemUnderTest,
                                seed: regressionSeed,
                                discoveryMethod: .replay
                            )
                            if suppressIssueReporting == false {
                                let rendered = renderFailure(
                                    result,
                                    failureInfo: ContractFailureInfo(originalCommands: nil, discoveryMethod: .replay),
                                    modelDescription: spec.modelDescription,
                                    includeDiff: includeDiff
                                )
                                reportIssue(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
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

        // --- Phase 1: Sequence Covering Array (SCA) coverage ---
        //
        // If the command generator is a simple pick with parameter-free branches, build a covering array where each sequence position is a parameter and each command type is a domain value. This guarantees every t-way ordered permutation of command types is tested.
        var scaOutcome: SCAOutcome<Spec.Command> = .skipped
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
        } else {
            scaOutcome = runSCACoverage(
                seqGen: commandSequenceGenerator,
                commandGen: commandGen.gen,
                commandLimit: resolvedCommandLimit,
                coverageBudget: coverageBudget,
                property: property,
                identifySkips: Spec.skipIdentifier
            )
        }

        // --- Phase 2: Random sampling (full budget) ---
        let failingSequence: [Spec.Command]?
        let failureInfo: ContractFailureInfo<Spec.Command>
        switch scaOutcome {
        case let .failure(commands, original):
            failingSequence = commands
            failureInfo = ContractFailureInfo(
                originalCommands: original,
                discoveryMethod: .coverage
            )
        case .completed, .skipped:
            // Only suppress generic coverage when SCA ran its covering array to completion.
            // When SCA was skipped, generic coverage is still needed.
            failingSequence = __ExhaustRuntime.__exhaust(
                commandSequenceGenerator.wrapped,
                settings: buildExhaustSettings(
                    samplingBudget: samplingBudget,
                    coverageBudget: coverageBudget,
                    seed: seed,
                    suppressIssueReporting: true,
                    useRandomOnly: useRandomOnly || scaOutcome.isCompleted,
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
            systemUnderTest: spec.systemUnderTest,
            seed: seed,
            discoveryMethod: failureInfo.discoveryMethod
        )

        if suppressIssueReporting == false {
            let rendered = renderFailure(
                result,
                failureInfo: failureInfo,
                modelDescription: spec.modelDescription,
                includeDiff: includeDiff
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

/// Formats a ``ContractResult`` and its associated failure metadata into a human-readable failure message.
func renderFailure<Spec: ContractSpecBase>(
    _ result: ContractResult<Spec>,
    failureInfo: ContractFailureInfo<Spec.Command>,
    modelDescription: String,
    includeDiff: Bool = false
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

    if includeDiff, let original = failureInfo.originalCommands, original.count > result.commands.count {
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
    lines.append("SUT:   \(result.systemUnderTest)")

    if let seed = result.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Failure metadata

/// Captures the original command sequence and the discovery method for a contract failure, used by ``renderFailure(_:failureInfo:modelDescription:)`` to build failure reports.
struct ContractFailureInfo<Command> {
    /// The original failing command sequence before reduction, if available.
    var originalCommands: [Command]?
    /// How the failure was discovered.
    var discoveryMethod: ContractDiscoveryMethod
}

// MARK: - Sequence Covering Array (SCA) coverage

/// Extracts pick choices from a command generator when the generator is a top-level ``Gen.pick``.
func extractPickChoices(
    from gen: Generator<some Any>
) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
    guard case let .impure(operation, _) = gen,
          case let .pick(choices, _) = operation
    else { return nil }
    return choices
}

/// Estimates a default command limit from the command generator's structure and the coverage budget.
///
/// Pre-analyzes pick branches to determine the per-position domain size, then computes the sequence length at which SCA rows (at t=2) would exhaust the budget. The result is the larger of this budget ceiling and an exploration floor based on the number of command types, ensuring sequences are long enough for each command to appear several times.
func estimateCommandLimit(
    commandGen: Generator<some Any>,
    coverageBudget: UInt64
) -> Int {
    guard let pickChoices = extractPickChoices(from: commandGen) else {
        return 10
    }

    let branchCount = pickChoices.count

    // Pre-analyze branch argument domains to estimate the per-position domain size.
    // Use sequenceLength=10 as initial estimate for threshold computation; the threshold is under a sqrt so it is not very sensitive to this value.
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
    // For small domains this is huge (budget is not the bottleneck); for large domains it can be < 2.
    let d = Double(min(domainSize, UInt64(Int.max)))
    let d2 = max(d * d, 1.0)
    let ratio = Double(coverageBudget) / d2
    let budgetCeiling = ratio > 1 ? Int(min(exp(ratio), 100)) : 2

    // Exploration floor: enough for each command type to appear several times, ensuring the random phase can reach meaningful state depths.
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

/// Outcome of an SCA coverage run.
enum SCAOutcome<Command> {
    /// SCA found a counterexample.
    case failure(commands: [Command], original: [Command])
    /// SCA ran its covering array to completion without finding a failure.
    case completed
    /// SCA was not applicable or was skipped before covering anything.
    case skipped

    /// Whether SCA ran to completion, covering command orderings.
    var isCompleted: Bool {
        switch self {
        case .completed: true
        case .failure, .skipped: false
        }
    }
}

/// Runs SCA coverage for contract command sequences.
///
/// Builds a covering array where each position's domain is the flattened union of `(commandType × argumentCombinations)`. Parameter-free branches contribute one domain value each; analyzed branches contribute the product of their parameter domain sizes. When any branch has analyzed arguments, interaction strength caps at t=2 to keep covering array sizes manageable; otherwise higher strengths (up to t=6 for short sequences) are used.
///
/// Returns ``SCAOutcome/skipped`` when domain construction fails or the domain is too small for pairwise coverage, so the caller can fall through to generic coverage and random sampling.
func runSCACoverage<Command>(
    seqGen: Generator<[Command]>,
    commandGen: Generator<Command>,
    commandLimit: Int,
    coverageBudget: UInt64,
    property: @escaping @Sendable ([Command]) -> Bool,
    identifySkips: @escaping @Sendable ([Command]) -> Set<Int>
) -> SCAOutcome<Command> {
    guard let pickChoices = extractPickChoices(from: commandGen) else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Command generator is not a top-level pick — SCA not applicable"
        )
        return .skipped
    }

    let sequenceLength = commandLimit
    guard sequenceLength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            metadata: [
                "sequence_length": "\(commandLimit)",
                "reason": "sequence length must be >= 2 for SCA",
            ]
        )
        return .skipped
    }

    // Cap interaction strength based on sequence length. Higher strength gives better coverage but the number of covering array rows grows with C(sequenceLength, t).
    // Short sequences can afford high strength; long sequences fall back to pairwise.
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
            event: "sca_coverage_skipped",
            "Domain construction failed — branches could not be analyzed"
        )
        return .skipped
    }

    let domainSizes = domain.profile.domainSizes
    let strength = min(domain.maxStrength, domainSizes.count, 4)
    guard strength >= 2 else {
        ExhaustLog.notice(
            category: .propertyTest,
            event: "sca_coverage_skipped",
            "Too few parameters for covering array (need >= 2)"
        )
        return .skipped
    }

    let generator = PullBasedCoveringArrayGenerator(
        domainSizes: domainSizes,
        strength: strength
    )
    let lengthRange = UInt64(0) ... UInt64(commandLimit)

    var iterations = 0
    while iterations < coverageBudget, let row = generator.next() {
        let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
        guard let tree else { continue }

        let mode = Materializer.Mode.guided(
            seed: UInt64(iterations),
            fallbackTree: nil
        )
        guard case let .success(value, freshTree, _) = Materializer.materialize(
            seqGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree
        ) else {
            continue
        }

        iterations += 1
        if property(value) == false {
            var reduceValue = value
            var reduceTree = freshTree

            let skippedIndices = identifySkips(value)
            if skippedIndices.isEmpty == false {
                ExhaustLog.notice(
                    category: .reducer,
                    event: "contract_skip_pruning",
                    metadata: [
                        "total_commands": "\(value.count)",
                        "skipped_count": "\(skippedIndices.count)",
                        "skipped_indices": "\(skippedIndices.sorted())",
                        "remaining": "\(value.count - skippedIndices.count)",
                    ]
                )
                let prunedTree = pruneSequenceElements(from: freshTree, at: skippedIndices)
                let prunedSequence = ChoiceSequence.flatten(prunedTree)
                let prunedMode = Materializer.Mode.guided(
                    seed: UInt64(iterations),
                    fallbackTree: nil
                )
                if case let .success(rematerializedValue, rematerializedTree, _) = Materializer.materialize(
                    seqGen, prefix: prunedSequence, mode: prunedMode, fallbackTree: prunedTree
                ),
                    property(rematerializedValue) == false
                {
                    reduceValue = rematerializedValue
                    reduceTree = rematerializedTree
                }
            }

            if let (_, reducedValue) = try? Interpreters.choiceGraphReduce(
                gen: seqGen,
                tree: reduceTree,
                output: reduceValue,
                config: .init(maxStalls: 2),
                property: property
            ) {
                return .failure(commands: reducedValue, original: value)
            }
            return .failure(commands: reduceValue, original: value)
        }
    }

    ExhaustLog.notice(
        category: .propertyTest,
        event: "sca_coverage",
        metadata: [
            "command_types": "\(pickChoices.count)",
            "iterations": "\(iterations)",
            "rows": "\(iterations)",
            "sequence_length": "\(sequenceLength)",
            "strength": "\(strength)",
        ]
    )

    return .completed
}

// MARK: - Skip-Aware Pruning

/// Removes elements at the given indices from the first `.sequence` node found in the tree.
func pruneSequenceElements(
    from tree: ChoiceTree,
    at indices: Set<Int>
) -> ChoiceTree {
    switch tree {
    case let .sequence(_, elements, meta):
        let pruned = elements.enumerated()
            .filter { indices.contains($0.offset) == false }
            .map(\.element)
        return .sequence(length: UInt64(pruned.count), elements: pruned, meta)
    case let .group(children, isOpaque):
        return .group(children.map { pruneSequenceElements(from: $0, at: indices) }, isOpaque: isOpaque)
    case let .resize(newSize, choices):
        return .resize(newSize: newSize, choices: choices.map { pruneSequenceElements(from: $0, at: indices) })
    default:
        return tree
    }
}

/// Builds an ``ExhaustSettings`` array from contract runner parameters, wiring budget, seed, logging, and diagnostic options.
func buildExhaustSettings(
    samplingBudget: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    suppressIssueReporting: Bool,
    useRandomOnly: Bool,
    collectOpenPBTStats: Bool = false,
    logLevel: LogLevel = .error,
    logFormat: LogFormat = .keyValue
) -> [ExhaustSettings] {
    var settings: [ExhaustSettings] = [
        .budget(.custom(
            coverage: coverageBudget,
            sampling: samplingBudget
        )),
    ]
    if let seed {
        settings.append(.replay(.numeric(seed)))
    }
    if suppressIssueReporting {
        settings.append(.suppress(.issueReporting))
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
