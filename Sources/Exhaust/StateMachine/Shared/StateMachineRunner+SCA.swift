// SCA (Sequence Covering Array) screening phase for spec testing.
import ExhaustCore
import Foundation

// MARK: - Shared SCA Row Loop

extension __ExhaustRuntime {
    /// Reports the raw outcome of the SCA row loop before caller-specific failure handling.
    ///
    /// Each caller handles the ``failure`` case differently. The sequential path prunes skipped commands and reduces directly, while the concurrent source wraps the value in a ``StateMachineCandidate`` for the machine to reduce.
    enum SCARowLoopResult<Value> {
        /// A counterexample was found at the given screening iteration.
        case failure(value: Value, tree: ChoiceTree, screeningInvocations: Int)
        /// The covering array was exhausted without finding a failure.
        case completed(screeningInvocations: Int)
        /// SCA was not applicable (generator structure or domain too small).
        case skipped
    }

    /// Core SCA screening row loop shared by the sequential and concurrent spec runners.
    ///
    /// Builds covering arrays at multiple sequence lengths to cover both short and long command sequences. Budget is split across length tiers: 50% at `min(5, commandLimit)`, 25% at `max(5, commandLimit / 2)`, 25% at `commandLimit`, with duplicate lengths collapsed and their budgets merged. Tiers run shortest-first so minimal counterexamples are found early.
    ///
    /// Returns ``SCARowLoopResult/skipped`` when domain construction fails or the domain is too small for pairwise coverage. Returns ``SCARowLoopResult/failure(value:tree:screeningInvocations:)`` with the raw (unreduced) counterexample so callers can apply their own reduction logic. The `logEventPrefix` parameterizes log event names: `"statemachine_screening"` for a fresh run, `"statemachine_screening_replay"` for row replay.
    static func runSCAScreeningRowLoop<Value>(
        sequenceGen: Generator<Value>,
        commandGen: Generator<some Any>,
        commandLimit: Int,
        screeningBudget: UInt64,
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

        let tiers = buildScreeningTiers(commandLimit: commandLimit, totalBudget: screeningBudget)

        var totalIterations = 0

        for tier in tiers {
            let domain: SCADomain
            if let concurrencyLevel {
                domain = SCADomain.buildForStateMachine(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    concurrencyLevel: concurrencyLevel,
                    strengthCap: 2
                )
            } else {
                guard let built = SCADomain.build(
                    sequenceLength: tier.length,
                    pickChoices: pickChoices,
                    screeningBudget: tier.budget,
                    strengthCap: 2
                ) else {
                    continue
                }
                domain = built
            }

            let domainSizes = domain.profile.domainSizes
            guard domainSizes.count >= 2 else {
                continue
            }

            let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
            var tierIterations: UInt64 = 0
            var tierAttempts: UInt64 = 0
            // A replay must land on the exact row discovery found. The global row index depends on how many rows each tier contributes, and the fractional `tier.budget` split makes that budget-dependent — so a replay under a smaller budget would cut a tier short and shift the target row into a different combination. A replay only needs to *reach* `skipToRow` (earlier rows are skipped without running the property), so cap each tier at `skipToRow + 1` instead: every tier then runs to its covering-array completion up to the target, matching the discovery run's row numbering regardless of the replay budget.
            let tierRowCap = skipToRow.map { UInt64($0) + 1 } ?? tier.budget
            let maxAttempts = tierRowCap * 10

            let tierLengthRange = UInt64(tier.length) ... UInt64(tier.length)
            let tierGen = sequenceGenForLength?(tierLengthRange) ?? sequenceGen

            while tierIterations < tierRowCap, tierAttempts < maxAttempts, let row = generator.next() {
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
                if let skipToRow, totalIterations - 1 < skipToRow {
                    continue
                }
                if property(value) == false {
                    return .failure(value: value, tree: freshTree, screeningInvocations: totalIterations)
                }
                if skipToRow != nil {
                    return .completed(screeningInvocations: totalIterations)
                }
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

        return .completed(screeningInvocations: totalIterations)
    }

    /// Computes screening tiers with deduplicated lengths and proportional budget allocation.
    ///
    /// Raw tiers: 50% at `min(5, commandLimit)`, 25% at `max(5, commandLimit / 2)`, 25% at `commandLimit`. Tiers with duplicate lengths are collapsed and their budgets merged. The minimum sequence length for any tier is 2 (pairwise coverage requires at least 2 parameters).
    private static func buildScreeningTiers(
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
            guard raw.length >= minLength else {
                continue
            }
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
            guard budget > 0 else {
                continue
            }
            result.append((length: tier.length, budget: budget))
            allocated += budget
        }

        return result
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
    /// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree.
    ///
    /// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree and the tree is rematerialized. When `requireFailurePreserved` is `true`, the rematerialized value is returned only if it still fails the property; otherwise the originals are returned unchanged. When `false`, the rematerialized value is returned whenever materialization succeeds, without re-checking the property.
    ///
    /// - Parameter requireFailurePreserved: Whether to re-check that the pruned sequence still fails the property before returning it. The counterexample-reduction callers keep this `true`. The `#execute(time:)` prune hook passes `false` because it normalizes every admitted candidate rather than only counterexamples, and skip pruning is pure element deletion into a fully populated tree, so a failing candidate keeps failing.
    static func pruneSkippedCommands<Value: Collection>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        seed: UInt64,
        property: @Sendable (Value) -> Bool,
        identifySkips: (Value) -> Set<Int>,
        requireFailurePreserved: Bool = true,
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
        ) {
            if requireFailurePreserved == false || property(rematerialized) == false {
                return (rematerialized, rematerializedTree)
            }
        }
        return (value, tree)
    }

