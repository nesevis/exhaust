// MARK: - Base Descent and Fibre Descent

//
// Extends ReductionState with the two phases of BonsaiScheduler's alternating minimization.
// Base descent (ramification) minimises the trace structure — the base of the fibration —
// via branch simplification, structural deletion, and bind-inner reduction.
// Fibre descent (foliage) minimises the value assignment within a fixed trace structure —
// the fibre above the current base point — via DAG-guided coordinate descent.

/// Maximum remaining range size for which ``LinearScanEncoder`` is emitted.
let linearScanThreshold = 64

extension ReductionState {
    /// Base descent: minimises the trace structure (the base of the fibration) with restart-on-success.
    ///
    /// Categorically, this is the cartesian factor of the cartesian-vertical factorisation — every accepted candidate changes the base point. In Bonsai terms, it develops the tree's fine branch structure: simplifying branches, removing unnecessary spans, and reducing the controlling values that shape downstream growth. In plain language, it makes the failing test case structurally simpler — fewer choices, simpler branching, shorter sequences — restarting from the top whenever it finds an improvement.
    ///
    /// Branch simplification and bind-inner reduction restart from the top on success. Structural deletion loops internally until exhausted. Returns the final dependency graph and whether any progress was made.
    func runBaseDescent(
        budget: inout Int,
        cycle: Int = 0
    ) throws -> (dag: ChoiceDependencyGraph?, progress: Bool) {
        phaseTracker.push(.baseDescent)
        defer { phaseTracker.pop() }
        var anyProgress = false

        while budget > 0 {
            // Branch simplification.
            if try runBranchSimplification(budget: &budget) {
                anyProgress = true
                continue // Restart from 1a.
            }

            // Structural deletion (inner loop: restart on success).
            var deletionMadeProgress = false
            while budget > 0 {
                let dag = rebuildDAGIfNeeded()
                if try runStructuralDeletion(budget: &budget, dag: dag) {
                    deletionMadeProgress = true
                    anyProgress = true
                } else {
                    break
                }
            }

            // Joint bind-inner reduction.
            if try runJointBindInnerReduction(budget: &budget, cycle: cycle) {
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
    private func runBranchSimplification(budget: inout Int) throws -> Bool {
        let subBudget = min(budget, config.branchSimplificationBudget)
        guard subBudget > 0 else { return false }

        let branchContext = DecoderContext(
            depth: .specific(0),
            bindIndex: bindIndex,
            fallbackTree: fallbackTree,
            strictness: .relaxed,
            materializePicks: true
        )
        let branchDecoder = SequenceDecoder.for(branchContext)
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
        let fullBranchRange = 0 ... max(0, sequence.count - 1)
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

        budget -= legBudget.used
        return improved
    }

    // MARK: - Structural Deletion (covariant — roots first)

    /// Runs deletion encoders in DAG topological order.
    ///
    /// Returns `true` on first acceptance (caller loops internally to chain further deletions). For bind generators, iterates structural nodes in topological order (roots first), then depth-0 content outside any bind. For bind-free generators, falls back to depth-0 only.
    private func runStructuralDeletion(
        budget: inout Int,
        dag: ChoiceDependencyGraph?
    ) throws -> Bool {
        let subBudget = min(budget, config.structuralDeletionBudget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()

        let scopes = buildDeletionScopes(dag: dag)

        for scope in scopes {
            guard legBudget.isExhausted == false else { break }
            dominance.invalidate()
            let scopeDecoder = makeDeletionDecoder(at: scope.depth)

            // Structural deletion uses per-encoder calls with restart-on-acceptance.
            // Deletions change sequence length, invalidating span positions for remaining
            // encoders. A descriptor chain would process stale spans — per-encoder restart
            // ensures each encoder gets fresh spans.
            let deletionContext = ReductionContext(bindIndex: bindIndex)
            let fullRange = 0 ... max(0, sequence.count - 1)

            for slot in pruneOrder {
                guard legBudget.isExhausted == false else { break }
                let targets: [ChoiceSpan] = if let positionRange = scope.positionRange {
                    spanCache.deletionTargets(
                        category: slot.spanCategory,
                        inRange: positionRange,
                        from: sequence
                    )
                } else {
                    spanCache.deletionTargets(
                        category: slot.spanCategory,
                        depth: scope.depth,
                        from: sequence,
                        bindIndex: bindIndex
                    )
                }
                let slotAccepted: Bool
                if slot == .alignedWindows {
                    // Contiguous window search dominates beam search.
                    // Both self-extract sibling groups — don't skip on empty container spans.
                    let contiguousAccepted = try runComposable(
                        contiguousWindowEncoder,
                        decoder: scopeDecoder,
                        positionRange: fullRange,
                        context: deletionContext,
                        structureChanged: true,
                        budget: &legBudget
                    )
                    if contiguousAccepted {
                        slotAccepted = true
                    } else {
                        // Contiguous exhausted — try beam search fallback.
                        slotAccepted = try runComposable(
                            beamSearchEncoder,
                            decoder: scopeDecoder,
                            positionRange: fullRange,
                            context: deletionContext,
                            structureChanged: true,
                            budget: &legBudget
                        )
                    }
                } else {
                    guard targets.isEmpty == false else { continue }
                    let decoder = slot == .randomRepairDelete
                        ? makeSpeculativeDecoder()
                        : scopeDecoder
                    let category = slot.spanCategory
                    slotAccepted = try runComposable(
                        DeletionEncoder(spanCategory: category, spans: targets),
                        decoder: decoder,
                        positionRange: fullRange,
                        context: deletionContext,
                        structureChanged: true,
                        budget: &legBudget
                    )
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

        // The sequential adaptive loop above finds the largest individually-accepted batch per
        // Track materializations from antichain composition and mutation pool.
        // These bypass runComposable and need manual accumulation into totalMaterializations.
        let budgetBeforeDirectDecodes = legBudget.used

        // scope and slot. k independent batches that are each rejected individually may be jointly
        // accepted (property still fails when all k are deleted). The antichain of the CDG
        // identifies the maximum set of structurally independent nodes; delta-debugging over this
        // set finds the largest jointly-deletable subset.
        //
        // Unlike the MutationPool fallback, this operates on CDG nodes directly and is not gated
        // on sequence length — the cost depends on the number of CDG nodes (typically < 20).
        if let dag {
            let antichainAccepted = try runAntichainComposition(
                dag: dag,
                budget: &legBudget
            )
            if antichainAccepted {
                if collectStats {
                    totalMaterializations += legBudget.used - budgetBeforeDirectDecodes
                }
                budget -= legBudget.used
                return true
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
                let pairs = MutationPool.composePairs(from: individuals, sequence: sequence)
                var combined = individuals + pairs
                combined.sort { $0.deletedLength > $1.deletedLength }
                let speculativeDecoder = makeSpeculativeDecoder()
                let cacheSalt = speculativeDecoder.rejectCacheSalt
                for entry in combined {
                    guard legBudget.isExhausted == false else { break }
                    let candidate = entry.candidate
                    let cacheKey = ZobristHash.hash(of: candidate) &+ cacheSalt
                    if rejectCache.contains(cacheKey) {
                        continue
                    }
                    if let result = try speculativeDecoder.decode(
                        candidate: candidate,
                        gen: gen,
                        tree: tree,
                        originalSequence: sequence,
                        property: property
                    ) {
                        legBudget.recordMaterialization()
                        phaseTracker.recordInvocation()
                        accept(result, structureChanged: true)
                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "bonsai_phase1_accepted",
                                metadata: [
                                    "subphase": "deletion_pool",
                                    "deleted_length": "\(entry.deletedLength)",
                                ]
                            )
                        }
                        if collectStats {
                            totalMaterializations += legBudget.used - budgetBeforeDirectDecodes
                        }
                        budget -= legBudget.used
                        return true
                    }
                    legBudget.recordMaterialization()
                    phaseTracker.recordInvocation()
                    rejectCache.insert(cacheKey)
                }
            }
        }

        // Accumulate materializations from antichain composition and mutation pool.
        // runComposable calls within this method already accumulate their share
        // via their deferred blocks. Direct decode calls in the antichain and
        // mutation pool bypass runComposable and need manual accumulation.
        if collectStats {
            totalMaterializations += legBudget.used - budgetBeforeDirectDecodes
        }

        budget -= legBudget.used
        return false
    }

    // MARK: - Antichain Composition

    /// Applies delta-debugging over the maximal antichain of the CDG to find the largest jointly-deletable subset of structurally independent spans.
    ///
    /// Populates each antichain node with its best deletion candidate from the span cache, then searches for the maximal subset whose joint deletion preserves the property failure. Only activates when the antichain has more than two members; below that, pair enumeration in the ``MutationPool`` fallback is simpler and equally capable.
    private func runAntichainComposition(
        dag: ChoiceDependencyGraph,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> Bool {
        let antichainNodes = dag.maximalAntichain()
        guard antichainNodes.count > 2 else { return false }

        // Populate each antichain node with the best deletion candidate across all slot categories.
        let candidates = collectAntichainCandidates(
            antichainNodes: antichainNodes,
            dag: dag
        )
        guard candidates.count > 2 else { return false }

        let decoder = makeSpeculativeDecoder()

        // Delta-debug over the antichain to find the maximal jointly-deletable subset.
        let accepted = try findMaximalDeletableSubset(
            candidates: candidates,
            decoder: decoder,
            budget: &budget
        )

        if let accepted {
            let totalDeleted = accepted.reduce(0) { $0 + $1.deletedLength }
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "bonsai_phase1_accepted",
                    metadata: [
                        "subphase": "antichain",
                        "antichain_size": "\(candidates.count)",
                        "accepted_k": "\(accepted.count)",
                        "deleted_length": "\(totalDeleted)",
                    ]
                )
            }
            return true
        }

        return false
    }

    /// Collects the best deletion candidate for each antichain node by querying the span cache across all slot categories within the node's scope range.
    ///
    /// Returns candidates sorted by `deletedLength` descending so the delta-debugging binary split places high-impact nodes in the first half. Excludes nodes with no deletable spans in any slot category.
    private func collectAntichainCandidates(
        antichainNodes: [Int],
        dag: ChoiceDependencyGraph
    ) -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)] {
        var candidates = [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]()

        for nodeIndex in antichainNodes {
            guard let scopeRange = dag.nodes[nodeIndex].scopeRange else { continue }

            var bestSpans = [ChoiceSpan]()
            var bestLength = 0

            // Try each deletion slot category; keep the one with the most deleted material.
            for slot in ReductionScheduler.DeletionEncoderSlot.allCases {
                let spans = spanCache.deletionTargets(
                    category: slot.spanCategory,
                    inRange: scopeRange,
                    from: sequence
                )
                guard spans.isEmpty == false else { continue }
                let totalLength = spans.reduce(0) { $0 + $1.range.count }
                if totalLength > bestLength {
                    bestSpans = spans
                    bestLength = totalLength
                }
            }

            if bestSpans.isEmpty == false {
                candidates.append((
                    nodeIndex: nodeIndex,
                    spans: bestSpans,
                    deletedLength: bestLength
                ))
            }
        }

        // Sort by deletedLength descending so the binary split in delta-debugging places
        // high-impact nodes in the first half.
        candidates.sort { $0.deletedLength > $1.deletedLength }
        return candidates
    }

    /// Finds the maximal subset of the antichain whose joint deletion preserves the property failure.
    ///
    /// Splits the antichain in half, recurses into both halves, takes the larger successful subset, then greedily extends it over the full complement (not just the unchosen half) to discover cross-half compositions.
    ///
    /// - Complexity: O(*n* · log *n*) property evaluations where *n* is the antichain size.
    private func findMaximalDeletableSubset(
        candidates: [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)],
        decoder: SequenceDecoder,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]? {
        guard budget.isExhausted == false else { return nil }

        // Try the full set first — cheapest possible success.
        let allSpans = candidates.flatMap(\.spans)
        if let result = try testComposition(spans: allSpans, decoder: decoder, budget: &budget) {
            accept(result, structureChanged: true)
            return candidates
        }

        guard candidates.count > 1 else { return nil }

        // Binary split and recurse.
        let mid = candidates.count / 2
        let left = Array(candidates[..<mid])
        let right = Array(candidates[mid...])

        let leftResult = try findMaximalDeletableSubset(
            candidates: left,
            decoder: decoder,
            budget: &budget
        )
        let rightResult = try findMaximalDeletableSubset(
            candidates: right,
            decoder: decoder,
            budget: &budget
        )

        // Take the larger successful subset.
        var best: [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]
        switch (leftResult, rightResult) {
        case let (leftFound?, rightFound?):
            best = leftFound.count >= rightFound.count ? leftFound : rightFound
        case let (leftFound?, nil):
            best = leftFound
        case let (nil, rightFound?):
            best = rightFound
        case (nil, nil):
            return nil
        }

        // Greedy extension: try adding each candidate from the full complement, not just the
        // unchosen half. This is critical for discovering cross-half compositions — if the left
        // found {A, B} and the right found {C}, extending {A, B} over the full complement tries
        // adding C, D, E, ... including elements from the right half.
        let bestNodeIndices = Set(best.map(\.nodeIndex))
        for candidate in candidates where bestNodeIndices.contains(candidate.nodeIndex) == false {
            guard budget.isExhausted == false else { break }
            let extendedSpans = best.flatMap(\.spans) + candidate.spans
            if let result = try testComposition(
                spans: extendedSpans,
                decoder: decoder,
                budget: &budget
            ) {
                // Re-accept with the extended composition. The previous accept from the recursive
                // call set the state; this overwrites it with the strictly better result.
                accept(result, structureChanged: true)
                best.append(candidate)
            }
        }

        return best
    }

    /// Composes a set of spans into a single deletion candidate via range-set union and tests it against the property.
    ///
    /// Returns the accepted ``ReductionResult`` if the candidate preserves the failure and is shortlex-smaller than the current sequence, or `nil` if the candidate is rejected or cache-hit.
    private func testComposition(
        spans: [ChoiceSpan],
        decoder: SequenceDecoder,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> ReductionResult<Output>? {
        var rangeSet = RangeSet<Int>()
        for span in spans {
            rangeSet.insert(contentsOf: span.range.asRange)
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }

        let cacheKey = ZobristHash.hash(of: candidate) &+ decoder.rejectCacheSalt
        if rejectCache.contains(cacheKey) {
            return nil
        }

        let result = try decoder.decode(
            candidate: candidate,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property
        )
        budget.recordMaterialization()
        phaseTracker.recordInvocation()

        if result == nil {
            rejectCache.insert(cacheKey)
        }
        return result
    }

    // MARK: - Joint Bind-Inner Reduction

    /// Runs product-space encoders and value encoders on bind-inner values.
    private func runJointBindInnerReduction(budget: inout Int, cycle: Int = 0) throws -> Bool {
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
            let fullRange = 0 ... max(0, sequence.count - 1)
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
                    positionRange: 0 ... max(0, sequence.count - 1),
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

// MARK: - Fibre Descent (Value Minimization)

extension ReductionState {
    /// Fibre descent: minimises the value assignment within the fibre above the current base point.
    ///
    /// Categorically, this is the vertical factor of the cartesian-vertical factorisation — every accepted candidate stays in the same fibre (same trace structure). A ``StructuralFingerprint`` guard detects accidental base changes and rolls them back, enforcing the factorisation boundary. In Bonsai terms, it refines the leaves of the tree: with the branch structure fixed, each leaf value is reduced toward its simplest form. In plain language, it makes the values in the failing test case smaller and simpler without changing how many values there are or how they relate to each other.
    ///
    /// Processes DAG leaf positions first, then sweeps bound-content values at intermediate bind depths from minimum upward (covariant). Returns `true` if any value reduction was committed.
    func runFibreDescent(
        budget: inout Int,
        dag: ChoiceDependencyGraph?
    ) throws -> Bool {
        phaseTracker.push(.fibreDescent)
        defer { phaseTracker.pop() }
        let subBudget = min(budget, BonsaiScheduler.verificationBudget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()
        var anyAccepted = false

        // Profiling: count coordinates with cached floors at Phase 2 start
        var convergedCount = 0
        var totalValueCount = 0
        for index in 0 ..< sequence.count {
            guard sequence[index].value != nil else { continue }
            totalValueCount += 1
            if convergenceCache.convergedOrigin(at: index) != nil {
                convergedCount += 1
            }
        }
        convergedCoordinatesAtPhaseTwoStart += convergedCount
        totalValueCoordinatesAtPhaseTwoStart += totalValueCount

        // Build converged origins once for all fibre descent calls in this pass.
        // Mid-pass updates (from one encoder's convergence records) must not leak into
        // another encoder's converged origins — the cross-zero skip relies on the
        // converged bound matching the value at which cross-zero was last attempted,
        // which is encoder-specific. A shared mid-pass update would let one
        // encoder's convergence trigger another encoder's cross-zero skip even
        // though cross-zero at that value was never attempted by the second encoder.
        let cachedOrigins = convergenceCache.allEntries

        // Compute target leaf ranges.
        let leafRanges = computeLeafRanges(dag: dag)

        // Capture skeleton fingerprint before fibre descent starts.
        let prePhaseFingerprint: StructuralFingerprint? =
            if hasBind, let bindSpanIndex = bindIndex {
            StructuralFingerprint.from(sequence, bindIndex: bindSpanIndex)
        } else {
            nil
        }

        // Per-leaf-range value minimization pass.
        for leafRange in leafRanges {
            guard legBudget.isExhausted == false else { break }

            // Determine whether this leaf range needs the fingerprint guard. Bound leaves inside
            // non-constant bind regions can cause structural changes; guard fires on first acceptance.
            let isInBound = bindIndex?.isInBoundSubtree(leafRange.lowerBound) ?? false
            let structureChanged = isInBound && hasBind
            let needsFingerprintGuard: Bool
            if structureChanged, let currentBindIndex = bindIndex {
                let isConstant = dag?.nodes.contains { node in
                    guard case let .structural(.bindInner(regionIndex: regionIndex)) = node.kind,
                          regionIndex < currentBindIndex.regions.count else { return false }
                    let region = currentBindIndex.regions[regionIndex]
                    return region.boundRange.contains(leafRange.lowerBound)
                        && node.isStructurallyConstant
                } ?? false
                needsFingerprintGuard = isConstant == false
            } else {
                needsFingerprintGuard = false
            }

            var restartLeafRange = false
            repeat {
                restartLeafRange = false

                let leafSpans = extractValueSpans(in: leafRange)
                guard leafSpans.isEmpty == false else { break }

                let floatSpans = leafSpans.filter { span in
                    guard let value = sequence[span.range.lowerBound].value else { return false }
                    return value.choice.tag == .double || value.choice.tag == .float
                }
                let decoder: SequenceDecoder = isInBound
                    ? .guided(fallbackTree: fallbackTree ?? tree)
                    : .exact()

                let leafContext = ReductionContext(
                    bindIndex: bindIndex,
                    convergedOrigins: cachedOrigins,
                    dag: dag
                )
                let guard_ = needsFingerprintGuard ? prePhaseFingerprint : nil
                // Check for zeroingDependency suppression.
                let suppressZeroValue: Bool = {
                    guard let origins = cachedOrigins,
                          origins.isEmpty == false
                    else { return false }
                    return origins.values.allSatisfy {
                        $0.signal == .zeroingDependency
                    }
                }()

                var firstAcceptedSlot: ReductionScheduler.ValueEncoderSlot?
                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    let encoder: (any ComposableEncoder)?
                    switch slot {
                    case .zeroValue where leafSpans.isEmpty == false && suppressZeroValue == false:
                        encoder = zeroValueEncoder
                    case .binarySearchToZero where leafSpans.isEmpty == false:
                        encoder = binarySearchToZeroEncoder
                    case .binarySearchToTarget where leafSpans.isEmpty == false:
                        encoder = binarySearchToTargetEncoder
                    case .reduceFloat where floatSpans.isEmpty == false:
                        encoder = reduceFloatEncoder
                    default:
                        encoder = nil
                    }
                    guard let encoder else { continue }
                    if try runComposable(
                        encoder, decoder: decoder, positionRange: leafRange,
                        context: leafContext, structureChanged: structureChanged,
                        budget: &legBudget, fingerprintGuard: guard_
                    ) {
                        if firstAcceptedSlot == nil { firstAcceptedSlot = slot }
                    }
                }

                // LinearScanEncoder for nonMonotoneGap signals.
                if let origins = cachedOrigins {
                    for (position, origin) in origins {
                        guard legBudget.isExhausted == false else { break }
                        guard case let .nonMonotoneGap(remainingRange) = origin.signal,
                              remainingRange <= linearScanThreshold,
                              remainingRange > 0
                        else { continue }
                        let scanEncoder = LinearScanEncoder(
                            targetPosition: position,
                            scanRange: (origin.bound >= UInt64(remainingRange))
                                ? (origin.bound - UInt64(remainingRange)) ... (origin.bound - 1)
                                : 0 ... (origin.bound - 1),
                            scanDirection: .upward
                        )
                        if try runComposable(
                            scanEncoder, decoder: decoder, positionRange: leafRange,
                            context: leafContext, structureChanged: structureChanged,
                            budget: &legBudget, fingerprintGuard: guard_
                        ) {
                            anyAccepted = true
                        }
                    }
                }

                if let firstAccepted = firstAcceptedSlot {
                    ReductionScheduler.moveToFront(firstAccepted, in: &trainOrder)
                    anyAccepted = true
                    if needsFingerprintGuard {
                        restartLeafRange = true
                    }
                }
            } while restartLeafRange && legBudget.isExhausted == false
        }

        // Covariant value sweep: reduce bound-content values at intermediate bind depths.
        // DAG leaf positions miss values inside nested bind regions (for example, parent node values in a recursive bind generator like a binary heap). Shallow depths first so that deeper depths reduce in the correct context.
        // vSpans at depth D can include nested bind-inner positions whose reduction changes the inner bound structure, which belongs in base descent. The fingerprintGuard in each runComposable call catches this per-acceptance and rolls back the structural probe while preserving any earlier clean value reductions.
        let maxBindDepth = bindIndex?.maxBindDepth ?? 0
        let fullRange = 0 ... max(0, sequence.count - 1)
        if maxBindDepth >= 1, legBudget.isExhausted == false {
            for depth in stride(from: 1, through: maxBindDepth, by: 1) {
                guard legBudget.isExhausted == false else { break }
                dominance.invalidate()
                let depthDecoderContext = DecoderContext(
                    depth: .specific(depth),
                    bindIndex: bindIndex,
                    fallbackTree: fallbackTree,
                    strictness: .normal
                )
                let depthDecoder = SequenceDecoder.for(depthDecoderContext)
                let depthContext = ReductionContext(
                    bindIndex: bindIndex,
                    convergedOrigins: cachedOrigins,
                    dag: dag,
                    depthFilter: depth
                )
                let hasValueSpansAtDepth = spanCache.valueSpans(
                    at: depth, from: sequence, bindIndex: bindIndex
                ).isEmpty == false
                let hasFloatsAtDepth = spanCache.floatSpans(
                    at: depth, from: sequence, bindIndex: bindIndex
                ).isEmpty == false

                // Check for zeroingDependency suppression.
                let depthSuppressZeroValue: Bool = {
                    guard let origins = cachedOrigins,
                          origins.isEmpty == false
                    else { return false }
                    return origins.values.allSatisfy {
                        $0.signal == .zeroingDependency
                    }
                }()

                var firstAcceptedDepthSlot: ReductionScheduler.ValueEncoderSlot?
                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    let encoder: (any ComposableEncoder)?
                    switch slot {
                    case .zeroValue where hasValueSpansAtDepth && depthSuppressZeroValue == false:
                        encoder = zeroValueEncoder
                    case .binarySearchToZero where hasValueSpansAtDepth:
                        encoder = binarySearchToZeroEncoder
                    case .binarySearchToTarget where hasValueSpansAtDepth:
                        encoder = binarySearchToTargetEncoder
                    case .reduceFloat where hasFloatsAtDepth:
                        encoder = reduceFloatEncoder
                    default:
                        encoder = nil
                    }
                    guard let encoder else { continue }
                    if try runComposable(
                        encoder, decoder: depthDecoder, positionRange: fullRange,
                        context: depthContext, structureChanged: hasBind,
                        budget: &legBudget, fingerprintGuard: prePhaseFingerprint
                    ) {
                        if firstAcceptedDepthSlot == nil { firstAcceptedDepthSlot = slot }
                    }
                }

                // LinearScanEncoder for nonMonotoneGap signals.
                if let origins = cachedOrigins {
                    for (position, origin) in origins {
                        guard legBudget.isExhausted == false else { break }
                        guard case let .nonMonotoneGap(remainingRange) = origin.signal,
                              remainingRange <= linearScanThreshold,
                              remainingRange > 0
                        else { continue }
                        let scanEncoder = LinearScanEncoder(
                            targetPosition: position,
                            scanRange: (origin.bound >= UInt64(remainingRange))
                                ? (origin.bound - UInt64(remainingRange)) ... (origin.bound - 1)
                                : 0 ... (origin.bound - 1),
                            scanDirection: .upward
                        )
                        if try runComposable(
                            scanEncoder, decoder: depthDecoder, positionRange: fullRange,
                            context: depthContext, structureChanged: hasBind,
                            budget: &legBudget, fingerprintGuard: prePhaseFingerprint
                        ) {
                            anyAccepted = true
                        }
                    }
                }

                if let firstAccepted = firstAcceptedDepthSlot {
                    ReductionScheduler.moveToFront(firstAccepted, in: &trainOrder)
                    anyAccepted = true
                }
            }
        }

        // Redistribution (once at end of fibre descent).
        if legBudget.isExhausted == false {
            let redistDecoderContext = DecoderContext(
                depth: .global,
                bindIndex: bindIndex,
                fallbackTree: fallbackTree,
                strictness: .normal
            )
            let redistDecoder = SequenceDecoder.for(redistDecoderContext)
            let redistContext = ReductionContext(
                bindIndex: bindIndex,
                convergedOrigins: cachedOrigins,
                dag: dag
            )

            if try runComposable(
                tandemEncoder, decoder: redistDecoder,
                positionRange: fullRange, context: redistContext,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }
            if try runComposable(
                redistributeEncoder, decoder: redistDecoder,
                positionRange: fullRange, context: redistContext,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bonsai_phase2_complete",
                metadata: [
                    "progress": "\(anyAccepted)",
                    "budget_remaining": "\(budget)",
                ]
            )
        }

        budget -= legBudget.used
        return anyAccepted
    }
}

// MARK: - Kleisli Exploration

extension ReductionState {
    /// Explores cross-level minima via ``KleisliComposition`` along CDG dependency edges.
    ///
    /// Targets the case where Phase 1c's guided lift does not preserve the failure at a reduced bind-inner value, but a specific downstream reduction in the new fibre recovers it. The composition searches both levels jointly — the upstream encoder proposes bind-inner values, the generator lift materializes without property check, and the downstream encoder searches the lifted fibre.
    ///
    /// Follows the ``runRelaxRound(remaining:)`` checkpoint/rollback pattern: snapshot before exploration, accept only if the net result is shortlex-better than the checkpoint.
    ///
    /// Returns `true` if the exploration found a net improvement.
    func runKleisliExploration(
        budget: inout Int,
        dag: ChoiceDependencyGraph?,
        edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100)
    ) throws -> Bool {
        phaseTracker.push(.exploration)
        defer { phaseTracker.pop() }
        guard hasBind, let dag, let bindSpanIndex = bindIndex else { return false }

        let edges = dag.reductionEdges()
        guard edges.isEmpty == false else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_exploration_skip",
                    metadata: ["reason": "no_edges"]
                )
            }
            return false
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "kleisli_exploration_start",
                metadata: [
                    "edges": "\(edges.count)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        let checkpoint = makeSnapshot()
        let acceptancesAtCheckpoint = phaseTracker.counts[.exploration]?.acceptances ?? 0
        let structuralAtCheckpoint = phaseTracker.counts[.exploration]?.structuralAcceptances ?? 0
        var anyAccepted = false
        var kleisliProbes = 0
        var kleisliMaterializations = 0

        let compositionEdges = Self.compositionDescriptors(
            edges: edges,
            gen: gen,
            sequence: sequence,
            tree: tree,
            fallbackTree: fallbackTree
        )

        for var compositionEdge in compositionEdges {
            guard budget > 0 else { break }
            compositionEdgesAttempted += 1

            let edge = compositionEdge.edge
            let prediction = compositionEdge.prediction

            // Skip structurally constant edges where the prior cycle's downstream
            // exhaustively searched the fibre and found no failure at this upstream value.
            if edge.isStructurallyConstant,
               let observation = edgeObservations[edge.regionIndex],
               observation.signal == .exhaustedClean,
               let currentUpstreamValue = sequence[
                   edge.upstreamRange.lowerBound
               ].value?.choice.bitPattern64,
               observation.upstreamValue == currentUpstreamValue
            {
                continue
            }

            // Run via manual loop (same pattern as runRelaxRound).
            let edgeSubBudget: Int = {
                switch edgeBudgetPolicy {
                case let .fixed(cap):
                    return min(budget, cap)
                case .adaptive:
                    let baseBudget = 100
                    guard let observation = edgeObservations[edge.regionIndex] else {
                        return min(budget, baseBudget)
                    }
                    switch observation.signal {
                    case .exhaustedWithFailure:
                        // Productive edge — increase budget by 50%.
                        return min(budget, baseBudget + baseBudget / 2)
                    case .exhaustedClean:
                        // Clean edge not caught by the skip above (data-dependent edge, or
                        // upstream value changed). Reduce budget by 50%.
                        return min(budget, baseBudget / 2)
                    case .bail:
                        // Bail — DownstreamPick should prevent this, but if it persists,
                        // reduce budget.
                        return min(budget, baseBudget / 2)
                    }
                }
            }()
            var legBudget = ReductionScheduler.LegBudget(hardCap: edgeSubBudget)

            let context = ReductionContext(
                bindIndex: bindSpanIndex,
                convergedOrigins: convergenceCache.allEntries,
                dag: dag
            )
            // Do not pass converged origins to the composition. The convergence
            // cache records floors established by the standalone pipeline — values
            // below which the property passes WITHOUT downstream fibre search.
            // The composition's purpose is to re-explore those values WITH
            // downstream search. Passing the cache would tell the upstream encoder
            // its current value is already at the floor, producing zero probes.
            compositionEdge.composition.start(
                sequence: sequence,
                tree: tree,
                positionRange: 0 ... max(0, sequence.count - 1),
                context: context
            )

            var lastAccepted = false
            var anyAcceptedThisEdge = false
            while true {
                // Warm-start validation: before the composition advances to the
                // next upstream probe and initializes the downstream, validate any
                // pending convergence transfer from the previous downstream.
                if let pending = compositionEdge.composition.pendingTransferOrigins,
                   let delta = compositionEdge.composition.upstreamDelta, delta == 1
                {
                    // Adjacent upstream values — validate each origin at floor - 1.
                    convergenceTransfersAttempted += 1
                    var allValid = true
                    for (index, origin) in pending {
                        guard index < sequence.count,
                              let value = sequence[index].value,
                              let range = value.validRange,
                              origin.bound > range.lowerBound
                        else { continue }

                        let probeBP = origin.bound - 1
                        var candidate = sequence
                        candidate[index] = .value(.init(
                            choice: ChoiceValue(
                                value.choice.tag.makeConvertible(bitPattern64: probeBP),
                                tag: value.choice.tag
                            ),
                            validRange: value.validRange,
                            isRangeExplicit: value.isRangeExplicit
                        ))
                        legBudget.recordMaterialization()
                        phaseTracker.recordInvocation()

                        let validationDecoder = SequenceDecoder.exact()
                        if let result = try validationDecoder.decode(
                            candidate: candidate,
                            gen: gen,
                            tree: tree,
                            originalSequence: sequence,
                            property: property
                        ), result.sequence.shortLexPrecedes(sequence) {
                            // Property fails at floor - 1: floor is stale.
                            // Discard ALL pending origins and cold-start.
                            allValid = false
                            accept(result, structureChanged: false)
                            anyAccepted = true
                            break
                        }
                    }
                    if allValid {
                        convergenceTransfersValidated += 1
                    } else {
                        convergenceTransfersStale += 1
                    }
                    compositionEdge.composition.setValidatedOrigins(allValid ? pending : nil)
                } else {
                    // First probe, delta > 1, or no pending origins: cold-start.
                    compositionEdge.composition.setValidatedOrigins(nil)
                }

                guard let probe = compositionEdge.composition.nextProbe(
                    lastAccepted: lastAccepted
                ) else {
                    break
                }
                guard legBudget.isExhausted == false else { break }
                if collectStats { kleisliProbes += 1 }
                legBudget.recordMaterialization()
                phaseTracker.recordInvocation()

                let decoder = SequenceDecoder.exact()
                if let result = try decoder.decode(
                    candidate: probe,
                    gen: gen,
                    tree: tree,
                    originalSequence: sequence,
                    property: property
                ) {
                    if result.sequence.shortLexPrecedes(sequence) {
                        accept(result, structureChanged: true)
                        lastAccepted = true
                        anyAccepted = true
                        anyAcceptedThisEdge = true

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "kleisli_exploration_accepted",
                                metadata: [
                                    "region": "\(edge.regionIndex)",
                                    "seq_len": "\(sequence.count)",
                                ]
                            )
                        }
                    } else {
                        lastAccepted = false
                    }
                } else {
                    lastAccepted = false
                }
            }

            // Track futile compositions (zero accepted probes for this edge)
            if legBudget.used > 0, anyAcceptedThisEdge == false {
                futileCompositions += 1
            }

            // Harvest fibre telemetry from the composition's downstream encoder.
            if collectStats {
                let comp = compositionEdge.composition
                fibreExceededExhaustiveThreshold += comp.fibrePairwiseStarts
                pairwiseOnExhaustibleFibre += comp.fibreExhaustiveStarts
                fibreZeroValueStarts += comp.fibreZeroValueStarts

                // Compare prediction against ground truth.
                // The prediction uses the current sequence; the ground truth uses the lifted sequences.
                // "Correct" means the predicted mode matches the MAJORITY of actual downstream starts.
                let actualMajorityMode: FibrePrediction.Mode
                if comp.fibreExhaustiveStarts >= comp.fibrePairwiseStarts,
                   comp.fibreExhaustiveStarts >= comp.fibreZeroValueStarts
                {
                    actualMajorityMode = .exhaustive
                } else if comp.fibrePairwiseStarts >= comp.fibreZeroValueStarts {
                    actualMajorityMode = .pairwise
                } else {
                    actualMajorityMode = .tooLarge
                }

                let totalStarts = comp.fibreExhaustiveStarts
                    + comp.fibrePairwiseStarts
                    + comp.fibreZeroValueStarts
                if totalStarts > 0 {
                    if prediction.predictedMode == actualMajorityMode {
                        fibrePredictionCorrect += 1
                    } else {
                        fibrePredictionWrong += 1
                    }
                }
            }

            // Log prediction vs ground truth for encoder selection accuracy measurement.
            if isInstrumented {
                let actualExhaustive = compositionEdge.composition.fibreExhaustiveStarts
                let actualPairwise = compositionEdge.composition.fibrePairwiseStarts
                let actualBail = compositionEdge.composition.fibreZeroValueStarts
                let predictionLabel: String = switch prediction.predictedMode {
                case .exhaustive: "exhaustive"
                case .pairwise: "pairwise"
                case .tooLarge: "too_large"
                }
                ExhaustLog.debug(
                    category: .reducer,
                    event: "fibre_prediction",
                    metadata: [
                        "region": "\(edge.regionIndex)",
                        "predicted_mode": predictionLabel,
                        "predicted_size": "\(prediction.predictedSize)",
                        "predicted_params": "\(prediction.parameterCount)",
                        "actual_exhaustive": "\(actualExhaustive)",
                        "actual_pairwise": "\(actualPairwise)",
                        "actual_bail": "\(actualBail)",
                        "max_fibre": "\(compositionEdge.composition.maxObservedFibreSize)",
                    ]
                )
            }

            // Record per-edge observation for cross-cycle factory decisions.
            let totalDownstreamStarts = compositionEdge.composition.fibreExhaustiveStarts
                + compositionEdge.composition.fibrePairwiseStarts
                + compositionEdge.composition.fibreZeroValueStarts
            let edgeSignal: FibreSignal
            if totalDownstreamStarts == 0 {
                edgeSignal = .bail(paramCount: edge.downstreamRange.count)
            } else if anyAcceptedThisEdge {
                edgeSignal = .exhaustedWithFailure
            } else {
                edgeSignal = .exhaustedClean
            }
            if let upstreamValue = compositionEdge.composition.previousUpstreamBitPattern {
                edgeObservations[edge.regionIndex] = EdgeObservation(
                    signal: edgeSignal,
                    upstreamValue: upstreamValue
                )
            }
            if collectStats {
                switch edgeSignal {
                case .exhaustedClean: fibreExhaustedCleanCount += 1
                case .exhaustedWithFailure: fibreExhaustedWithFailureCount += 1
                case .bail: fibreBailCount += 1
                }
            }

            budget -= legBudget.used
            if collectStats { kleisliMaterializations += legBudget.used }
        }

