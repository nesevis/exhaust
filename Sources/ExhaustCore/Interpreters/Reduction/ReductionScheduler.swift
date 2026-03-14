/// V-cycle scheduler for principled test case reduction.
///
/// Orchestrates encoders and decoders in the multigrid V-cycle pattern: contravariant sweep (depths max→1, exact), deletion sweep (depths 0→max, guided), covariant sweep (depth 0, guided for binds), post-processing merge, and redistribution.
///
/// Resource tracking uses per-leg budgets with unused-budget forwarding. Each leg has a hard cap (maximum materializations) and a stall patience (maximum consecutive fruitless materializations). Forwarded budget extends productive legs but does not increase patience for unproductive ones.
enum ReductionScheduler {

    // MARK: - Leg Budget Tracker

    /// Tracks materialization budget within a single V-cycle leg.
    ///
    /// Two counters: `used` (total materializations, capped by `hardCap`) and `consecutiveFruitless` (consecutive failures, capped by `stallPatience`). A success resets the fruitless counter.
    struct LegBudget {
        /// Maximum total materializations this leg may consume.
        let hardCap: Int
        /// Maximum consecutive fruitless materializations before the leg gives up.
        let stallPatience: Int

        private(set) var used = 0
        private(set) var consecutiveFruitless = 0

        var isExhausted: Bool {
            used >= hardCap || consecutiveFruitless >= stallPatience
        }

        mutating func recordMaterialization(accepted: Bool) {
            used += 1
            if accepted {
                consecutiveFruitless = 0
            } else {
                consecutiveFruitless += 1
            }
        }
    }

    // MARK: - Default cycle budget

    /// Default per-cycle materialization budget.
    ///
    /// Sized to allow thorough reduction for typical generators. The per-leg weights distribute this across the V-cycle legs.
    static let defaultCycleBudgetTotal = 200

    // MARK: - Entry Point