    /// Runs the reducer and unwraps its outcome to the reduced value, or the input unchanged when the reducer makes no improvement or fails to run.
    ///
    /// Shared by the sequential SCA failure tail and the concurrent counterexample reducer. Logging stays with each caller (they emit different events), so this is a pure reduce-and-unwrap. `reduced` is `true` only when the reducer produced a strictly simpler value.
    static func reduceStateMachineCounterexample<Value>(
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

    /// Reduces a concurrent spec counterexample in two passes: structural (lane collapse + deletion) then value minimization.
    ///
    /// Lane collapse and deletion run together in pass 1 so the scheduler can interleave them — collapsing a lane then deleting the now-prefix command in the same cycle, rather than over-collapsing before deletion gets a chance. Pass 2 runs value and float search on the structurally reduced sequence. Each pass rematerializes on success to keep the output and tree consistent. Shared by the cooperative and preemptive backends so the reduction strategy cannot drift between them.
    ///
    /// The property closure returns a ``StateMachineProbeVerdict`` so the preemptive backend can carry linearizability evidence (response witnesses, failure descriptions) through reduction without a separate side-channel. The cooperative backend returns `.fail(())`. A `.abort` verdict (a probe timed out, so further probing would reduce toward a hang) stops reduction: remaining probes in the current pass are treated as passing and the second pass is skipped, leaving the counterexample as-is.
    static func reduceConcurrentTwoPass<Command, Evidence>(
        generator: Generator<[(ScheduleMarker, Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Command)],
        deadlineNanoseconds: UInt64,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> StateMachineProbeVerdict<Evidence>
    ) -> ConcurrentTwoPassResult<Command, Evidence> {
        let noRelax = SchedulerTuning(relaxMaterializationBudget: 0)
        var currentOutput = output
        var currentTree = tree
        var mergedStats = ReductionStats()
        nonisolated(unsafe) var lastEvidence: Evidence?
        nonisolated(unsafe) var aborted = false

        // The underlying graph reducer has no abort channel, so an abort is latched here: remaining probes in the in-flight pass report passing (rejecting every candidate) without reaching the backend's property, and the next pass is skipped.
        let boolProperty: @Sendable ([(ScheduleMarker, Command)]) -> Bool = { commands in
            guard aborted == false else {
                return true
            }
            switch property(commands) {
                case .pass:
                    return true
                case .abort:
                    aborted = true
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
        if aborted == false, let result = try? Interpreters.choiceGraphReduceCollectingStats(
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
            lastEvidence: lastEvidence,
            aborted: aborted
        )
    }
}

// MARK: - Sequential Smoke Property

extension __ExhaustRuntime {
    /// Builds a sequential property for the smoke source: runs commands in order, checks invariants after each step.
    ///
    /// Shared by all spec backends. The sync variant handles `StateMachineSpec`; the async variant bridges through `_blockingAwaitSemaphore`. Both are used as the smoke source's property closure and as the sequential backend's probe property.
    static func syncSequentialProperty<Spec: StateMachineSpec>(_ specType: Spec.Type) -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool {
        let verdictProperty = syncSequentialVerdictProperty(specType)
        return { tagged in
            verdictProperty(tagged).isFailure == false
        }
    }

    /// The one sequential executor loop, returning a verdict: preserves the thrown error as the failure symptom, so the `time:` runner's reduction gate can tell invariant violations (`StateMachineCheckFailure`) apart from user-thrown error types instead of collapsing every spec fault into one capped symptom. ``syncSequentialProperty(_:)`` derives the Bool probe from this, so the two can never disagree on what passes.
    static func syncSequentialVerdictProperty<Spec: StateMachineSpec>(_: Spec.Type) -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> SprawlVerdict {
        { tagged in
            let spec = Spec()
            for (_, command) in tagged {
                do {
                    try spec.run(command)
                    try spec.checkInvariants()
                } catch is StateMachineSkip {
                    continue
                } catch {
                    return .fail(.thrown(error))
                }
            }
            return .pass
        }
    }

    /// Async variant of the sequential smoke property, bridging through `_blockingAwaitSemaphore`.
    static func asyncSequentialProperty<Spec: AsyncStateMachineSpec>(
        specInit: @escaping () -> Spec
    ) -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool {
        nonisolated(unsafe) let specInit = specInit
        return { tagged in
            let passed = _blockingAwaitSemaphore(timeoutMilliseconds: nil) {
                let spec = specInit()
                for (_, command) in tagged {
                    do {
                        try await spec.run(command)
                        try await spec.checkInvariants()
                    } catch is StateMachineSkip {
                        continue
                    } catch {
                        return false
                    }
                }
                return true
            }
            return passed ?? false
        }
    }
}

// MARK: - Two-Pass Reduction Types

extension __ExhaustRuntime {
    enum StateMachineProbeVerdict<Evidence> {
        case pass
        case fail(Evidence)
        /// The probe could not produce a verdict (it timed out) and further probing would reduce toward a hang. ``reduceConcurrentTwoPass(generator:tree:output:deadlineNanoseconds:property:)`` stops reduction and keeps the counterexample as-is.
        case abort
    }

    struct ConcurrentTwoPassResult<Command, Evidence> {
        let value: [(ScheduleMarker, Command)]
        let tree: ChoiceTree
        let stats: ReductionStats
        let lastEvidence: Evidence?
        /// Whether the property aborted reduction. Backends surface this as ``StateMachineReduction/timedOut``.
        let aborted: Bool
    }
}

// MARK: - Source Construction

extension __ExhaustRuntime {
    /// Builds the prioritized source array for a spec machine run.
    ///
    /// Source order matches the design document: screening replay, sampling replay, smoke, screening, sampling. Each source is independently gated by the config. The smoke source is entry-point-specific (sequential has none, cooperative and preemptive construct different property closures), so it is passed in pre-built.
    static func buildStateMachineSources<Command>(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        concurrencyLevel: Int,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool,
        smokeSource: AnyStateMachineCandidateSource<Command>? = nil,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Command)]>)? = nil
    ) -> [AnyStateMachineCandidateSource<Command>] {
        var sources: [AnyStateMachineCandidateSource<Command>] = []

        if let row = config.screeningReplayRow {
            sources.append(.screeningReplay(
                row: row,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: max(UInt64(config.budget.screeningBudget), UInt64(row) + 1),
                concurrencyLevel: concurrencyLevel,
                property: property
            ))
        }

        if let replayIteration = config.replayIteration, let seed = config.seed {
            sources.append(.samplingReplay(
                replaySeed: seed,
                replayIteration: replayIteration,
                sequenceGen: sequenceGen,
                property: property
            ))
        }

        if let smokeSource {
            sources.append(smokeSource)
        }

        if config.shouldRunScreening {
            sources.append(.screening(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: UInt64(config.budget.screeningBudget),
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                property: property
            ))
        }

        if config.replayIteration == nil, config.screeningReplayRow == nil {
            let seed = config.seed ?? Xoshiro256().seed
            sources.append(.sampling(
                sequenceGen: sequenceGen,
                seed: seed,
                samplingBudget: UInt64(config.budget.samplingBudget),
                property: property
            ))
        }

        return sources
    }
}

