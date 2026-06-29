// SCA (Sequence Covering Array) coverage phase for contract testing.
import ExhaustCore
import Foundation

// MARK: - Shared SCA Row Loop

extension __ExhaustRuntime {
    /// Raw outcome of the SCA row loop before caller-specific failure handling.
    ///
    /// Each caller (sequential, concurrent) handles the ``failure`` case differently. The sequential path prunes skipped commands and reduces directly, while the concurrent path delegates to ``reduceConcurrentCounterexample(input:tree:sequenceGen:reductionConfig:property:identifySkips:seed:skipPruningLogEvent:timedOut:)``.
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
    /// Builds covering arrays at multiple sequence lengths to cover both short and long command sequences. Budget is split across length tiers: 50% at `min + 4`, 25% at `max / 2`, 25% at `max`, with duplicate lengths collapsed and their budgets merged. Tiers run shortest-first so minimal counterexamples are found early.
    ///
    /// Returns ``SCARowLoopResult/skipped`` when domain construction fails or the domain is too small for pairwise coverage. Returns ``SCARowLoopResult/failure(value:tree:coverageInvocations:)`` with the raw (unreduced) counterexample so callers can apply their own reduction logic. The `logEventPrefix` parameterizes log event names: `"sca_coverage"` for sequential, `"concurrent_sca_coverage"` for concurrent.
    static func runSCACoverageRowLoop<Value>(
        sequenceGen: Generator<Value>,
        commandGen: Generator<some Any>,
        commandLimit: Int,
        coverageBudget: UInt64,
        skipToRow: Int?,
        logEventPrefix: String,
        concurrencyLevel: Int? = nil,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<Value>)? = nil,
        property: @escaping @Sendable (Value) -> Bool
    ) -> SCARowLoopResult<Value> {
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "\(logEventPrefix)_skipped",
                "Command generator is not a top-level pick. SCA not applicable."
            )
            return .skipped
        }

        guard commandLimit >= 2 else {
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

        let tiers = buildCoverageTiers(commandLimit: commandLimit, totalBudget: coverageBudget)

        var totalIterations = 0

        for tier in tiers {
            let domain: SCADomain
            if let concurrencyLevel {
                domain = SCADomain.buildForContract(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    concurrencyLevel: concurrencyLevel,
                    strengthCap: 2
                )
            } else {
                guard let built = SCADomain.build(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    coverageBudget: tier.budget,
                    strengthCap: 2
                ) else {
                    continue
                }
                domain = built
            }

            let domainSizes = domain.profile.domainSizes
            guard domainSizes.count >= 2 else { continue }

            let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
            var tierIterations: UInt64 = 0
            var tierAttempts: UInt64 = 0
            let maxAttempts = tier.budget * 10

            let tierLengthRange = UInt64(tier.length) ... UInt64(tier.length)
            let tierGen = sequenceGenForLength?(tierLengthRange) ?? sequenceGen

            while tierIterations < tier.budget, tierAttempts < maxAttempts, let row = generator.next() {
                tierAttempts += 1
                guard let tree = domain.buildTree(row: row, sequenceLengthRange: tierLengthRange) else {
                    continue
                }

                let mode = Materializer.Mode.guided(
                    seed: UInt64(totalIterations),
                    fallbackTree: tree
                )
                guard case let .success(value, freshTree, _) = Materializer.materialize(
                    tierGen, prefix: ChoiceSequence(), mode: mode
                ) else {
                    continue
                }

                tierIterations += 1
                totalIterations += 1
                if let skipToRow, totalIterations - 1 < skipToRow { continue }
                if property(value) == false {
                    return .failure(value: value, tree: freshTree, coverageInvocations: totalIterations)
                }
                if skipToRow != nil { return .completed(coverageInvocations: totalIterations) }
            }
        }

        ExhaustLog.notice(
            category: .propertyTest,
            event: logEventPrefix,
            metadata: [
                "command_types": "\(pickChoices.count)",
                "iterations": "\(totalIterations)",
                "command_limit": "\(commandLimit)",
                "tiers": "\(tiers.count)",
                "strength": "2",
            ]
        )

        return .completed(coverageInvocations: totalIterations)
    }

    /// Computes coverage tiers with deduplicated lengths and proportional budget allocation.
    ///
    /// Raw tiers: 50% at `min(min + 4, max)`, 25% at `max(min + 4, max / 2)`, 25% at `max`. Tiers with duplicate lengths are collapsed and their budgets merged. The minimum sequence length for any tier is 2 (pairwise coverage requires at least 2 parameters).
    private static func buildCoverageTiers(
        commandLimit: Int,
        totalBudget: UInt64
    ) -> [(length: Int, budget: UInt64)] {
        let shortLength = min(5, commandLimit)
        let rawTiers: [(length: Int, fraction: UInt64, denominator: UInt64)] = [
            (length: shortLength, fraction: 1, denominator: 2),
            (length: max(shortLength, commandLimit / 2), fraction: 1, denominator: 4),
            (length: commandLimit, fraction: 1, denominator: 4),
        ]
        let minLength = 2

        var merged: [(length: Int, fraction: UInt64, denominator: UInt64)] = []
        for raw in rawTiers {
            guard raw.length >= minLength else { continue }
            if let existingIndex = merged.firstIndex(where: { $0.length == raw.length }) {
                let existing = merged[existingIndex]
                let combinedNumerator = existing.fraction * raw.denominator + raw.fraction * existing.denominator
                let combinedDenominator = existing.denominator * raw.denominator
                merged[existingIndex] = (length: raw.length, fraction: combinedNumerator, denominator: combinedDenominator)
            } else {
                merged.append(raw)
            }
        }

        merged.sort { $0.length < $1.length }

        var result: [(length: Int, budget: UInt64)] = []
        var allocated: UInt64 = 0
        for (index, tier) in merged.enumerated() {
            let budget: UInt64
            if index == merged.count - 1 {
                budget = totalBudget - allocated
            } else {
                budget = totalBudget * tier.fraction / tier.denominator
            }
            guard budget > 0 else { continue }
            result.append((length: tier.length, budget: budget))
            allocated += budget
        }

        return result
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
                guard let targetIndex = children.firstIndex(where: { containsSequence($0) }) else {
                    return tree
                }
                var updated = children
                updated[targetIndex] = pruneSequenceElements(from: updated[targetIndex], at: indices)
                return .group(updated, isOpaque: isOpaque)
            case let .resize(newSize, choices):
                guard let targetIndex = choices.firstIndex(where: { containsSequence($0) }) else {
                    return tree
                }
                var updated = choices
                updated[targetIndex] = pruneSequenceElements(from: updated[targetIndex], at: indices)
                return .resize(newSize: newSize, choices: updated)
            default:
                return tree
        }
    }

    private static func containsSequence(_ tree: ChoiceTree) -> Bool {
        switch tree {
            case .sequence:
                return true
            case let .group(children, _):
                return children.contains(where: { containsSequence($0) })
            case let .resize(_, choices):
                return choices.contains(where: { containsSequence($0) })
            default:
                return false
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
        let prunedMode = Materializer.Mode.guided(seed: seed, fallbackTree: prunedTree)
        if case let .success(rematerialized, rematerializedTree, _) = Materializer.materialize(
            generator, prefix: prunedSequence, mode: prunedMode
        ),
            property(rematerialized) == false
        {
            if rematerialized.count == 1 {
                print("[skip-prune] degenerate: \(value.count) → \(rematerialized.count), skipped \(skippedIndices.sorted()), rematerialized: \(rematerialized)")
            }
            return (rematerialized, rematerializedTree)
        }
        return (value, tree)
    }

    /// Runs the reducer and unwraps its outcome to the reduced value, or the input unchanged when the reducer makes no improvement or fails to run.
    ///
    /// Shared by the sequential SCA failure tail and the concurrent counterexample reducer. Logging stays with each caller (they emit different events), so this is a pure reduce-and-unwrap. `reduced` is `true` only when the reducer produced a strictly simpler value.
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
        if case let .reduced(_, _, reduced) = result.outcome {
            return (reduced, result.stats, true)
        }
        return (value, result.stats, false)
    }

    /// Variant of ``reduceContractCounterexample(value:tree:generator:config:property:)`` that also returns the post-reduction choice tree for use as input to a subsequent reduction pass.
    static func reduceContractCounterexampleWithTree<Value>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        config: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable (Value) -> Bool
    ) -> (value: Value, tree: ChoiceTree, stats: ReductionStats?, reduced: Bool) {
        guard let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: value,
            config: config,
            property: property
        ) else {
            return (value, tree, nil, false)
        }
        switch result.outcome {
            case let .reduced(_, reducedTree, reduced):
                return (reduced, reducedTree, result.stats, true)
            case let .unreduced(_, unreducedTree, _):
                return (value, unreducedTree, result.stats, false)
            case .failure:
                return (value, tree, result.stats, false)
        }
    }

    /// Reduces a concurrent contract counterexample in two passes: structural (lane collapse + deletion) then value minimization.
    ///
    /// Lane collapse and deletion run together in pass 1 so the scheduler can interleave them — collapsing a lane then deleting the now-prefix command in the same cycle, rather than over-collapsing before deletion gets a chance. Pass 2 runs value and float search on the structurally reduced sequence. Each pass rematerializes on success to keep the output and tree consistent. Shared by the cooperative and preemptive backends so the reduction strategy cannot drift between them.
    ///
    /// The property closure returns a ``ContractProbeVerdict`` so the preemptive backend can carry linearizability evidence (response witnesses, failure descriptions) through reduction without a separate side-channel. The cooperative backend returns `.fail(())`.
    static func reduceConcurrentTwoPass<Command, Evidence>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        deadlineNanoseconds: UInt64,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> ContractProbeVerdict<Evidence>
    ) -> ConcurrentTwoPassResult<Command, Evidence> {
        let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
        var currentOutput = output
        var currentTree = tree
        var mergedStats = ReductionStats()
        nonisolated(unsafe) var lastEvidence: Evidence?

        let boolProperty: @Sendable ([(ScheduleMarker, Command)]) -> Bool = { commands in
            switch property(commands) {
                case .pass:
                    return true
                case let .fail(evidence):
                    lastEvidence = evidence
                    return false
            }
        }

        // Pass 1: structural reduction (lane collapse + deletion).
        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: deadlineNanoseconds,
                enabledEncoders: [.laneCollapse, .deletion],
                tuning: noRelax
            ),
            property: boolProperty
        ) {
            mergedStats.merge(result.stats)
            if case let .reduced(sequence, reducedTree, reduced) = result.outcome {
                currentOutput = reduced
                currentTree = reducedTree
                if case let .success(value, tree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact
                ) {
                    currentOutput = value
                    currentTree = tree
                }
            }
        }

        // Pass 2: value minimization on the structurally reduced sequence.
        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: deadlineNanoseconds,
                enabledEncoders: [.valueSearch, .floatSearch],
                tuning: noRelax
            ),
            property: boolProperty
        ) {
            mergedStats.merge(result.stats)
            if case let .reduced(sequence, reducedTree, reduced) = result.outcome {
                currentOutput = reduced
                currentTree = reducedTree
                if case let .success(value, tree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact
                ) {
                    currentOutput = value
                    currentTree = tree
                }
            }
        }

        return ConcurrentTwoPassResult(
            value: currentOutput,
            tree: currentTree,
            stats: mergedStats,
            lastEvidence: lastEvidence
        )
    }
}

// MARK: - Two-Pass Reduction Types

extension __ExhaustRuntime {
    enum ContractProbeVerdict<Evidence> {
        case pass
        case fail(Evidence)
    }

    struct ConcurrentTwoPassResult<Command, Evidence> {
        let value: [(ScheduleMarker, Command)]
        let tree: ChoiceTree
        let stats: ReductionStats
        let lastEvidence: Evidence?
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
