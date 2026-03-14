/// V-cycle scheduler for principled test case reduction.
///
/// Orchestrates encoders and decoders in the multigrid V-cycle pattern: contravariant sweep (depths max→1, exact), deletion sweep (depths 0→max, guided), covariant sweep (depth 0, guided for binds), post-processing merge, and redistribution.
enum ReductionScheduler {

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
        let crossStageTactics: [any CrossStageShrinkTactic] = [
            ReduceInTandemTactic(probeBudget: config.probeBudgets.reduceValuesInTandem, onBudgetExhausted: budgetLogger),
            RedistributeTactic(probeBudget: config.probeBudgets.redistributeNumericPairs, onBudgetExhausted: budgetLogger),
        ]

        // MARK: - Helpers

        // Accepts a successful result and updates mutable state.
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

        /// Runs a batch encoder against a decoder. Returns true if a candidate was accepted.
        func runBatch(
            _ encoder: any BatchEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache: inout ReducerCache
        ) throws -> Bool {
            for candidate in encoder.encode(sequence: sequence, targets: targets) {
                guard cache.contains(candidate) == false else { continue }
                if let result = try decoder.decode(
                    candidate: candidate, gen: gen, tree: tree,
                    originalSequence: sequence, property: property
                ) {
                    accept(result, structureChanged: structureChanged)
                    return true
                }
                cache.insert(candidate)
            }
            return false
        }