// MARK: - Sequence Generator Construction

extension __ExhaustRuntime {
    /// Builds the sequential command-sequence generator: up to `commandLimit` commands at constant scaling, each tagged with `ScheduleMarker.prefix`.
    ///
    /// Shared by plain `#execute`'s sequential entry points and the `time:` spec adapter, so the sequence shape (length range, scaling, marker tagging) cannot drift between the modes.
    static func taggedSequenceGenerator<Command>(
        commandGen: ReflectiveGenerator<Command>,
        commandLimit: Int
    ) -> Generator<[(ScheduleMarker, Command)]> {
        commandGen.array(length: 0 ... commandLimit, scaling: .constant).gen.map { commands in
            commands.map { (ScheduleMarker.prefix, $0) }
        }
    }
}

// MARK: - Pick Analysis

extension __ExhaustRuntime {
    /// Extracts pick choices from a command generator when the generator is a top-level ``Gen.pick``.
    static func extractPickChoices(
        from gen: Generator<some Any>
    ) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
        guard case let .impure(operation, _) = gen,
              case let .pick(choices, _) = operation
        else {
            return nil
        }
        return choices
    }

    /// Estimates a default command limit from the command generator's structure and the screening budget.
    ///
    /// Pre-analyzes pick branches to determine the per-position domain size, then computes the sequence length at which SCA rows (at t=2) would exhaust the budget. The result is the larger of this budget ceiling and an exploration floor based on the number of command types, ensuring sequences are long enough for each command to appear several times.
    static func estimateCommandLimit(
        commandGen: Generator<some Any>,
        screeningBudget: UInt64
    ) -> Int {
        guard let pickChoices = extractPickChoices(from: commandGen) else {
            return 10
        }

        let branchCount = pickChoices.count

        // Pre-analyze branch argument domains to estimate the per-position domain size.
        // Use sequenceLength=10 as initial estimate for threshold computation; the threshold is under a sqrt so it is not very sensitive to this value.
        let threshold = SequenceCoveringArray.computeThreshold(
            budget: screeningBudget,
            sequenceLength: 10,
            branchCount: branchCount
        )
        let branchProfiles = SequenceCoveringArray.analyzeBranches(
            pickChoices,
            threshold: threshold,
            screeningBudget: screeningBudget
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
        let ratio = Double(screeningBudget) / domainSizeSquared
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
