/// V-cycle scheduler for principled test case reduction.
///
/// Orchestrates encoders and decoders in the multigrid V-cycle pattern: contravariant sweep (depths max→1, exact), deletion sweep (depths 0→max, guided), covariant sweep (depth 0, guided for binds), post-processing merge, and redistribution.
///
/// Resource tracking uses per-leg budgets with unused-budget forwarding. Each leg has a hard cap (maximum materializations) and a stall patience (maximum consecutive fruitless materializations). Forwarded budget extends productive legs but does not increase patience for unproductive ones.
enum ReductionScheduler {

    // MARK: - Merge

    /// Builds a merged sequence by substituting pre-covariant bound values where they're
    /// shortlex-smaller and within the post-covariant valid range.
    ///
    /// Returns `nil` if no valid substitution exists (pre-checks 2b, 3, 4 all gate this).
    static func buildMergedSequence(
        preCovariantSequence: ChoiceSequence,
        postCovariantSequence: ChoiceSequence,
        preBindIndex: BindSpanIndex,
        postBindIndex: BindSpanIndex
    ) -> ChoiceSequence? {
        guard preBindIndex.regions.count == postBindIndex.regions.count else { return nil }

        // Pre-check 2b: Filter to regions where inner range sizes match (corresponding generator sites).
        // Pre-check 3: Scan for any aligned bound position where pre < post (a merge candidate exists).
        var correspondingRegions: [(BindSpanIndex.BindRegion, BindSpanIndex.BindRegion)] = []
        var anyMergeCandidate = false
        for (oldRegion, newRegion) in zip(preBindIndex.regions, postBindIndex.regions) {
            guard oldRegion.innerRange.count == newRegion.innerRange.count else { continue }
            correspondingRegions.append((oldRegion, newRegion))
            if anyMergeCandidate == false {
                for (oldIdx, newIdx) in zip(oldRegion.boundRange, newRegion.boundRange) {
                    if preCovariantSequence[oldIdx].shortLexCompare(postCovariantSequence[newIdx]) == .lt {
                        anyMergeCandidate = true
                        break
                    }
                }
            }
        }

        guard anyMergeCandidate else { return nil }

        var mergedSeq = postCovariantSequence
        var didMerge = false
        for (oldRegion, newRegion) in correspondingRegions {
            for (oldIdx, newIdx) in zip(oldRegion.boundRange, newRegion.boundRange) {
                // Pre-check 4: Skip substitution if pre-covariant value falls outside post-covariant valid range.
                if let preValue = preCovariantSequence[oldIdx].value,
                   let postValue = postCovariantSequence[newIdx].value,
                   preValue.choice.fits(in: postValue.validRange) == false
                {
                    continue
                }
                if preCovariantSequence[oldIdx].shortLexCompare(postCovariantSequence[newIdx]) == .lt {
                    mergedSeq[newIdx] = preCovariantSequence[oldIdx]
                    didMerge = true
                }
            }
        }

        guard didMerge, mergedSeq.shortLexPrecedes(postCovariantSequence) else { return nil }
        return mergedSeq
    }

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

        var reduceFloatEncoder = ReduceFloatEncoder()
        var deleteAlignedWindowsEncoder = DeleteAlignedWindowsEncoder(
            beamTuning: config.alignedDeletionBeamSearchTuning
        )
        var tandemEncoder = TandemReductionEncoder()
        var redistributeEncoder = CrossStageRedistributeEncoder()
        var bindAwareRedistributeEncoder = BindAwareRedistributeEncoder()

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