    /// Runs the V-cycle reduction to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        config: Interpreters.KleisliReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        guard var output = try Interpreters.materialize(gen, with: tree, using: sequence) else {
            return nil
        }

        let hasBind = initialTree.containsBind
        var bindIndex: BindSpanIndex? = hasBind ? BindSpanIndex(from: sequence) : nil
        var fallbackTree: ChoiceTree? = hasBind ? tree : nil
        var bestSequence = sequence
        var bestOutput = output
        var rejectCache = ReducerCache()
        var stallBudget = config.maxStalls
        var cyclesSinceRedistribution = 0
        let redistributionDeferralCap = 3
        var cycles = 0

        let cycleBudget = CycleBudget(total: defaultCycleBudgetTotal, legWeights: CycleBudget.defaultWeights())

        // Build encoders.
        let branchEncoders: [any BranchEncoder] = [PromoteBranchesEncoder(), PivotBranchesEncoder()]
        var deleteContainerSpans = DeleteContainerSpansEncoder()
        var deleteSequenceElements = DeleteSequenceElementsEncoder()
        var deleteSequenceBoundaries = DeleteSequenceBoundariesEncoder()
        var deleteFreeStandingValues = DeleteFreeStandingValuesEncoder()
        var speculativeDelete = SpeculativeDeleteEncoder()
        let zeroValueEncoder = ZeroValueEncoder()
        var binarySearchToZeroEncoder = BinarySearchToZeroEncoder()
        var binarySearchToTargetEncoder = BinarySearchToTargetEncoder()
        let reorderEncoder = ReorderSiblingsEncoder()

        // Legacy tactics for encoders not yet extracted.
        let budgetLogger: ((String) -> Void)? = isInstrumented ? { message in
            ExhaustLog.notice(category: .reducer, event: "kleisli_probe_budget_exhausted", message)
        } : nil
        let alignedWindowsTactic = DeleteAlignedWindowsTactic(
            probeBudget: config.probeBudgets.deleteAlignedSiblingWindows,
            subsetBeamSearchTuning: config.alignedDeletionBeamSearchTuning,
            onBudgetExhausted: budgetLogger
        )
        let floatTactic = ReduceFloatTactic()
        var tandemEncoder = TandemReductionEncoder()
        var redistributeEncoder = CrossStageRedistributeEncoder()

        // MARK: - Helpers

        func accept(_ result: ShrinkResult<Output>, structureChanged: Bool) {
            sequence = result.sequence
            tree = result.tree
            output = result.output
            fallbackTree = result.tree
            if structureChanged {
                bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
            }
            if hasBind {
                bestSequence = sequence
                bestOutput = output
            } else if sequence.shortLexPrecedes(bestSequence) {
                bestSequence = sequence
                bestOutput = output
            }
        }

        /// Runs a batch encoder against a decoder, tracking materializations. Returns true if a candidate was accepted.
        func runBatch(
            _ encoder: any BatchEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache: inout ReducerCache,
            budget: inout LegBudget
        ) throws -> Bool {
            guard budget.isExhausted == false else { return false }
            for candidate in encoder.encode(sequence: sequence, targets: targets) {
                guard budget.isExhausted == false else { return false }
                guard cache.contains(candidate) == false else { continue }
                if let result = try decoder.decode(
                    candidate: candidate, gen: gen, tree: tree,
                    originalSequence: sequence, property: property
                ) {
                    budget.recordMaterialization(accepted: true)
                    accept(result, structureChanged: structureChanged)
                    return true
                }
                budget.recordMaterialization(accepted: false)
                cache.insert(candidate)
            }
            return false
        }

        /// Runs an adaptive encoder against a decoder, tracking materializations. Returns true if any probe was accepted.
        func runAdaptive(
            _ encoder: inout some AdaptiveEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache: inout ReducerCache,
            budget: inout LegBudget
        ) throws -> Bool {
            guard budget.isExhausted == false else { return false }
            encoder.start(sequence: sequence, targets: targets)
            var lastAccepted = false
            var anyAccepted = false
            while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
                guard budget.isExhausted == false else { break }
                if let result = try decoder.decode(
                    candidate: probe, gen: gen, tree: tree,
                    originalSequence: sequence, property: property
                ) {
                    budget.recordMaterialization(accepted: true)
                    accept(result, structureChanged: structureChanged)
                    lastAccepted = true
                    anyAccepted = true
                } else {
                    budget.recordMaterialization(accepted: false)
                    lastAccepted = false
                }
            }
            return anyAccepted
        }

        func valueSpans(at depth: Int) -> [ChoiceSpan] {
            let all = ChoiceSequence.extractAllValueSpans(from: sequence)
            if let bi = bindIndex {
                return all.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
            }
            return all
        }

        func siblingGroups(at depth: Int) -> [SiblingGroup] {
            let all = ChoiceSequence.extractSiblingGroups(from: sequence)
            if let bi = bindIndex {
                return all.filter { bi.bindDepth(at: $0.ranges[0].lowerBound) == depth }
            }
            return all
        }

        func floatSpans(at depth: Int) -> [ChoiceSpan] {
            valueSpans(at: depth).filter { span in
                guard let v = sequence[span.range.lowerBound].value else { return false }
                return v.choice.tag == .double || v.choice.tag == .float
            }
        }

        func deletionTargets(category: DeletionSpanCategory, depth: Int) -> [ChoiceSpan] {
            let spans: [ChoiceSpan]
            switch category {
            case .containerSpans:
                spans = ChoiceSequence.extractContainerSpans(from: sequence)
            case .sequenceElements:
                spans = ChoiceSequence.extractSequenceElementSpans(from: sequence)
            case .sequenceBoundaries:
                spans = ChoiceSequence.extractSequenceBoundarySpans(from: sequence)
            case .freeStandingValues:
                spans = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
            case .siblingGroups, .mixed:
                spans = ChoiceSequence.extractContainerSpans(from: sequence)
            }
            if let bi = bindIndex {
                return spans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
            }
            return spans
        }

        // MARK: - V-Cycle

        while stallBudget > 0 {
            cycles += 1
            var cycleImproved = false
            let maxBindDepth = bindIndex?.maxBindDepth ?? 0
            var contravariantAccepted = 0
            var deletionAccepted = 0
            var covariantAccepted = 0

            // Per-cycle budget with unused-budget forwarding.
            var remaining = cycleBudget.total

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "vcycle_start",
                    metadata: ["cycle": "\(cycles)", "stall_budget": "\(stallBudget)", "max_bind_depth": "\(maxBindDepth)", "cycle_budget": "\(remaining)"]
                )
            }

            // ── Pre-cycle: Branch tactics ──
            do {
                let target = cycleBudget.initialBudget(for: .branch)
                var branchBudget = LegBudget(hardCap: remaining, stallPatience: target)
                for branchEncoder in branchEncoders {
                    guard branchBudget.isExhausted == false else { break }
                    let decoder = SequenceDecoder.guided(fallbackTree: fallbackTree ?? tree, strictness: .relaxed)
                    for candidate in branchEncoder.encode(sequence: sequence, tree: tree) {
                        guard branchBudget.isExhausted == false else { break }
                        if let result = try decoder.decode(
                            candidate: candidate, gen: gen, tree: tree,
                            originalSequence: sequence, property: property
                        ) {
                            branchBudget.recordMaterialization(accepted: true)
                            accept(result, structureChanged: true)
                            cycleImproved = true
                            if isInstrumented { ExhaustLog.debug(category: .reducer, event: "branch_accepted", metadata: ["encoder": branchEncoder.name]) }
                            break
                        }
                        branchBudget.recordMaterialization(accepted: false)
                    }
                }
                remaining -= branchBudget.used
            }

            // ── Leg 1: Contravariant sweep (depths max → 1) ──
            do {
                let target = cycleBudget.initialBudget(for: .contravariant)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                if maxBindDepth >= 1 {
                    for depth in stride(from: maxBindDepth, through: 1, by: -1) {
                        guard legBudget.isExhausted == false else { break }
                        var depthProgress = true
                        while depthProgress, legBudget.isExhausted == false {
                            depthProgress = false
                            let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
                            let decoder = SequenceDecoder.for(context)

                            let vSpans = valueSpans(at: depth)
                            if vSpans.isEmpty == false {
                                let targets = TargetSet.spans(vSpans)
                                if try runBatch(zeroValueEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                    depthProgress = true
                                    contravariantAccepted += 1
                                }
                                if try runAdaptive(&binarySearchToZeroEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                    depthProgress = true
                                    contravariantAccepted += 1
                                }
                                if try runAdaptive(&binarySearchToTargetEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                    depthProgress = true
                                    contravariantAccepted += 1
                                }
                            }

                            let fSpans = floatSpans(at: depth)
                            if fSpans.isEmpty == false, legBudget.isExhausted == false {
                                let tacticContext = TacticContext(bindIndex: bindIndex, depth: depth, fallbackTree: fallbackTree)
                                if let result = try floatTactic.apply(
                                    gen: gen, sequence: sequence, tree: tree,
                                    targetSpans: fSpans, context: tacticContext,
                                    property: property, rejectCache: &rejectCache
                                ) {
                                    legBudget.recordMaterialization(accepted: true)
                                    accept(result, structureChanged: false)
                                    depthProgress = true
                                    contravariantAccepted += 1
                                }
                            }

                            let sGroups = siblingGroups(at: depth)
                            if sGroups.isEmpty == false {
                                if try runBatch(reorderEncoder, decoder: decoder, targets: .siblingGroups(sGroups), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                    depthProgress = true
                                    contravariantAccepted += 1
                                }
                            }
                        }
                    }
                }
                remaining -= legBudget.used
            }

            // ── Leg 2: Deletion sweep (depths 0 → max) ──
            do {
                let target = cycleBudget.initialBudget(for: .deletion)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                for depth in 0 ... maxBindDepth {
                    guard legBudget.isExhausted == false else { break }
                    let deletionContext = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed)
                    let deletionDecoder = SequenceDecoder.for(deletionContext)

                    if try runAdaptive(&deleteContainerSpans, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .containerSpans, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteSequenceElements, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .sequenceElements, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteSequenceBoundaries, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .sequenceBoundaries, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteFreeStandingValues, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .freeStandingValues, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }

                    // Legacy: aligned window deletion.
                    if legBudget.isExhausted == false {
                        let tacticContext = TacticContext(bindIndex: bindIndex, depth: depth, fallbackTree: fallbackTree)
                        let containerSpans = deletionTargets(category: .containerSpans, depth: depth)
                        if containerSpans.isEmpty == false {
                            if let result = try alignedWindowsTactic.apply(
                                gen: gen, sequence: sequence, tree: tree,
                                targetSpans: containerSpans, context: tacticContext,
                                property: property, rejectCache: &rejectCache
                            ) {
                                legBudget.recordMaterialization(accepted: true)
                                accept(result, structureChanged: true)
                                deletionAccepted += 1
                                cycleImproved = true
                            }
                        }
                    }

                    if try runAdaptive(&speculativeDelete, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .mixed, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                }
                remaining -= legBudget.used
            }

            // ── Leg 3: Covariant sweep (depth 0) ──
            do {
                let target = cycleBudget.initialBudget(for: .covariant)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                let preCovariantSequence = sequence
                let preCovariantBindIndex = bindIndex
                let preCovariantTree = tree

                let depth0Context = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
                let depth0Decoder = SequenceDecoder.for(depth0Context)
                let structureChangedOnCovariant = hasBind

                let vSpans0 = valueSpans(at: 0)
                if vSpans0.isEmpty == false {
                    let targets = TargetSet.spans(vSpans0)
                    if try runBatch(zeroValueEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                        covariantAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&binarySearchToZeroEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                        covariantAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&binarySearchToTargetEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                        covariantAccepted += 1
                        cycleImproved = true
                    }
                }

                let fSpans0 = floatSpans(at: 0)
                if fSpans0.isEmpty == false, legBudget.isExhausted == false {
                    let tacticContext = TacticContext(bindIndex: bindIndex, depth: 0, fallbackTree: fallbackTree)
                    if let result = try floatTactic.apply(
                        gen: gen, sequence: sequence, tree: tree,
                        targetSpans: fSpans0, context: tacticContext,
                        property: property, rejectCache: &rejectCache
                    ) {
                        legBudget.recordMaterialization(accepted: true)
                        accept(result, structureChanged: structureChangedOnCovariant)
                        covariantAccepted += 1
                        cycleImproved = true
                    }
                }

                let sGroups0 = siblingGroups(at: 0)
                if sGroups0.isEmpty == false {
                    if try runBatch(reorderEncoder, decoder: depth0Decoder, targets: .siblingGroups(sGroups0), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                        covariantAccepted += 1
                        cycleImproved = true
                    }
                }

                remaining -= legBudget.used

                // ── Post-processing: Shortlex merge ──
                // Not charged to any leg's budget — fixed per-cycle overhead.
                if hasBind, covariantAccepted > 0,
                   let preBi = preCovariantBindIndex, let postBi = bindIndex,
                   preBi.regions.count == postBi.regions.count
                {
                    var mergedSeq = sequence
                    var didMerge = false
                    for (oldRegion, newRegion) in zip(preBi.regions, postBi.regions) {
                        for (oldIdx, newIdx) in zip(oldRegion.boundRange, newRegion.boundRange) {
                            if preCovariantSequence[oldIdx].shortLexCompare(sequence[newIdx]) == .lt {
                                mergedSeq[newIdx] = preCovariantSequence[oldIdx]
                                didMerge = true
                            }
                        }
                    }

                    if didMerge, mergedSeq.shortLexPrecedes(sequence) {
                        let seed = mergedSeq.zobristHash
                        if case let .success(mergedOutput, mergedFinalSeq, mergedTree) =
                            GuidedMaterializer.materialize(gen, prefix: mergedSeq, seed: seed, fallbackTree: preCovariantTree),
                           property(mergedOutput) == false,
                           mergedFinalSeq.shortLexPrecedes(sequence)
                        {
                            let mergeResult = ShrinkResult(sequence: mergedFinalSeq, tree: mergedTree, output: mergedOutput, evaluations: 1)
                            accept(mergeResult, structureChanged: true)
                            cycleImproved = true
                            if isInstrumented { ExhaustLog.debug(category: .reducer, event: "merge_accepted") }
                        }
                    }
                }
            }

            // ── Cross-cutting: Redistribution ──
            let redistributionTriggered =
                (contravariantAccepted == 0 && deletionAccepted == 0)
                || cyclesSinceRedistribution >= redistributionDeferralCap

            if redistributionTriggered {
                cyclesSinceRedistribution = 0
                let target = cycleBudget.initialBudget(for: .redistribution)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                let redistContext = DecoderContext(depth: .global, bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
                let redistDecoder = SequenceDecoder.for(redistContext)

                // Tandem reduction: reduce sibling value pairs together.
                let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
                if allSiblings.isEmpty == false {
                    if try runAdaptive(&tandemEncoder, decoder: redistDecoder, targets: .siblingGroups(allSiblings), structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                        cycleImproved = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "tandemReduction"]) }
                    }
                }

                // Cross-stage redistribution: move mass between coordinates.
                if try runAdaptive(&redistributeEncoder, decoder: redistDecoder, targets: .wholeSequence, structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                    cycleImproved = true
                    if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "crossStageRedistribute"]) }
                }
            } else {
                cyclesSinceRedistribution += 1
            }

            // ── Cycle termination ──
            if cycleImproved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }
        }

        if isInstrumented {
            ExhaustLog.notice(category: .reducer, event: "vcycle_complete", metadata: ["cycles": "\(cycles)"])
        }

        return (bestSequence, bestOutput)
    }
}