        if collectStats {
            encoderProbes[.kleisliComposition, default: 0] += kleisliProbes
            totalMaterializations += kleisliMaterializations
        }

        // Pipeline acceptance: net improvement check.
        if anyAccepted, sequence.shortLexPrecedes(checkpoint.sequence) {
            bestSequence = sequence
            bestOutput = output

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_exploration_complete",
                    metadata: [
                        "accepted": "true",
                        "seq_len": "\(sequence.count)",
                    ]
                )
            }

            return true
        }

        // Rollback: net result was not an improvement. Revert acceptances but keep invocations.
        phaseTracker.restoreAcceptances(
            for: .exploration,
            acceptances: acceptancesAtCheckpoint,
            structuralAcceptances: structuralAtCheckpoint
        )
        restoreSnapshot(checkpoint)
        return false
    }
}

// MARK: - Helpers

extension ReductionState {
    /// Computes ordered leaf ranges for fibre descent.
    ///
    /// Uses DAG leaf positions when available. For bind-free generators, uses all value spans at depth 0. Leaves inside bind-bound subtrees are ordered first (structural proximity ordering).
    func computeLeafRanges(dag: ChoiceDependencyGraph?) -> [ClosedRange<Int>] {
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
        var minPosition = valueSpans[0].range.lowerBound
        var maxPosition = valueSpans[0].range.upperBound
        for span in valueSpans.dropFirst() {
            if span.range.lowerBound < minPosition { minPosition = span.range.lowerBound }
            if span.range.upperBound > maxPosition { maxPosition = span.range.upperBound }
        }
        return [minPosition ... maxPosition]
    }

