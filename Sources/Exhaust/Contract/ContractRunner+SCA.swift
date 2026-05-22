// SCA (Sequence Covering Array) coverage phase for sequential contract testing.
import ExhaustCore
import Foundation

/// Extracts pick choices from a command generator when the generator is a top-level ``Gen.pick``.
func extractPickChoices(
    from gen: Generator<some Any>
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
    case failure(commands: [Command], original: [Command], coverageInvocations: Int, reductionStats: ReductionStats?)
    /// SCA ran its covering array to completion without finding a failure.
    case completed(coverageInvocations: Int)
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

            if let result = try? Interpreters.choiceGraphReduceCollectingStats(
                gen: seqGen,
                tree: reduceTree,
                output: reduceValue,
                config: .init(maxStalls: 2),
                property: property
            ) {
                if let (_, reducedValue) = result.reduced {
                    return .failure(commands: reducedValue, original: value, coverageInvocations: iterations, reductionStats: result.stats)
                }
                return .failure(commands: reduceValue, original: value, coverageInvocations: iterations, reductionStats: result.stats)
            }
            return .failure(commands: reduceValue, original: value, coverageInvocations: iterations, reductionStats: nil)
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

    return .completed(coverageInvocations: iterations)
}

// MARK: - Skip-Aware Pruning

/// Removes elements at the given indices from `.sequence` nodes in the choice tree.
///
/// Walks the tree recursively, pruning indexed elements from the first sequence node encountered and updating its stored length. Used by the skip-pruning pass to excise commands whose preconditions were not met before handing the tree to the reducer.
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
