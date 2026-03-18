// MARK: - Phase 1: Structural Minimization
//
// Phase methods for the PrincipledScheduler. Extends ReductionState with structural minimization (Phase 1) and DAG-guided value minimization (Phase 2). All sub-phases call the same runBatch/runAdaptive/accept infrastructure as the V-cycle legs.

extension ReductionState {
    /// Runs structural minimization with restart-on-success policy.
    ///
    /// All sub-phases restart from branch simplification on success (branch re-check is cheap after any structural change). Returns the final DAG and whether any progress was made.
    func runStructuralMinimization(
        budget: inout Int
    ) throws -> (dag: DependencyDAG?, progress: Bool) {
        var anyProgress = false

        while budget > 0 {
            var roundProgress = false

            // 1a: Branch simplification.
            if try runBranchSimplification(budget: &budget) {
                roundProgress = true
                anyProgress = true
                continue // Restart from 1a.
            }

            // 1b: Structural deletion.
            let dag = rebuildDAGIfNeeded()
            if try runStructuralDeletion(budget: &budget, dag: dag) {
                roundProgress = true
                anyProgress = true
                continue // Restart from 1a.
            }

            // 1c: Joint bind-inner reduction.
            if try runJointBindInnerReduction(budget: &budget) {
                roundProgress = true
                anyProgress = true
                continue // Restart from 1a.
            }

            if roundProgress == false {
                break
            }
        }

        let finalDAG = rebuildDAGIfNeeded()
        return (finalDAG, anyProgress)
    }

