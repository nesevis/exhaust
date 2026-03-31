//
//  ReductionState+BaseDescent.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Base Descent

//
// Extends ReductionState with the base descent phase of BonsaiScheduler's alternating minimization.
// Base descent (ramification) minimises the trace structure — the base of the fibration —
// via branch simplification, structural deletion, and bind-inner reduction.

extension ReductionState {
    /// Base descent: minimises the trace structure (the base of the fibration) with restart-on-success.
    ///
    /// Categorically, this is the cartesian factor of the cartesian-vertical factorisation — every accepted candidate changes the base point. In Bonsai terms, it develops the tree's fine branch structure: simplifying branches, removing unnecessary spans, and reducing the controlling values that shape downstream growth. In plain language, it makes the failing test case structurally simpler — fewer choices, simpler branching, shorter sequences — restarting from the top whenever it finds an improvement.
    ///
    /// Branch simplification and bind-inner reduction restart from the top on success. Structural deletion loops internally until exhausted. Returns the final dependency graph and whether any progress was made.
    func runBaseDescent(
        budget: inout Int,
        cycle: Int = 0,
        scopeRange: ClosedRange<Int>? = nil
    ) throws -> (dag: ChoiceDependencyGraph?, progress: Bool) {
        phaseTracker.push(.baseDescent)
        defer { phaseTracker.pop() }

        var anyProgress = false

        while budget > 0 {
            // Branch simplification.
            if try runBranchSimplification(budget: &budget, scopeRange: scopeRange) {
                anyProgress = true
                continue // Restart from 1a.
            }

            // Structural deletion (inner loop: restart on success).
            var deletionMadeProgress = false
            while budget > 0 {
                let dag = rebuildDAGIfNeeded()
                if try runStructuralDeletion(budget: &budget, dag: dag, scopeRange: scopeRange) {
                    deletionMadeProgress = true
                    anyProgress = true
                } else {
                    break
                }
            }

            // Joint bind-inner reduction.
            if try runJointBindInnerReduction(budget: &budget, cycle: cycle, scopeRange: scopeRange) {
                anyProgress = true
                continue // Restart from 1a.
            }

            // If 1b made progress, restart from 1a (structural changes may enable branch simplification).
            if deletionMadeProgress {
                continue
            }

            // No step made progress; base descent fixed point reached.
            break
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bonsai_phase1_complete",
                metadata: [
                    "progress": "\(anyProgress)",
                    "budget_remaining": "\(budget)",
                ]
            )
        }