        func makeDeletionDecoder(at depth: Int) -> SequenceDecoder {
            let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed)
            return SequenceDecoder.for(context)
        }

        func makeDepthZeroDecoder() -> SequenceDecoder {
            let context = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
            return SequenceDecoder.for(context)
        }

        // MARK: - V-Cycle

        while stallBudget > 0 {
            cycles += 1
            var cycleImproved = false
            let maxBindDepth = bindIndex?.maxBindDepth ?? 0
            var contravariantAccepted = 0
            var deletionAccepted = 0
            var covariantAccepted = 0
            var dirtyDepths = Set(0 ... maxBindDepth)

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
                    for depth in stride(from: maxBindDepth, through: 1, by: -1) where dirtyDepths.contains(depth) {
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
                            if fSpans.isEmpty == false {
                                if try runAdaptive(&reduceFloatEncoder, decoder: decoder, targets: .spans(fSpans), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
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

                    if try runAdaptive(&deleteContainerSpans, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .containerSpans, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteSequenceElements, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .sequenceElements, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteSequenceBoundaries, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .sequenceBoundaries, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                    if try runAdaptive(&deleteFreeStandingValues, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .freeStandingValues, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }

                    if try runAdaptive(&deleteAlignedWindowsEncoder, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .containerSpans, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }

                    if try runAdaptive(&speculativeDelete, decoder: makeDeletionDecoder(at: depth), targets: .spans(deletionTargets(category: .mixed, depth: depth)), structureChanged: true, cache: &rejectCache, budget: &legBudget) {
                        deletionAccepted += 1
                        cycleImproved = true
                    }
                }
                remaining -= legBudget.used
                if deletionAccepted > 0 {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
                }
            }

            // ── Leg 3: Covariant sweep (depth 0) ──
            do {
                let target = cycleBudget.initialBudget(for: .covariant)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                let preCovariantSequence = sequence
                let preCovariantBindIndex = bindIndex
                let preCovariantTree = tree

                let structureChangedOnCovariant = hasBind

                // Zero values.
                do {
                    let vSpansZero = valueSpans(at: 0)
                    if vSpansZero.isEmpty == false {
                        let targets = TargetSet.spans(vSpansZero)
                        if try runBatch(zeroValueEncoder, decoder: makeDepthZeroDecoder(), targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                            covariantAccepted += 1
                            cycleImproved = true
                        }
                    }
                }

                // Binary search to zero.
                do {
                    let vSpansZero = valueSpans(at: 0)
                    if vSpansZero.isEmpty == false {
                        let targets = TargetSet.spans(vSpansZero)
                        if try runAdaptive(&binarySearchToZeroEncoder, decoder: makeDepthZeroDecoder(), targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                            covariantAccepted += 1
                            cycleImproved = true
                        }
                    }
                }

                // Binary search to target.
                do {
                    let vSpansZero = valueSpans(at: 0)
                    if vSpansZero.isEmpty == false {
                        let targets = TargetSet.spans(vSpansZero)
                        if try runAdaptive(&binarySearchToTargetEncoder, decoder: makeDepthZeroDecoder(), targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                            covariantAccepted += 1
                            cycleImproved = true
                        }
                    }
                }

                // Float reduction.
                do {
                    let fSpansZero = floatSpans(at: 0)
                    if fSpansZero.isEmpty == false {
                        if try runAdaptive(&reduceFloatEncoder, decoder: makeDepthZeroDecoder(), targets: .spans(fSpansZero), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                            covariantAccepted += 1
                            cycleImproved = true
                        }
                    }
                }

                // Sibling reordering.
                do {
                    let sGroupsZero = siblingGroups(at: 0)
                    if sGroupsZero.isEmpty == false {
                        if try runBatch(reorderEncoder, decoder: makeDepthZeroDecoder(), targets: .siblingGroups(sGroupsZero), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                            covariantAccepted += 1
                            cycleImproved = true
                        }
                    }
                }

                remaining -= legBudget.used

                // ── Post-processing: Shortlex merge ──
                // Not charged to any leg's budget — fixed per-cycle overhead.
                if hasBind, covariantAccepted > 0,
                   let preBi = preCovariantBindIndex, let postBi = bindIndex
                {
                    if let mergedSeq = Self.buildMergedSequence(
                        preCovariantSequence: preCovariantSequence,
                        postCovariantSequence: sequence,
                        preBindIndex: preBi,
                        postBindIndex: postBi
                    ) {
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
                if covariantAccepted > 0 {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
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
                var redistributionAccepted = false

                // Bind-aware redistribution: coordinate inner+bound across bind regions.
                // Runs first because it's the most targeted for bind-coupled generators,
                // where the cross-stage encoder cannot make progress.
                if hasBind, let bi = bindIndex, bi.regions.count >= 2 {
                    let regionPairs = BindAwareRedistributeEncoder.buildPlans(
                        from: sequence, bindIndex: bi
                    )
                    for plan in regionPairs {
                        guard legBudget.isExhausted == false else { break }
                        let sinkRegionIndex = plan.sink.regionIndex
                        let bindRedistDecoder = SequenceDecoder.guided(
                            fallbackTree: fallbackTree ?? tree,
                            strictness: .normal,
                            maximizeBoundRegionIndices: Set([sinkRegionIndex])
                        )
                        bindAwareRedistributeEncoder.startPlan(
                            sequence: sequence, plan: plan
                        )
                        var lastAccepted = false
                        while let probe = bindAwareRedistributeEncoder.nextProbe(lastAccepted: lastAccepted) {
                            guard legBudget.isExhausted == false else { break }
                            if let result = try bindRedistDecoder.decode(
                                candidate: probe, gen: gen, tree: tree,
                                originalSequence: sequence, property: property
                            ) {
                                legBudget.recordMaterialization(accepted: true)
                                accept(result, structureChanged: true)
                                lastAccepted = true
                                cycleImproved = true
                                redistributionAccepted = true
                                if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "bindAwareRedistribute"]) }
                            } else {
                                legBudget.recordMaterialization(accepted: false)
                                lastAccepted = false
                            }
                        }
                    }
                }

                // Tandem reduction: reduce sibling value pairs together.
                let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
                if allSiblings.isEmpty == false {
                    if try runAdaptive(&tandemEncoder, decoder: redistDecoder, targets: .siblingGroups(allSiblings), structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                        cycleImproved = true
                        redistributionAccepted = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "tandemReduction"]) }
                    }
                }

                // Cross-stage redistribution: move mass between coordinates.
                if try runAdaptive(&redistributeEncoder, decoder: redistDecoder, targets: .wholeSequence, structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                    cycleImproved = true
                    redistributionAccepted = true
                    if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "crossStageRedistribute"]) }
                }

                if redistributionAccepted {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
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