    /// Rebuilds the ``DependencyDAG`` from the current sequence, tree, and bind index.
    ///
    /// Returns `nil` for bind-free generators.
    private func rebuildDAGIfNeeded() -> DependencyDAG? {
        guard hasBind, let bindSpanIndex = bindIndex else {
            return nil
        }
        return DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindSpanIndex)
    }

    // MARK: - Sub-phase 1a: Branch Simplification

    /// Runs branch promotion and pivoting encoders.
    private func runBranchSimplification(budget: inout Int) throws -> Bool {
        let subBudget = min(budget, 200)
        guard subBudget > 0 else { return false }

        let branchContext = DecoderContext(
            depth: .specific(0),
            bindIndex: bindIndex,
            fallbackTree: fallbackTree,
            strictness: .relaxed,
            useReductionMaterializer: config.useReductionMaterializer,
            materializePicks: true
        )
        let branchDecoder = SequenceDecoder.for(branchContext)
        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        var improved = false

        // Re-materialize with picks so branch encoders see all non-selected alternatives.
        if case let .success(_, freshTree) = ReductionMaterializer.materialize(
            gen, prefix: sequence, mode: .exact, fallbackTree: fallbackTree,
            materializePicks: true
        ) {
            tree = freshTree
        }

        promoteBranchesEncoder.currentTree = tree
        if try runBatch(
            promoteBranchesEncoder,
            decoder: branchDecoder,
            targets: .wholeSequence,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
        }

        pivotBranchesEncoder.currentTree = tree
        if try runBatch(
            pivotBranchesEncoder,
            decoder: branchDecoder,
            targets: .wholeSequence,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
        }

        budget -= legBudget.used
        return improved
    }

    // MARK: - Sub-phase 1b: Structural Deletion

    /// Runs deletion encoders across all bind depths. Returns `true` on first acceptance (caller rebuilds DAG and restarts).
    private func runStructuralDeletion(
        budget: inout Int,
        dag: DependencyDAG?
    ) throws -> Bool {
        let subBudget = min(budget, 1200)
        guard subBudget > 0 else { return false }

        let maxBindDepth = bindIndex?.maxBindDepth ?? 0
        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        lattice.invalidate()

        for depth in 0 ... maxBindDepth {
            guard legBudget.isExhausted == false else { break }
            lattice.invalidate()
            let depthDecoder = makeDeletionDecoder(at: depth)

            for slot in pruneOrder {
                guard legBudget.isExhausted == false else { break }
                let targets = spanCache.deletionTargets(
                    category: slot.spanCategory,
                    depth: depth,
                    from: sequence,
                    bindIndex: bindIndex
                )
                let slotAccepted: Bool
                switch slot {
                case .speculativeDelete:
                    slotAccepted = try runAdaptive(
                        speculativeDelete,
                        decoder: makeSpeculativeDecoder(),
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .containerSpans:
                    slotAccepted = try runAdaptive(
                        deleteContainerSpans,
                        decoder: depthDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .sequenceElements:
                    slotAccepted = try runAdaptive(
                        deleteSequenceElements,
                        decoder: depthDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .sequenceBoundaries:
                    slotAccepted = try runAdaptive(
                        deleteSequenceBoundaries,
                        decoder: depthDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .freeStandingValues:
                    slotAccepted = try runAdaptive(
                        deleteFreeStandingValues,
                        decoder: depthDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .alignedWindows:
                    slotAccepted = try runAdaptive(
                        deleteAlignedWindowsEncoder,
                        decoder: depthDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                }
                if slotAccepted {
                    ReductionScheduler.moveToFront(slot, in: &pruneOrder)
                    budget -= legBudget.used
                    return true // Restart from 1a.
                }
            }
        }

        budget -= legBudget.used
        return false
    }

    // MARK: - Sub-phase 1c: Joint Bind-Inner Reduction

    /// Runs product-space and bind-root-search encoders on bind-inner values.
    private func runJointBindInnerReduction(budget: inout Int) throws -> Bool {
        guard hasBind, let bindSpanIndex = bindIndex else { return false }
        let subBudget = min(budget, 600)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        lattice.invalidate()
        var accepted = 0

        let prngDecoder: SequenceDecoder = .guided(fallbackTree: nil, usePRNGFallback: true)
        let bindInnerCount = bindSpanIndex.regions.count

        if bindInnerCount <= 3 {
            // Batch: enumerate product space of bind-inner values.
            productSpaceBatchEncoder.bindIndex = bindSpanIndex
            productSpaceBatchEncoder.dag = DependencyDAG.build(
                from: sequence, tree: tree, bindIndex: bindSpanIndex
            )

            // Tier 1: guided replay (clamp bound entries to current tree).
            let guidedDecoder: SequenceDecoder = .guided(
                fallbackTree: fallbackTree ?? tree
            )
            if try runBatch(
                productSpaceBatchEncoder, decoder: guidedDecoder,
                targets: .wholeSequence, structureChanged: true,
                budget: &legBudget
            ) {
                accepted += 1
            } else if try runBatch(
                // Tier 2: PRNG fallback (fresh bound content).
                productSpaceBatchEncoder, decoder: prngDecoder,
                targets: .wholeSequence, structureChanged: true,
                budget: &legBudget
            ) {
                accepted += 1
            }
        } else {
            // Adaptive: delta-debug coordinate halving for k > 3.
            productSpaceAdaptiveEncoder.bindIndex = bindSpanIndex
            while legBudget.isExhausted == false {
                if try runAdaptive(
                    productSpaceAdaptiveEncoder, decoder: prngDecoder,
                    targets: .wholeSequence, structureChanged: true,
                    budget: &legBudget
                ) {
                    accepted += 1
                } else {
                    break
                }
            }
        }

        // Fallback: BindRootSearchEncoder for non-converged axes.
        bindRootSearchEncoder.bindIndex = bindSpanIndex
        while legBudget.isExhausted == false {
            if try runAdaptive(
                bindRootSearchEncoder,
                decoder: prngDecoder,
                targets: .wholeSequence,
                structureChanged: true,
                budget: &legBudget
            ) {
                accepted += 1
            } else {
                break
            }
        }

        // Value encoders on bind-inner spans only (not all depth-0 spans).
        let bindInnerSpans = buildBindInnerValueSpans(bindSpanIndex: bindSpanIndex)
        if bindInnerSpans.isEmpty == false {
            let trainDecoder = makeDepthZeroDecoder()
            for slot in trainOrder {
                guard legBudget.isExhausted == false else { break }
                switch slot {
                case .zeroValue:
                    if try runAdaptive(
                        zeroValueEncoder, decoder: trainDecoder,
                        targets: .spans(bindInnerSpans), structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.zeroValue, in: &trainOrder)
                    }
                case .binarySearchToZero:
                    if try runAdaptive(
                        binarySearchToZeroEncoder, decoder: trainDecoder,
                        targets: .spans(bindInnerSpans), structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToZero, in: &trainOrder)
                    }
                case .binarySearchToTarget:
                    if try runAdaptive(
                        binarySearchToTargetEncoder, decoder: trainDecoder,
                        targets: .spans(bindInnerSpans), structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToTarget, in: &trainOrder)
                    }
                case .reduceFloat:
                    let floatSpans = bindInnerSpans.filter { span in
                        guard let value = sequence[span.range.lowerBound].value else { return false }
                        return value.choice.tag == .double || value.choice.tag == .float
                    }
                    if floatSpans.isEmpty == false {
                        if try runAdaptive(
                            reduceFloatEncoder, decoder: trainDecoder,
                            targets: .spans(floatSpans), structureChanged: true,
                            budget: &legBudget
                        ) {
                            accepted += 1
                            ReductionScheduler.moveToFront(.reduceFloat, in: &trainOrder)
                        }
                    }
                }
            }
        }

        budget -= legBudget.used
        return accepted > 0
    }

    /// Extracts value spans that fall inside bind-inner ranges.
    private func buildBindInnerValueSpans(bindSpanIndex: BindSpanIndex) -> [ChoiceSpan] {
        let allValueSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        return allValueSpans.filter { span in
            bindSpanIndex.regions.contains { region in
                region.innerRange.contains(span.range.lowerBound)
            }
        }
    }
}

// MARK: - Phase 2: Value Minimization

extension ReductionState {
    /// Runs value minimization on DAG leaf positions, with fingerprint boundary guard.
    ///
    /// Returns `true` if any progress was made. If a structural change is detected by the fingerprint guard, returns `true` to signal the outer loop to re-enter Phase 1.
    func runValueMinimization(
        budget: inout Int,
        dag: DependencyDAG?
    ) throws -> Bool {
        let subBudget = min(budget, PrincipledScheduler.phase2Budget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        lattice.invalidate()
        var anyAccepted = false

        // Compute target leaf ranges.
        let leafRanges = computeLeafRanges(dag: dag)

        // Capture skeleton fingerprint before Phase 2 starts.
        let prePhaseFingerprint: SkeletonFingerprint?
        if hasBind, let bindSpanIndex = bindIndex {
            prePhaseFingerprint = SkeletonFingerprint.from(tree, bindIndex: bindSpanIndex)
        } else {
            prePhaseFingerprint = nil
        }

        // Per-leaf-range value minimization pass.
        for leafRange in leafRanges {
            guard legBudget.isExhausted == false else { break }

            let leafSpans = extractValueSpans(in: leafRange)
            guard leafSpans.isEmpty == false else { continue }

            let floatSpans = leafSpans.filter { span in
                guard let value = sequence[span.range.lowerBound].value else { return false }
                return value.choice.tag == .double || value.choice.tag == .float
            }

            // Select decoder based on whether leaf is in a bind-bound subtree.
            let isInBound = bindIndex?.isInBoundSubtree(leafRange.lowerBound) ?? false
            let decoder: SequenceDecoder
            if isInBound {
                decoder = .guided(fallbackTree: fallbackTree ?? tree)
            } else {
                decoder = .exact()
            }

            // Structure change flag: bound leaves may cause structural changes.
            let structureChanged = isInBound && hasBind

            for slot in trainOrder {
                guard legBudget.isExhausted == false else { break }
                switch slot {
                case .zeroValue:
                    if leafSpans.isEmpty == false {
                        if try runAdaptive(
                            zeroValueEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget
                        ) {
                            anyAccepted = true
                            ReductionScheduler.moveToFront(.zeroValue, in: &trainOrder)
                        }
                    }
                case .binarySearchToZero:
                    if leafSpans.isEmpty == false {
                        if try runAdaptive(
                            binarySearchToZeroEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget
                        ) {
                            anyAccepted = true
                            ReductionScheduler.moveToFront(.binarySearchToZero, in: &trainOrder)
                        }
                    }
                case .binarySearchToTarget:
                    if leafSpans.isEmpty == false {
                        if try runAdaptive(
                            binarySearchToTargetEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget
                        ) {
                            anyAccepted = true
                            ReductionScheduler.moveToFront(.binarySearchToTarget, in: &trainOrder)
                        }
                    }
                case .reduceFloat:
                    if floatSpans.isEmpty == false {
                        if try runAdaptive(
                            reduceFloatEncoder, decoder: decoder,
                            targets: .spans(floatSpans), structureChanged: structureChanged,
                            budget: &legBudget
                        ) {
                            anyAccepted = true
                            ReductionScheduler.moveToFront(.reduceFloat, in: &trainOrder)
                        }
                    }
                }
            }

            // Fingerprint boundary guard: check if a structural change occurred.
            if isInBound, let preFingerprint = prePhaseFingerprint, hasBind,
               let currentBindIndex = bindIndex
            {
                // Skip check for structurally constant binds.
                let isConstant = dag?.nodes.contains { node in
                    if case let .structural(.bindInner(regionIndex: regionIndex)) = node.kind,
                       regionIndex < currentBindIndex.regions.count,
                       currentBindIndex.regions[regionIndex].boundRange.contains(leafRange.lowerBound)
                    {
                        return node.isStructurallyConstant
                    }
                    return false
                } ?? false

                if isConstant == false {
                    let currentFingerprint = SkeletonFingerprint.from(tree, bindIndex: currentBindIndex)
                    if currentFingerprint != preFingerprint {
                        // Structural change detected. Keep accepted probes, signal Phase 1 re-entry.
                        budget -= legBudget.used
                        return true
                    }
                }
            }
        }

        // Redistribution (once at end of Phase 2).
        if legBudget.isExhausted == false {
            let redistContext = DecoderContext(
                depth: .global,
                bindIndex: bindIndex,
                fallbackTree: fallbackTree,
                strictness: .normal,
                useReductionMaterializer: config.useReductionMaterializer
            )
            let redistDecoder = SequenceDecoder.for(redistContext)

            // Tandem reduction on sibling groups.
            let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
            if allSiblings.isEmpty == false {
                if try runAdaptive(
                    tandemEncoder, decoder: redistDecoder,
                    targets: .siblingGroups(allSiblings),
                    structureChanged: hasBind, budget: &legBudget
                ) {
                    anyAccepted = true
                }
            }

            // Cross-stage redistribution.
            if try runAdaptive(
                redistributeEncoder, decoder: redistDecoder,
                targets: .wholeSequence,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }

            // Bind-aware redistribution.
            if hasBind, let bindSpanIndex = bindIndex, bindSpanIndex.regions.count >= 2 {
                let regionPairs = BindAwareRedistributeEncoder.buildPlans(
                    from: sequence, bindIndex: bindSpanIndex
                )
                for plan in regionPairs {
                    guard legBudget.isExhausted == false else { break }
                    let sinkRegionIndex = plan.sink.regionIndex
                    let bindRedistDecoder: SequenceDecoder = .guided(
                        fallbackTree: fallbackTree ?? tree,
                        maximizeBoundRegionIndices: Set([sinkRegionIndex])
                    )
                    bindAwareRedistributeEncoder.startPlan(sequence: sequence, plan: plan)
                    var lastAccepted = false
                    while let probe = bindAwareRedistributeEncoder.nextProbe(lastAccepted: lastAccepted) {
                        guard legBudget.isExhausted == false else { break }
                        if let result = try bindRedistDecoder.decode(
                            candidate: probe, gen: gen, tree: tree,
                            originalSequence: sequence, property: property
                        ) {
                            legBudget.recordMaterialization()
                            accept(result, structureChanged: true)
                            lastAccepted = true
                            anyAccepted = true
                        } else {
                            legBudget.recordMaterialization()
                            lastAccepted = false
                        }
                    }
                }
            }
        }

        budget -= legBudget.used
        return anyAccepted
    }
}

// MARK: - Helpers

extension ReductionState {
    /// Computes ordered leaf ranges for Phase 2.
    ///
    /// Uses DAG leaf positions when available. For bind-free generators, uses all value spans at depth 0. Leaves inside bind-bound subtrees are ordered first (structural proximity ordering).
    func computeLeafRanges(dag: DependencyDAG?) -> [ClosedRange<Int>] {
        if let dag {
            // Sort: leaves inside bind-bound subtrees first, then by position ascending.
            return dag.leafPositions.sorted { lhs, rhs in
                let lhsInBound = bindIndex?.isInBoundSubtree(lhs.lowerBound) ?? false
                let rhsInBound = bindIndex?.isInBoundSubtree(rhs.lowerBound) ?? false
                if lhsInBound != rhsInBound {
                    return lhsInBound
                }
                return lhs.lowerBound < rhs.lowerBound
            }
        }

        // Bind-free: all value spans at depth 0 as a single contiguous range.
        let valueSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        guard valueSpans.isEmpty == false else { return [] }
        let minPosition = valueSpans.map(\.range.lowerBound).min()!
        let maxPosition = valueSpans.map(\.range.upperBound).max()!
        return [minPosition ... maxPosition]
    }

    /// Extracts value spans within the given position range.
    private func extractValueSpans(in range: ClosedRange<Int>) -> [ChoiceSpan] {
        let allSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        return allSpans.filter { range.contains($0.range.lowerBound) }
    }
}