        /// Runs an adaptive encoder against a decoder. Returns true if any probe was accepted.
        func runAdaptive(
            _ encoder: inout some AdaptiveEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache: inout ReducerCache
        ) throws -> Bool {
            encoder.start(sequence: sequence, targets: targets)
            var lastAccepted = false
            var anyAccepted = false
            while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
                if let result = try decoder.decode(
                    candidate: probe, gen: gen, tree: tree,
                    originalSequence: sequence, property: property
                ) {
                    accept(result, structureChanged: structureChanged)
                    lastAccepted = true
                    anyAccepted = true
                } else {
                    lastAccepted = false
                }
            }
            return anyAccepted
        }

        /// Extracts value spans at a specific bind depth.
        func valueSpans(at depth: Int) -> [ChoiceSpan] {
            let all = ChoiceSequence.extractAllValueSpans(from: sequence)
            if let bi = bindIndex {
                return all.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
            }
            return all
        }

        /// Extracts sibling groups at a specific bind depth.
        func siblingGroups(at depth: Int) -> [SiblingGroup] {
            let all = ChoiceSequence.extractSiblingGroups(from: sequence)
            if let bi = bindIndex {
                return all.filter { bi.bindDepth(at: $0.ranges[0].lowerBound) == depth }
            }
            return all
        }

        /// Extracts float value spans at a specific bind depth.
        func floatSpans(at depth: Int) -> [ChoiceSpan] {
            valueSpans(at: depth).filter { span in
                guard let v = sequence[span.range.lowerBound].value else { return false }
                return v.choice.tag == .double || v.choice.tag == .float
            }
        }

        /// Extracts spans of a specific deletion category at a specific depth.
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

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "vcycle_start",
                    metadata: ["cycle": "\(cycles)", "stall_budget": "\(stallBudget)", "max_bind_depth": "\(maxBindDepth)"]
                )
            }

            // ── Pre-cycle: Branch tactics ──
            for branchEncoder in branchEncoders {
                let decoder = SequenceDecoder.guided(fallbackTree: fallbackTree ?? tree, strictness: .relaxed)
                for candidate in branchEncoder.encode(sequence: sequence, tree: tree) {
                    if let result = try decoder.decode(
                        candidate: candidate, gen: gen, tree: tree,
                        originalSequence: sequence, property: property
                    ) {
                        accept(result, structureChanged: true)
                        cycleImproved = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "branch_accepted", metadata: ["encoder": branchEncoder.name]) }
                        break
                    }
                }
            }

            // ── Leg 1: Contravariant sweep (depths max → 1) ──
            // Value minimization + reordering ONLY. Structure-preserving, exact.
            rejectCache = ReducerCache()
            if maxBindDepth >= 1 {
                for depth in stride(from: maxBindDepth, through: 1, by: -1) {
                    var depthProgress = true
                    while depthProgress {
                        depthProgress = false
                        let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
                        let decoder = SequenceDecoder.for(context)

                        // Value minimization: zero, binary search to zero, binary search to target.
                        let vSpans = valueSpans(at: depth)
                        if vSpans.isEmpty == false {
                            let targets = TargetSet.spans(vSpans)
                            if try runBatch(zeroValueEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache) {
                                depthProgress = true
                                contravariantAccepted += 1
                            }
                            if try runAdaptive(&binarySearchToZeroEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache) {
                                depthProgress = true
                                contravariantAccepted += 1
                            }
                            if try runAdaptive(&binarySearchToTargetEncoder, decoder: decoder, targets: targets, structureChanged: false, cache: &rejectCache) {
                                depthProgress = true
                                contravariantAccepted += 1
                            }
                        }

                        // Float reduction (legacy tactic).
                        let fSpans = floatSpans(at: depth)
                        if fSpans.isEmpty == false {
                            let tacticContext = TacticContext(bindIndex: bindIndex, depth: depth, fallbackTree: fallbackTree)
                            if let result = try floatTactic.apply(
                                gen: gen, sequence: sequence, tree: tree,
                                targetSpans: fSpans, context: tacticContext,
                                property: property, rejectCache: &rejectCache
                            ) {
                                accept(result, structureChanged: false)
                                depthProgress = true
                                contravariantAccepted += 1
                            }
                        }

                        // Reordering.
                        let sGroups = siblingGroups(at: depth)
                        if sGroups.isEmpty == false {
                            if try runBatch(reorderEncoder, decoder: decoder, targets: .siblingGroups(sGroups), structureChanged: false, cache: &rejectCache) {
                                depthProgress = true
                                contravariantAccepted += 1
                            }
                        }
                    }
                }
            }

            // ── Leg 2: Deletion sweep (depths 0 → max) ──
            rejectCache = ReducerCache()
            for depth in 0 ... maxBindDepth {
                let deletionContext = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed)
                let deletionDecoder = SequenceDecoder.for(deletionContext)

                if try runAdaptive(&deleteContainerSpans, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .containerSpans, depth: depth)), structureChanged: true, cache: &rejectCache) {
                    deletionAccepted += 1
                    cycleImproved = true
                }
                if try runAdaptive(&deleteSequenceElements, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .sequenceElements, depth: depth)), structureChanged: true, cache: &rejectCache) {
                    deletionAccepted += 1
                    cycleImproved = true
                }
                if try runAdaptive(&deleteSequenceBoundaries, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .sequenceBoundaries, depth: depth)), structureChanged: true, cache: &rejectCache) {
                    deletionAccepted += 1
                    cycleImproved = true
                }
                if try runAdaptive(&deleteFreeStandingValues, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .freeStandingValues, depth: depth)), structureChanged: true, cache: &rejectCache) {
                    deletionAccepted += 1
                    cycleImproved = true
                }

                // Legacy: aligned window deletion (not yet extracted as encoder).
                let tacticContext = TacticContext(bindIndex: bindIndex, depth: depth, fallbackTree: fallbackTree)
                let containerSpans = deletionTargets(category: .containerSpans, depth: depth)
                if containerSpans.isEmpty == false {
                    if let result = try alignedWindowsTactic.apply(
                        gen: gen, sequence: sequence, tree: tree,
                        targetSpans: containerSpans, context: tacticContext,
                        property: property, rejectCache: &rejectCache
                    ) {
                        accept(result, structureChanged: true)
                        deletionAccepted += 1
                    cycleImproved = true
                    }
                }

                if try runAdaptive(&speculativeDelete, decoder: deletionDecoder, targets: .spans(deletionTargets(category: .mixed, depth: depth)), structureChanged: true, cache: &rejectCache) {
                    deletionAccepted += 1
                    cycleImproved = true
                }
            }

            // ── Leg 3: Covariant sweep (depth 0) ──
            rejectCache = ReducerCache()
            let preCovariantSequence = sequence
            let preCovariantBindIndex = bindIndex
            let preCovariantTree = tree

            let depth0Context = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal)
            let depth0Decoder = SequenceDecoder.for(depth0Context)
            let structureChangedOnCovariant = hasBind

            // Value minimization at depth 0.
            let vSpans0 = valueSpans(at: 0)
            if vSpans0.isEmpty == false {
                let targets = TargetSet.spans(vSpans0)
                if try runBatch(zeroValueEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache) {
                    covariantAccepted += 1
                    cycleImproved = true
                }
                if try runAdaptive(&binarySearchToZeroEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache) {
                    covariantAccepted += 1
                    cycleImproved = true
                }
                if try runAdaptive(&binarySearchToTargetEncoder, decoder: depth0Decoder, targets: targets, structureChanged: structureChangedOnCovariant, cache: &rejectCache) {
                    covariantAccepted += 1
                    cycleImproved = true
                }
            }

            // Float reduction at depth 0 (legacy tactic).
            let fSpans0 = floatSpans(at: 0)
            if fSpans0.isEmpty == false {
                let tacticContext = TacticContext(bindIndex: bindIndex, depth: 0, fallbackTree: fallbackTree)
                if let result = try floatTactic.apply(
                    gen: gen, sequence: sequence, tree: tree,
                    targetSpans: fSpans0, context: tacticContext,
                    property: property, rejectCache: &rejectCache
                ) {
                    accept(result, structureChanged: structureChangedOnCovariant)
                    covariantAccepted += 1
                    cycleImproved = true
                }
            }

            // Reordering at depth 0.
            let sGroups0 = siblingGroups(at: 0)
            if sGroups0.isEmpty == false {
                if try runBatch(reorderEncoder, decoder: depth0Decoder, targets: .siblingGroups(sGroups0), structureChanged: structureChangedOnCovariant, cache: &rejectCache) {
                    covariantAccepted += 1
                    cycleImproved = true
                }
            }

            // ── Post-processing: Shortlex merge ──
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

            // ── Cross-cutting: Redistribution ──
            let redistributionTriggered =
                (contravariantAccepted == 0 && deletionAccepted == 0)
                || cyclesSinceRedistribution >= redistributionDeferralCap

            if redistributionTriggered {
                cyclesSinceRedistribution = 0
                let crossStageContext = TacticContext(bindIndex: bindIndex, depth: -1, fallbackTree: fallbackTree)
                let allValues = ChoiceSequence.extractAllValueSpans(from: sequence)
                let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
                for tactic in crossStageTactics {
                    if let result = try tactic.apply(
                        gen: gen, sequence: sequence, tree: tree,
                        siblingGroups: allSiblings, allValueSpans: allValues,
                        context: crossStageContext, property: property,
                        rejectCache: &rejectCache
                    ) {
                        accept(result, structureChanged: hasBind)
                        cycleImproved = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["tactic": tactic.name]) }
                        break
                    }
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