    /// Extracts value spans within the given position range.
    private func extractValueSpans(in range: ClosedRange<Int>) -> [ChoiceSpan] {
        let allSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        return allSpans.filter { range.contains($0.range.lowerBound) }
    }

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
                scopes.append(DeletionScope(positionRange: boundRange, depth: boundDepth))
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

// MARK: - Composition Descriptors

/// A composition edge paired with its fibre prediction, ready for execution.
struct CompositionEdge<Output> {
    var composition: KleisliComposition<Output>
    let prediction: FibrePrediction
    let edge: ReductionEdge
}

/// Predicts the downstream fibre size for a CDG edge from the current sequence state.
///
/// Walks value positions in the downstream range, reads their domain sizes from ``validRange``, and returns the product. This is the same computation ``FibreCoveringEncoder`` performs at ``ComposableEncoder/start(sequence:tree:positionRange:context:)`` time — but computed on the CURRENT sequence before the upstream mutation, not on the lifted sequence after it.
///
/// The prediction is accurate when the downstream domains are independent of the upstream value (structurally constant edges). For data-dependent edges, the actual fibre size after lift may differ.
struct FibrePrediction {
    /// Product of domain sizes across downstream value positions.
    let predictedSize: UInt64
    /// Number of value parameters in the downstream range.
    let parameterCount: Int
    /// Predicted encoder mode based on thresholds.
    let predictedMode: Mode

