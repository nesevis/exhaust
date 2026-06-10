// SCA (Sequence Covering Array) coverage phase for contract testing.
import ExhaustCore
import Foundation

// MARK: - Shared SCA Row Loop

extension __ExhaustRuntime {
    /// Raw outcome of the SCA row loop before caller-specific failure handling.
    ///
    /// Each caller (sequential, concurrent) handles the ``failure`` case differently — the sequential path prunes skipped commands and reduces directly, while the concurrent path delegates to ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``.
    enum SCARowLoopResult<Value> {
        /// A counterexample was found at the given coverage iteration.
        case failure(value: Value, tree: ChoiceTree, coverageInvocations: Int)
        /// The covering array was exhausted without finding a failure.
        case completed(coverageInvocations: Int)
        /// SCA was not applicable (generator structure or domain too small).
        case skipped
    }

    /// Core SCA coverage row loop shared by the sequential and concurrent contract runners.
    ///
    /// Builds a covering array where each position's domain is the flattened union of `(commandType x argumentCombinations)`. Parameter-free branches contribute one domain value each; analyzed branches contribute the product of their parameter domain sizes. Interaction strength caps at t=2.
    ///
    /// Returns ``SCARowLoopResult/skipped`` when domain construction fails or the domain is too small for pairwise coverage. Returns ``SCARowLoopResult/failure(value:tree:coverageInvocations:)`` with the raw (unreduced) counterexample so callers can apply their own reduction logic. The `logEventPrefix` parameterizes log event names: `"sca_coverage"` for sequential, `"concurrent_sca_coverage"` for concurrent.
    static func runSCACoverageRowLoop<Value>(
        sequenceGen: Generator<Value>,
        commandGen: Generator<some Any>,
        commandLimit: Int,
        coverageBudget: UInt64,
        skipToRow: Int?,
        logEventPrefix: String,
        property: @escaping @Sendable (Value) -> Bool
    ) -> SCARowLoopResult<Value> {
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                "Command generator is not a top-level pick — SCA not applicable"
            )
            return .skipped
        }

        let sequenceLength = commandLimit
        guard sequenceLength >= 2 else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                metadata: [
                    "sequence_length": "\(commandLimit)",
                    "reason": "sequence length must be >= 2 for SCA",
                ]
            )
            return .skipped
        }

        guard let domain = SCADomain.build(
            sequenceLength: sequenceLength,
            pickChoices: pickChoices,
            coverageBudget: coverageBudget,
            strengthCap: 2
        ) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                "Domain construction failed — branches could not be analyzed"
            )
            return .skipped
        }

        let domainSizes = domain.profile.domainSizes
        guard domainSizes.count >= 2 else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                "Too few parameters for covering array (need >= 2)"
            )
            return .skipped
        }

        let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
        let lengthRange = UInt64(0) ... UInt64(commandLimit)

        var iterations = 0
        var attempts: UInt64 = 0
        let maxAttempts = coverageBudget * 10
        while iterations < coverageBudget, attempts < maxAttempts, let row = generator.next() {
            attempts += 1
            let tree: ChoiceTree? = domain.buildTree(row: row, sequenceLengthRange: lengthRange)
            guard let tree else { continue }

            let mode = Materializer.Mode.guided(
                seed: UInt64(iterations),
                fallbackTree: nil
            )
            guard case let .success(value, freshTree, _) = Materializer.materialize(
                sequenceGen, prefix: ChoiceSequence(), mode: mode, fallbackTree: tree
            ) else {
                continue
            }

            iterations += 1
            if let skipToRow, iterations - 1 < skipToRow { continue }
            if property(value) == false {
                return .failure(value: value, tree: freshTree, coverageInvocations: iterations)
            }
            if skipToRow != nil { break }
        }

        ExhaustLog.notice(
            category: .propertyTest,
            event: logEventPrefix,
            metadata: [
                "command_types": "\(pickChoices.count)",
                "iterations": "\(iterations)",
                "rows": "\(iterations)",
                "sequence_length": "\(sequenceLength)",
                "strength": "2",
            ]
        )

        return .completed(coverageInvocations: iterations)
    }
}

// MARK: - Sequential SCA Coverage