        let finalDAG = rebuildDAGIfNeeded()
        return (finalDAG, anyProgress)
    }

    /// Rebuilds the ``ChoiceDependencyGraph`` from the current sequence, tree, and bind index.
    ///
    /// Returns a DAG for bind generators and for bind-free generators that contain picks. Returns `nil` only when neither binds nor picks are present.
    /// Builds a CDG from the current sequence and tree, or returns nil if neither binds nor picks are present.
    func buildDAG() -> ChoiceDependencyGraph? {
        rebuildDAGIfNeeded()
    }

    private func rebuildDAGIfNeeded() -> ChoiceDependencyGraph? {
        if hasBind, let bindSpanIndex = bindIndex {
            return ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindSpanIndex)
        }
        guard tree.containsPicks else { return nil }
        // Bind-free but has picks: build DAG with an empty bind index so branch nodes are still captured.
        return ChoiceDependencyGraph.build(
            from: sequence,
            tree: tree,
            bindIndex: BindSpanIndex(from: sequence)
        )
    }

    // MARK: - Branch Simplification

    /// Runs branch promotion and pivoting encoders.
    private func runBranchSimplification(budget: inout Int, scopeRange: ClosedRange<Int>? = nil) throws -> Bool {
        let subBudget = min(budget, config.branchSimplificationBudget)
        guard subBudget > 0 else { return false }

        // Guided decoder: conditional cursor suspension (inner-value comparison)
        // keeps the cursor active when the bind-inner is unchanged, so pick
        // changes inside bind content are visible in a single pass.
        let branchDecoder: SequenceDecoder = .guided(
            fallbackTree: fallbackTree, materializePicks: true
        )
        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        var improved = false

        // Re-materialize with picks so branch encoders see all non-selected alternatives.
        // Skip if the tree is already up to date (no acceptance since last materialization).
        if branchTreeDirty {
            if case let .success(_, freshTree, _) = ReductionMaterializer.materialize(
                gen, prefix: sequence, mode: .exact, fallbackTree: fallbackTree,
                materializePicks: true
            ) {
                tree = freshTree
            }
            branchTreeDirty = false
        }

        let branchReductionContext = ReductionContext(bindIndex: bindIndex)
        let fullBranchRange = scopeRange ?? (0 ... max(0, sequence.count - 1))
        if try runComposable(
            promoteDirectDescendantEncoder,
            decoder: branchDecoder,
            positionRange: fullBranchRange,
            context: branchReductionContext,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "branch_promote_direct"])
            }
        }

        if try runComposable(
            promoteBranchesEncoder,
            decoder: branchDecoder,
            positionRange: fullBranchRange,
            context: branchReductionContext,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "branch_promote"])
            }
        }

        if try runComposable(
            pivotBranchesEncoder,
            decoder: branchDecoder,
            positionRange: fullBranchRange,
            context: branchReductionContext,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "branch_pivot"])
            }
        }

        if try runComposable(
            swapSiblingsEncoder,
            decoder: branchDecoder,
            positionRange: fullBranchRange,
            context: branchReductionContext,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "sibling_swap"])
            }
        }

        // Bind substitution: replace a bind region with a deeper descendant's
        // content. Uses exact decoding because the inner value changes.
        if try runComposable(
            bindSubstitutionEncoder,
            decoder: .exact(),
            positionRange: fullBranchRange,
            context: branchReductionContext,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "bind_substitution"])
            }
        }

        budget -= legBudget.used
        return improved
    }

    // MARK: - Structural Deletion (covariant — roots first)

    /// Runs deletion encoders in DAG topological order.
    ///
    /// Returns `true` on first acceptance (caller loops internally to chain further deletions). For bind generators, iterates structural nodes in topological order (roots first), then depth-0 content outside any bind. For bind-free generators, falls back to depth-0 only.
    private func runStructuralDeletion(
        budget: inout Int,
        dag: ChoiceDependencyGraph?,
        scopeRange: ClosedRange<Int>? = nil
    ) throws -> Bool {
        let subBudget = min(budget, config.structuralDeletionBudget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()

        let allScopes = buildDeletionScopes(dag: dag)
        // When scoped to a level, filter to deletion scopes that overlap the scope range.
        let scopes = scopeRange.map { range in
            allScopes.filter { scope in
                scope.positionRange.map { $0.overlaps(range) } ?? true
            }
        } ?? allScopes

        for scope in scopes {
            guard legBudget.isExhausted == false else { break }
            dominance.invalidate()
            let scopeDecoder = makeDeletionDecoder(at: scope.depth)

            // Structural deletion uses per-encoder calls with restart-on-acceptance.
            // Deletions change sequence length, invalidating span positions for remaining
            // encoders. A descriptor chain would process stale spans — per-encoder restart
            // ensures each encoder gets fresh spans.
            let deletionContext = ReductionContext(bindIndex: bindIndex)
            let fullRange = scopeRange ?? (0 ... max(0, sequence.count - 1))

            for slot in pruneOrder {
                guard legBudget.isExhausted == false else { break }
                let targets = scope.positionRange.map { positionRange in
                    spanCache.deletionTargets(
                        category: slot.spanCategory,
                        inRange: positionRange,
                        from: sequence
                    )
                } ?? spanCache.deletionTargets(
                    category: slot.spanCategory,
                    depth: scope.depth,
                    from: sequence,
                    bindIndex: bindIndex
                )
                var slotAccepted = false
                if slot == .alignedWindows {
                    // Contiguous window search dominates beam search.
                    // Both self-extract sibling groups — don't skip on empty container spans.
                    // Pre-compute cohorts once via SpanCache so both encoders share
                    // the O(n) sibling group extraction and cohort construction.
                    let sharedCohorts = spanCache.alignedDeletionCohorts(from: sequence)
                    guard sharedCohorts.isEmpty == false else { continue }
                    contiguousWindowEncoder.precomputedCohorts = sharedCohorts
                    beamSearchEncoder.precomputedCohorts = sharedCohorts
                    if try runComposable(
                        contiguousWindowEncoder,
                        decoder: scopeDecoder,
                        positionRange: fullRange,
                        context: deletionContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        slotAccepted = true
                    }
                    // Beam search: non-contiguous subset deletion via bitmask
                    // enumeration. Skip for small bind-free sequences where
                    // contiguous window + adaptive deletion already cover the
                    // search space. Bind generators need beam search even at
                    // small sizes because non-contiguous element deletions
                    // within bound regions enable bind-inner reduction.
                    if sequence.count >= 30 {
                        if try runComposable(
                            beamSearchEncoder,
                            decoder: scopeDecoder,
                            positionRange: fullRange,
                            context: deletionContext,
                            structureChanged: true,
                            budget: &legBudget
                        ) {
                            slotAccepted = true
                        }
                    }
                } else {
                    guard targets.isEmpty == false else { continue }
                    let decoder = slot == .randomRepairDelete
                        ? makeSpeculativeDecoder()
                        : scopeDecoder
                    let category = slot.spanCategory
                    var deletionEncoder = DeletionEncoder(spanCategory: category, spans: targets)
                    // For sequence element deletion inside bind-controlled regions,
                    // also decrement the bind-inner value so the candidate has a
                    // consistent (shorter) structure that the exact decoder accepts.
                    if category == .sequenceElements {
                        deletionEncoder.bindInnerValueIndex = scope.bindInnerValueIndex
                    }
                    if try runComposable(
                        deletionEncoder,
                        decoder: decoder,
                        positionRange: fullRange,
                        context: deletionContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        slotAccepted = true
                    }
                }
                if slotAccepted {
                    ReductionScheduler.moveToFront(slot, in: &pruneOrder)
                    if isInstrumented {
                        ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                         metadata: ["subphase": "deletion", "slot": "\(slot)"])
                    }
                    budget -= legBudget.used
                    return true
                }
            }
        }

        // MARK: - Antichain composition (k-way pushout law)

        // k independent batches that are each rejected individually may be jointly
        // accepted (property still fails when all k are deleted). The antichain of the CDG
        // identifies the maximum set of structurally independent nodes; delta-debugging over this
        // set finds the largest jointly-deletable subset.
        //
        // Unlike the MutationPool fallback, this operates on CDG nodes directly and is not gated
        // on sequence length — the cost depends on the number of CDG nodes (typically < 20).
        //
        // Track materializations from mutation pool below — it bypasses runComposable
        // and needs manual accumulation into totalMaterializations.
        let budgetBeforeDirectDecodes = legBudget.used

        if let dag {
            let antichainNodes = dag.maximalAntichain()
            if antichainNodes.count > 2 {
                let rawCandidates = collectAntichainCandidates(
                    antichainNodes: antichainNodes,
                    dag: dag
                )
                if rawCandidates.count > 2 {
                    antichainDeletionEncoder.setCandidates(
                        rawCandidates.map { AntichainDeletionEncoder.Candidate(
                            nodeIndex: $0.nodeIndex,
                            spans: $0.spans,
                            deletedLength: $0.deletedLength
                        ) }
                    )
                    let speculativeDecoder = makeSpeculativeDecoder()
                    if try runComposable(
                        antichainDeletionEncoder,
                        decoder: speculativeDecoder,
                        positionRange: 0 ... max(0, sequence.count - 1),
                        context: ReductionContext(),
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        budget -= legBudget.used
                        return true
                    }
                }
            }
        }

        // MARK: - Mutation pool fallback (pair enumeration)

        // Fall back to pairwise composition for spans with dependency edges or when the antichain
        // is too small for delta-debugging to outperform pair testing.
        // Capped at sequence.count <= 500 to bound span-cache traversal cost.
        if sequence.count <= 500 {
            let individuals = MutationPool.collect(
                sequence: sequence,
                spanCache: &spanCache,
                scopes: scopes,
                slots: pruneOrder,
                bindIndex: bindIndex
            )
            if individuals.isEmpty == false {
                let pairs = MutationPool.composePairs(
                    from: individuals,
                    sequence: sequence
                )
                var combined = individuals + pairs
                combined.sort { $0.deletedLength > $1.deletedLength }
                let poolEncoder = PrecomputedComposableEncoder(
                    name: .productSpaceAdaptive,
                    phase: .structuralDeletion,
                    candidates: combined.map(\.candidate)
                )
                if try runComposable(
                    poolEncoder,
                    decoder: makeSpeculativeDecoder(),
                    positionRange: 0 ... max(0, sequence.count - 1),
                    context: ReductionContext(),
                    structureChanged: true,
                    budget: &legBudget
                ) {
                    budget -= legBudget.used
                    return true
                }
            }
        }

        budget -= legBudget.used
        return false
    }

    // MARK: - Joint Bind-Inner Reduction

    /// Runs product-space encoders and value encoders on bind-inner values.
    private func runJointBindInnerReduction(budget: inout Int, cycle: Int = 0, scopeRange: ClosedRange<Int>? = nil) throws -> Bool {
        guard hasBind, let bindSpanIndex = bindIndex else { return false }
        let subBudget = min(budget, config.bindInnerReductionBudget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()
        var accepted = 0

        let bindInnerCount = bindSpanIndex.regions.count

        if bindInnerCount <= 3 {
            // Batch: enumerate product space of bind-inner values.
            // Three-descriptor dominance chain replaces the hand-coded multi-tier orchestration:
            //   Tier 1 (guided) → Regime probe → Tier 2 (PRNG retries)
            let bindDag = ChoiceDependencyGraph.build(
                from: sequence, tree: tree, bindIndex: bindSpanIndex
            )
            productSpaceBatchEncoder.bindIndex = bindSpanIndex
            productSpaceBatchEncoder.dag = bindDag
            productSpaceBatchEncoder.dependentDomains = computeDependentDomains(
                bindSpanIndex: bindSpanIndex, dag: bindDag
            )

            let allCandidates = Array(productSpaceBatchEncoder.encode(
                sequence: sequence, targets: .wholeSequence
            ))
            let tier2Candidates = sortByLargestFibreFirst(
                allCandidates, bindIndex: bindSpanIndex
            )

            let chainContext = ReductionContext(bindIndex: bindSpanIndex, dag: bindDag)
            let fullRange = scopeRange ?? (0 ... max(0, sequence.count - 1))
            let guidedDecoder: SequenceDecoder = .guided(fallbackTree: fallbackTree ?? tree)

            // Tier 1: guided — all candidates.
            let tier1Accepted = try runComposable(
                PrecomputedComposableEncoder(
                    name: .productSpaceBatch, phase: .valueMinimization,
                    candidates: allCandidates
                ),
                decoder: guidedDecoder, positionRange: fullRange,
                context: chainContext, structureChanged: true, budget: &legBudget
            )
            if tier1Accepted {
                accepted += 1
            } else {
                // Regime probe: exact decoder, single probe.
                let regimeAccepted = try runComposable(
                    RegimeProbeEncoder(), decoder: .exact(),
                    positionRange: fullRange, context: chainContext,
                    structureChanged: true, budget: &legBudget
                )
                if regimeAccepted {
                    accepted += 1
                } else {
                    // Tier 2: PRNG retries with largest-fibre-first ordering.
                    let saltBase = UInt64(cycle * 4)
                    for retry in 0 ..< 4 {
                        guard legBudget.isExhausted == false else { break }
                        let prngDecoder: SequenceDecoder = .guided(
                            fallbackTree: nil, usePRNGFallback: true,
                            prngSalt: saltBase &+ UInt64(retry)
                        )
                        if try runComposable(
                            PrecomputedComposableEncoder(
                                name: .productSpaceBatch, phase: .valueMinimization,
                                candidates: tier2Candidates
                            ),
                            decoder: prngDecoder, positionRange: fullRange,
                            context: chainContext, structureChanged: true, budget: &legBudget
                        ) {
                            accepted += 1
                            break
                        }
                    }
                }
            }
        } else {
            // Adaptive: delta-debug coordinate halving for k > 3.
            let adaptivePRNGDecoder: SequenceDecoder = .guided(
                fallbackTree: nil, usePRNGFallback: true,
                prngSalt: UInt64(cycle)
            )
            let adaptiveContext = ReductionContext(bindIndex: bindSpanIndex)
            while legBudget.isExhausted == false {
                if try runComposable(
                    productSpaceAdaptiveEncoder, decoder: adaptivePRNGDecoder,
                    positionRange: scopeRange ?? (0 ... max(0, sequence.count - 1)),
                    context: adaptiveContext,
                    structureChanged: true,
                    budget: &legBudget
                ) {
                    accepted += 1
                } else {
                    break
                }
            }
        }

        // Re-read bindIndex — product-space acceptances may have changed the sequence structure.
        guard let currentBindSpanIndex = bindIndex else {
            budget -= legBudget.used
            return accepted > 0
        }

        // Value encoders on bind-inner spans only (not all depth-0 spans).
        let bindInnerSpans = buildBindInnerValueSpans(bindSpanIndex: currentBindSpanIndex)
        if bindInnerSpans.isEmpty == false {
            let trainDecoder = makeDepthZeroDecoder()
            // Compute bounding range for bind-inner positions.
            let innerMin = bindInnerSpans.map(\.range.lowerBound).min()!
            let innerMax = bindInnerSpans.map(\.range.upperBound).max()!
            let bindInnerRange = innerMin ... innerMax
            // No depth filter — bind-inner positions are explicitly scoped by buildBindInnerValueSpans.
            // The encoder sees all value spans in the bounding range; bind-inner positions are a subset.
            // This is slightly broader than the pre-extracted spans but acceptable — extra spans
            // are non-bind-inner values that the encoder will attempt to reduce (harmless, same decoder).
            let bindInnerContext = ReductionContext(
                bindIndex: bindIndex
            )
            for slot in trainOrder {
                guard legBudget.isExhausted == false else { break }
                switch slot {
                case .zeroValue:
                    if try runComposable(
                        zeroValueEncoder, decoder: trainDecoder,
                        positionRange: bindInnerRange, context: bindInnerContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.zeroValue, in: &trainOrder)
                    }
                case .binarySearchToZero:
                    if try runComposable(
                        binarySearchToZeroEncoder, decoder: trainDecoder,
                        positionRange: bindInnerRange, context: bindInnerContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToZero, in: &trainOrder)
                    }
                case .binarySearchToTarget:
                    if try runComposable(
                        binarySearchToTargetEncoder, decoder: trainDecoder,
                        positionRange: bindInnerRange, context: bindInnerContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToTarget, in: &trainOrder)
                    }
                case .reduceFloat:
                    if try runComposable(
                        reduceFloatEncoder, decoder: trainDecoder,
                        positionRange: bindInnerRange, context: bindInnerContext,
                        structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.reduceFloat, in: &trainOrder)
                    }
                }
            }
        }

        if accepted > 0, isInstrumented {
            ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                             metadata: ["subphase": "bind_inner", "accepted": "\(accepted)"])
        }

        budget -= legBudget.used
        return accepted > 0
    }

    /// Extracts value spans that fall inside bind-inner ranges.
    private func buildBindInnerValueSpans(bindSpanIndex: BindSpanIndex) -> [ChoiceSpan] {
        let allValueSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        var inBindInner = [Bool](repeating: false, count: sequence.count)
        for region in bindSpanIndex.regions {
            for i in region.innerRange {
                inBindInner[i] = true
            }
        }
        return allValueSpans.filter { inBindInner[$0.range.lowerBound] }
    }
}