    enum Mode: Equatable {
        case exhaustive    // predictedSize <= 64
        case pairwise      // predictedSize > 64, parameterCount <= 20
        case tooLarge      // parameterCount > 20 or overflow
    }
}

extension ReductionState {
    /// Builds composition edges from CDG reduction edges, ordered by predicted fibre size.
    ///
    /// Each edge gets a discovery lift at the upstream's reduction target to predict the downstream fibre size. Edges predicted as too large (> 20 parameters, downstream encoder would bail with zero probes) are excluded. Remaining edges are ordered by ascending predicted fibre size — cheaper edges first.
    static func compositionDescriptors(
        edges: [ReductionEdge],
        gen: FreerMonad<ReflectiveOperation, Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?
    ) -> [CompositionEdge<Output>] {
        var result = [CompositionEdge<Output>]()
        result.reserveCapacity(edges.count)

        for edge in edges {
            let prediction: FibrePrediction

            // Structurally constant edges: the fibre shape is invariant under upstream
            // value changes. The discovery lift at the target sees the same fibre as every
            // other upstream value — the prediction is exact. Select the downstream encoder
            // at factory time.
            //
            // Data-dependent edges: the fibre varies with each upstream candidate. The
            // discovery lift sees the target's fibre (typically the smallest). Don't commit
            // to a downstream encoder based on this — let FibreCoveringEncoder inspect
            // the actual fibre at start() time and select exhaustive or pairwise.
            if edge.isStructurallyConstant {
                prediction = predictFibreSizeAtTarget(
                    sequence: sequence,
                    edge: edge,
                    gen: gen,
                    tree: tree,
                    fallbackTree: fallbackTree
                )
                // For constant edges, the prediction is exact. Skip if tooLarge.
                if prediction.predictedMode == .tooLarge {
                    continue
                }
            } else {
                // For data-dependent edges, use the current-sequence prediction for ordering
                // only. Don't skip — the actual fibre may be smaller at some upstream values.
                prediction = predictFibreSize(
                    sequence: sequence,
                    downstreamRange: edge.downstreamRange
                )
            }

            // Constant edges: FibreCoveringEncoder (prediction is exact, fibre won't change).
            // Data-dependent edges: DownstreamPick selects at runtime based on actual fibre.
            let downstream: any ComposableEncoder
            if edge.isStructurallyConstant {
                downstream = FibreCoveringEncoder()
            } else {
                downstream = DownstreamPick(alternatives: [
                    // Exhaustive: small fibres (<= 64 combinations).
                    .init(
                        encoder: FibreCoveringEncoder(),
                        predicate: { totalSpace, _ in
                            totalSpace <= FibreCoveringEncoder.exhaustiveThreshold
                        }
                    ),
                    // Pairwise: medium fibres (2–20 parameters).
                    .init(
                        encoder: FibreCoveringEncoder(),
                        predicate: { _, paramCount in paramCount >= 2 && paramCount <= 20 }
                    ),
                    // Zero-value: large fibres (> 20 params or overflow). Cheap structural
                    // probe — the all-at-once zero discovers elimination-regime failures.
                    .init(
                        encoder: ZeroValueEncoder(),
                        predicate: { _, _ in true }
                    ),
                ])
            }

            let composition = KleisliComposition(
                upstream: BinarySearchToSemanticSimplestEncoder(),
                downstream: downstream,
                lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: fallbackTree ?? tree)),
                upstreamRange: edge.upstreamRange,
                downstreamRange: edge.downstreamRange
            )