extension __ExhaustRuntime {
    /// Runs SCA coverage for sequential contract command sequences.
    ///
    /// Delegates to the shared ``runSCACoverageRowLoop(sequenceGen:commandGen:commandLimit:coverageBudget:skipToRow:logEventPrefix:property:)`` for the covering array iteration, then prunes skipped commands and reduces any counterexample found.
    ///
    /// Returns ``SCAOutcome/skipped`` when domain construction fails or the domain is too small for pairwise coverage, so the caller can fall through to generic coverage and random sampling.
    static func runSCACoverage<Command>(
        sequenceGen: Generator<[Command]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        skipToRow: Int? = nil,
        property: @escaping @Sendable ([Command]) -> Bool,
        identifySkips: @escaping @Sendable ([Command]) -> Set<Int>
    ) -> SCAOutcome<Command> {
        let result = runSCACoverageRowLoop(
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: commandLimit,
            coverageBudget: coverageBudget,
            skipToRow: skipToRow,
            logEventPrefix: "sca_coverage",
            property: property
        )
        switch result {
            case let .failure(value, tree, coverageInvocations):
                // Single-threaded: the reducer calls the property sequentially on the pipeline thread.
                let reductionPropertyInvocations = UnsafeSendableBox(0)
                let countingProperty: @Sendable ([Command]) -> Bool = { input in
                    reductionPropertyInvocations.value += 1
                    return property(input)
                }
                let reductionStopwatch = Stopwatch()
                let (reduceValue, reduceTree) = pruneSkippedCommands(
                    value: value,
                    tree: tree,
                    generator: sequenceGen,
                    seed: UInt64(coverageInvocations),
                    property: countingProperty,
                    identifySkips: identifySkips,
                    logEvent: "contract_skip_pruning"
                )
                let (reduced, stats, _) = reduceContractCounterexample(
                    value: reduceValue,
                    tree: reduceTree,
                    generator: sequenceGen,
                    config: .init(maxStalls: 2),
                    property: countingProperty
                )
                let reductionMilliseconds = reductionStopwatch.elapsedMilliseconds
                return .failure(
                    commands: reduced,
                    original: value,
                    coverageInvocations: coverageInvocations,
                    reductionStats: stats,
                    reductionInvocations: reductionPropertyInvocations.value,
                    reductionMilliseconds: reductionMilliseconds
                )
            case let .completed(coverageInvocations):
                return .completed(coverageInvocations: coverageInvocations)
            case .skipped:
                return .skipped
        }
    }
}

// MARK: - Skip-Aware Pruning

extension __ExhaustRuntime {
    /// Removes elements at the given indices from `.sequence` nodes in the choice tree.
    ///
    /// Walks the tree recursively, pruning indexed elements from the first sequence node encountered and updating its stored length. Used by the skip-pruning pass to excise commands whose preconditions were not met before handing the tree to the reducer.
    static func pruneSequenceElements(
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
}

extension __ExhaustRuntime {
    /// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree that still fail the property.
    ///
    /// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree, the tree is rematerialized, and the property is re-checked. If the pruned sequence still fails, the pruned value and tree are returned; otherwise the originals are returned unchanged.
    static func pruneSkippedCommands<Value: Collection>(
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
            metadata: [
                "total_commands": "\(value.count)",
                "skipped_count": "\(skippedIndices.count)",
                "skipped_indices": "\(skippedIndices.sorted())",
                "remaining": "\(value.count - skippedIndices.count)",
            ]
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

    /// Runs the reducer and unwraps its outcome to the reduced value, or the input unchanged when the reducer makes no improvement or fails to run.
    ///
    /// Shared by the sequential SCA failure tail and the concurrent counterexample reducer. Logging stays with each caller — they emit different events — so this is a pure reduce-and-unwrap. `reduced` is `true` only when the reducer produced a strictly simpler value.
    static func reduceContractCounterexample<Value>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        config: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable (Value) -> Bool
    ) -> (value: Value, stats: ReductionStats?, reduced: Bool) {
        guard let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: value,
            config: config,
            property: property
        ) else {
            return (value, nil, false)
        }
        if case let .reduced(_, reduced) = result.outcome {
            return (reduced, result.stats, true)
        }
        return (value, result.stats, false)
    }
}

extension __ExhaustRuntime {
    /// Extracts pick choices from a command generator when the generator is a top-level ``Gen.pick``.
    static func extractPickChoices(
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
    static func estimateCommandLimit(
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
            threshold: threshold,
            coverageBudget: coverageBudget
        )
        var domainSize: UInt64 = 0
        for profile in branchProfiles {
            let contribution: UInt64 = switch profile {
                case .parameterFree, .unanalyzable:
                    1
                case let .analyzed(params):
                    params.reduce(UInt64(1)) { partialProduct, param in
                        let (result, overflow) = partialProduct.multipliedReportingOverflow(by: param.domainSize)
                        return overflow ? .max : result
                    }
            }
            let (sum, overflow) = domainSize.addingReportingOverflow(contribution)
            domainSize = overflow ? .max : sum
        }

        // Budget ceiling: at t=2, covering array rows ≈ d² × ln(L).
        // Solving for L: L = e^(B / d²).
        // For small domains this is huge (budget is not the bottleneck); for large domains it can be < 2.
        let domainSizeEstimate = Double(min(domainSize, UInt64(Int.max)))
        let domainSizeSquared = max(domainSizeEstimate * domainSizeEstimate, 1.0)
        let ratio = Double(coverageBudget) / domainSizeSquared
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
}

// MARK: - SCA Outcome

extension __ExhaustRuntime {
    /// Outcome of an SCA coverage run.
    enum SCAOutcome<Command> {
        /// SCA found a counterexample.
        case failure(commands: [Command], original: [Command], coverageInvocations: Int, reductionStats: ReductionStats?, reductionInvocations: Int, reductionMilliseconds: Double)
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
}