// MARK: - Helpers

extension ReductionState {
    /// Discovers downstream axis domains for dependent bind-inner axes via lightweight replay.
    ///
    /// For each dependency edge (upstream → downstream) in the DAG, replays the generator with each upstream ladder value to discover the downstream axis's valid range at that upstream value. Returns a mapping from downstream region index to per-upstream-value domain ranges.
    ///
    /// - Note: For multi-hop chains (A → B → C), C's domains are discovered at the current A value. When the product space tests a candidate A value, C's domains may be stale because B's domain shifted under the new A. This means valid (a, b, c) tuples can be missed, but invalid tuples are still rejected at evaluation time. The fix would be, for each candidate `a'` in A's ladder, to replay once to get B's domain at `a'`, then for each `b'` in that domain replay again to get C's domain — O(s_A × s_B) replays instead of the current O(s_A + s_B). With typical ladder sizes of 6–15 values that is roughly 48–225 replays versus 12–30. The scenario requires three nested data-dependent (non-`getSize`) binds where each inner value determines the valid range of the next, which is uncommon in practice. Additionally, tier 2's salted PRNG retries do not use `dependentDomains` at all and provide probabilistic coverage of tuples tier 1 misses. The approximation is only load-bearing when the minimal tuple sits inside a narrow C domain that only opens at a specific `(a', b')` pair and tier 2 fails to land on it within budget — a combination unlikely enough that the extra replay cost is not currently justified.
    private func computeDependentDomains(
        bindSpanIndex: BindSpanIndex,
        dag: ChoiceDependencyGraph
    ) -> [Int: [UInt64: ClosedRange<UInt64>]]? {
        let topology = dag.bindInnerTopology()

        // Quick check: any dependencies at all?
        guard topology.contains(where: { $0.dependsOn.isEmpty == false }) else {
            return nil
        }

        let axes = extractAxes(from: sequence, bindIndex: bindSpanIndex)
        guard axes.isEmpty == false else { return nil }

        var regionToAxis = [Int: Int]()
        for (axisIndex, axis) in axes.enumerated() {
            regionToAxis[axis.regionIndex] = axisIndex
        }

        var result = [Int: [UInt64: ClosedRange<UInt64>]]()

        for entry in topology where entry.dependsOn.isEmpty == false {
            guard let upstreamAxisIndex = regionToAxis[entry.regionIndex] else {
                continue
            }
            let upstreamAxis = axes[upstreamAxisIndex]
            let upstreamLadder = BinarySearchLadder.compute(
                current: upstreamAxis.currentBitPattern,
                target: upstreamAxis.targetBitPattern
            )

            for dependentNodeIndex in entry.dependsOn {
                let nodeKind = dag.nodes[dependentNodeIndex].kind
                guard case let .structural(
                    .bindInner(regionIndex: downstreamRegion)
                ) = nodeKind else {
                    continue
                }

                var domainMap = [UInt64: ClosedRange<UInt64>]()

                // Include the current value's domain (known from the existing sequence).
                if let downstreamAxisIndex = regionToAxis[downstreamRegion] {
                    let downstreamAxis = axes[downstreamAxisIndex]
                    if let validRange = downstreamAxis.validRange {
                        domainMap[upstreamAxis.currentBitPattern] = validRange
                    }
                }

                for value in upstreamLadder.values {
                    if value == upstreamAxis.currentBitPattern { continue }

                    // Ladder values are shortlex keys — convert to bit patterns for materialization.
                    let probeChoice = ChoiceValue.fromShortlexKey(
                        value, tag: upstreamAxis.choiceTag
                    )

                    // Create modified sequence with upstream set to candidate value.
                    var modified = sequence
                    modified[upstreamAxis.seqIdx] = .value(.init(
                        choice: probeChoice,
                        validRange: upstreamAxis.validRange,
                        isRangeExplicit: upstreamAxis.isRangeExplicit
                    ))

                    // Lightweight replay to discover downstream domain.
                    // These materializations are not budgeted — they are structural
                    // discovery, not candidate evaluation. Tracked for profiling visibility.
                    phaseTracker.recordInvocation()
                    let replayResult = ReductionMaterializer.materialize(
                        gen, prefix: modified, mode: .exact, fallbackTree: tree
                    )

                    if case let .success(_, freshTree, _) = replayResult {
                        let freshSequence = ChoiceSequence(freshTree)
                        let freshBindIndex = BindSpanIndex(from: freshSequence)

                        // Find the downstream axis in the fresh sequence by region index.
                        // This assumes region indices are positionally stable across upstream value changes.
                        // If the upstream's continuation conditionally constructs generators with different bind topologies (for example, 2 nested binds for n=10 vs 0 for n=3), region indices can shift and we may read the wrong domain.
                        // This is not a soundness issue — the materializer validates all candidates at evaluation time — but it can produce suboptimal ladders.
                        // A structural-path-based matching scheme would fix this but is not worth the complexity for this rare generator shape.
                        if downstreamRegion < freshBindIndex.regions.count {
                            let freshRegion = freshBindIndex.regions[downstreamRegion]
                            for index in freshRegion.innerRange where index < freshSequence.count {
                                if let freshValue = freshSequence[index].value {
                                    if let range = freshValue.validRange {
                                        domainMap[value] = range
                                    }
                                    break
                                }
                            }
                        }
                        // If region doesn't exist for this upstream value, no entry is added.
                        // The encoder will skip this (upstream, downstream) combination.
                    }
                }

                if domainMap.isEmpty == false {
                    result[downstreamRegion] = domainMap
                }
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Builds ordered deletion scopes for structural deletion within base descent.
    ///
    /// Iterates structural nodes in topological order (roots first). Bind-inner nodes scope deletion to their bound range; branch-selector nodes scope deletion to the selected subtree. A final depth-0 scope handles content outside all structural nodes. Returns a single depth-0 scope when no DAG is available.
    private func buildDeletionScopes(dag: ChoiceDependencyGraph?) -> [DeletionScope] {
        guard let dag else {
            return [DeletionScope(positionRange: nil, depth: 0)]
        }

        var scopes = [DeletionScope]()

        for nodeIndex in dag.topologicalOrder {
            let node = dag.nodes[nodeIndex]
            switch node.kind {
            case let .structural(.bindInner(regionIndex: regionIndex)):
                guard let bindSpanIndex = bindIndex,
                      regionIndex < bindSpanIndex.regions.count else { continue }
                let region = bindSpanIndex.regions[regionIndex]
                let boundRange = region.boundRange
                let boundDepth = bindSpanIndex.bindDepth(at: boundRange.lowerBound)
                // Find the value entry in the inner range that controls the bound sequence length.
                var innerValueIndex: Int?
                for index in region.innerRange where sequence[index].value != nil {
                    innerValueIndex = index
                    break
                }
                scopes.append(DeletionScope(
                    positionRange: boundRange,
                    depth: boundDepth,
                    bindInnerValueIndex: innerValueIndex
                ))
            case .structural(.branchSelector):
                guard let subtreeRange = node.scopeRange else { continue }
                let depth = bindIndex?.bindDepth(at: subtreeRange.lowerBound) ?? 0
                scopes.append(DeletionScope(positionRange: subtreeRange, depth: depth))
            default:
                continue
            }
        }

        // Depth-0 content outside all structural nodes.
        // Only append if there are leaf positions at depth 0 not already covered
        // by position-ranged scopes from DAG nodes.
        let hasUncoveredDepthZeroContent = dag.leafPositions.contains { leafRange in
            bindIndex?.bindDepth(at: leafRange.lowerBound) == 0 || bindIndex == nil
        }
        if hasUncoveredDepthZeroContent {
            scopes.append(DeletionScope(positionRange: nil, depth: 0))
        }

        return scopes
    }
}

// MARK: - Deletion Scope

/// A scoped region for structural deletion within base descent.
///
/// When ``positionRange`` is set, deletion targets are filtered by position range (DAG-driven). When `nil`, targets are filtered by bind depth (bind-free fallback).
struct DeletionScope {
    /// The position range to scope deletion targets to, or `nil` for depth-based filtering.
    let positionRange: ClosedRange<Int>?

    /// The bind depth for decoder selection.
    let depth: Int

    /// Sequence index of the bind-inner value that controls the sequence length within this scope.
    /// Set for bind-inner scopes where the inner value determines the bound sequence length.
    let bindInnerValueIndex: Int?

    init(positionRange: ClosedRange<Int>?, depth: Int, bindInnerValueIndex: Int? = nil) {
        self.positionRange = positionRange
        self.depth = depth
        self.bindInnerValueIndex = bindInnerValueIndex
    }
}