            result.append(CompositionEdge(
                composition: composition,
                prediction: prediction,
                edge: edge
            ))
        }

        // Order by leverage / requiredBudget (descending). Higher score = more structural
        // impact per probe. Leverage is the downstream range size; required budget is the
        // predicted fibre size (capped at the covering budget for pairwise).
        result.sort { lhs, rhs in
            let coveringCap = UInt64(FibreCoveringEncoder.coveringBudget)
            let lhsBudget = max(1, min(lhs.prediction.predictedSize, coveringCap))
            let rhsBudget = max(1, min(rhs.prediction.predictedSize, coveringCap))
            let lhsLeverage = UInt64(lhs.edge.downstreamRange.count)
            let rhsLeverage = UInt64(rhs.edge.downstreamRange.count)
            // leverage / budget — higher is better. Cross-multiply to avoid division.
            return lhsLeverage * rhsBudget > rhsLeverage * lhsBudget
        }

        return result
    }

    // MARK: - Fibre size prediction

    /// Predicts downstream fibre size from the current sequence state.
    static func predictFibreSize(
        sequence: ChoiceSequence,
        downstreamRange: ClosedRange<Int>
    ) -> FibrePrediction {
        var parameterCount = 0
        var product: UInt64 = 1
        var overflowed = false

        for index in downstreamRange {
            guard index < sequence.count else { break }
            guard let value = sequence[index].value,
                  let validRange = value.validRange
            else { continue }

            parameterCount += 1
            let domainSize = validRange.upperBound - validRange.lowerBound + 1
            let (result, overflow) = product.multipliedReportingOverflow(by: domainSize)
            if overflow || result > UInt64.max / 2 {
                overflowed = true
                break
            }
            product = result
        }

        let predictedSize = overflowed ? UInt64.max : product
        let mode: FibrePrediction.Mode
        if overflowed || parameterCount > 20 {
            mode = .tooLarge
        } else if predictedSize <= FibreCoveringEncoder.exhaustiveThreshold {
            mode = .exhaustive
        } else {
            mode = .pairwise
        }

        return FibrePrediction(
            predictedSize: predictedSize,
            parameterCount: parameterCount,
            predictedMode: mode
        )
    }

    /// Predicts downstream fibre size at the upstream's reduction target via a discovery lift.
    ///
    /// Sets the upstream bind-inner value to its reduction target (range minimum or semantic simplest), materialises the generator to produce a fresh downstream sequence, then reads the fibre size from the lifted result. This is one materialisation — the "discovery budget" from the planning document.
    ///
    /// Returns the naive prediction (from the current sequence) if the discovery lift fails.
    static func predictFibreSizeAtTarget(
        sequence: ChoiceSequence,
        edge: ReductionEdge,
        gen: FreerMonad<ReflectiveOperation, Output>,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?
    ) -> FibrePrediction {
        // Read the upstream value and compute its reduction target.
        let upstreamIndex = edge.upstreamRange.lowerBound
        guard upstreamIndex < sequence.count,
              let upstreamValue = sequence[upstreamIndex].value
        else {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        let isWithinRecordedRange =
            upstreamValue.isRangeExplicit
            && upstreamValue.choice.fits(in: upstreamValue.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? upstreamValue.choice.reductionTarget(in: upstreamValue.validRange)
            : upstreamValue.choice.semanticSimplest.bitPattern64

        // If the upstream is already at its target, the current-sequence prediction is exact.
        if targetBitPattern == upstreamValue.choice.bitPattern64 {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        // Build a modified sequence with the upstream set to its target.
        var modified = sequence
        modified[upstreamIndex] = .value(.init(
            choice: ChoiceValue(
                upstreamValue.choice.tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: upstreamValue.choice.tag
            ),
            validRange: upstreamValue.validRange,
            isRangeExplicit: upstreamValue.isRangeExplicit
        ))

        // Discovery lift: materialise at the target upstream value.
        let liftResult = ReductionMaterializer.materialize(
            gen,
            prefix: modified,
            mode: .exact,
            fallbackTree: fallbackTree ?? tree
        )

        switch liftResult {
        case let .success(_, freshTree, _):
            let freshSequence = ChoiceSequence(freshTree)
            // Read the fibre size from the lifted sequence.
            // The downstream range may shift in the lifted sequence (structural changes).
            // Use the edge's downstream range clamped to the fresh sequence length.
            let clampedUpperBound = min(
                edge.downstreamRange.upperBound,
                max(0, freshSequence.count - 1)
            )
            let clampedRange = edge.downstreamRange.lowerBound ... clampedUpperBound
            return predictFibreSize(sequence: freshSequence, downstreamRange: clampedRange)
        case .rejected, .failed:
            // Discovery lift failed (target value out of range or materialisation error).
            // Fall back to the naive prediction from the current sequence.
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }
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
}
