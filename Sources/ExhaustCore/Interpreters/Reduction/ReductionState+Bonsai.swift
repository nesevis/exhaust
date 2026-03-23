// MARK: - Base Descent and Fibre Descent

//
// Extends ReductionState with the two phases of BonsaiScheduler's alternating minimization.
// Base descent (ramification) minimises the trace structure — the base of the fibration —
// via branch simplification, structural deletion, and bind-inner reduction.
// Fibre descent (foliage) minimises the value assignment within a fixed trace structure —
// the fibre above the current base point — via DAG-guided coordinate descent.

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
        let subBudget = min(budget, 200)
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

        promoteBranchesEncoder.currentTree = tree
        if try runBatch(
            promoteBranchesEncoder,
            decoder: branchDecoder,
            targets: .wholeSequence,
            structureChanged: true,
            budget: &legBudget
        ) {
            improved = true
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "bonsai_phase1_accepted",
                                 metadata: ["subphase": "branch_promote"])
            }
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
        let subBudget = min(budget, 1200)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()

        let scopes = buildDeletionScopes(dag: dag)

        for scope in scopes {
            guard legBudget.isExhausted == false else { break }
            dominance.invalidate()
            let scopeDecoder = makeDeletionDecoder(at: scope.depth)

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
                let slotAccepted: Bool = switch slot {
                case .randomRepairDelete:
                    try runAdaptive(
                        randomRepairDelete,
                        decoder: makeSpeculativeDecoder(),
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .containerSpans:
                    try runAdaptive(
                        deleteContainerSpans,
                        decoder: scopeDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .sequenceElements:
                    try runAdaptive(
                        deleteSequenceElements,
                        decoder: scopeDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .sequenceBoundaries:
                    try runAdaptive(
                        deleteSequenceBoundaries,
                        decoder: scopeDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .freeStandingValues:
                    try runAdaptive(
                        deleteFreeStandingValues,
                        decoder: scopeDecoder,
                        targets: .spans(targets),
                        structureChanged: true,
                        budget: &legBudget
                    )
                case .alignedWindows:
                    try runAdaptive(
                        deleteAlignedWindowsEncoder,
                        decoder: scopeDecoder,
                        targets: .spans(targets),
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
                        legBudget.recordMaterialization()
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
                        budget -= legBudget.used
                        return true
                    }
                    legBudget.recordMaterialization()
                    rejectCache.insert(cacheKey)
                }
            }
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
                candidates.append((nodeIndex: nodeIndex, spans: bestSpans, deletedLength: bestLength))
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
            budget.recordMaterialization()
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

        if result == nil {
            rejectCache.insert(cacheKey)
        }
        return result
    }

    // MARK: - Joint Bind-Inner Reduction

    /// Runs product-space encoders and value encoders on bind-inner values.
    private func runJointBindInnerReduction(budget: inout Int, cycle: Int = 0) throws -> Bool {
        guard hasBind, let bindSpanIndex = bindIndex else { return false }
        let subBudget = min(budget, 600)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()
        var accepted = 0

        let bindInnerCount = bindSpanIndex.regions.count

        if bindInnerCount <= 3 {
            // Batch: enumerate product space of bind-inner values.
            let bindDag = ChoiceDependencyGraph.build(
                from: sequence, tree: tree, bindIndex: bindSpanIndex
            )
            productSpaceBatchEncoder.bindIndex = bindSpanIndex
            productSpaceBatchEncoder.dag = bindDag

            // Compute dependent domains for nested binds via lightweight replay.
            productSpaceBatchEncoder.dependentDomains = computeDependentDomains(
                bindSpanIndex: bindSpanIndex, dag: bindDag
            )

            // Pre-materialize once; both tiers reuse the same [ChoiceSequence] array.
            let allCandidates = Array(productSpaceBatchEncoder.encode(
                sequence: sequence, targets: .wholeSequence
            ))
            let tier1Encoder = PrecomputedBatchEncoder(
                name: productSpaceBatchEncoder.name,
                phase: productSpaceBatchEncoder.phase,
                candidates: allCandidates
            )

            // Tier 1: guided replay (clamp bound entries to current tree).
            let guidedDecoder: SequenceDecoder = .guided(
                fallbackTree: fallbackTree ?? tree
            )
            if try runBatch(
                tier1Encoder, decoder: guidedDecoder,
                targets: .wholeSequence, structureChanged: true,
                budget: &legBudget
            ) {
                accepted += 1
            } else {
                // Tier 2: PRNG fallback with salted retries, largest-fibre-first ordering.
                // Sort candidates by bind-inner value sum descending so that candidates with larger inner values (wider downstream domains) are tried first, giving PRNG more room to find a failure.
                // Capped at 5 candidates per the spec.
                let tier2Candidates = sortByLargestFibreFirst(
                    allCandidates, bindIndex: bindSpanIndex
                )
                let tier2Encoder = PrecomputedBatchEncoder(
                    name: .productSpaceBatch,
                    phase: .valueMinimization,
                    candidates: tier2Candidates
                )

                // MARK: - Regime probe (Opportunity 2: fibration uniqueness of cartesian lifts)

                //
                // The uniqueness law says the canonical projection is the unique best projection — the
                // PRNG retries below are not searching for a better one, they're asking whether any
                // point in the new fibre witnesses the failure. When the failure is structural (elimination
                // regime), all four retries are guaranteed waste. Build the simplest-values probe to
                // detect the regime before committing to the retry budget.
                var simplestProbe = sequence
                var probeNeedsRun = false
                var probeIdx = 0
                while probeIdx < simplestProbe.count {
                    if let v = simplestProbe[probeIdx].value {
                        let target = ZeroValueEncoder.simplestTarget(for: v)
                        if target != v.choice {
                            probeNeedsRun = true
                            simplestProbe[probeIdx] = .value(.init(
                                choice: target,
                                validRange: v.validRange,
                                isRangeExplicit: v.isRangeExplicit
                            ))
                        }
                    }
                    probeIdx += 1
                }

                var skipRetries = false
                if probeNeedsRun {
                    legBudget.recordMaterialization()
                    let probeResult = ReductionMaterializer.materialize(
                        gen, prefix: simplestProbe, mode: .exact, fallbackTree: fallbackTree
                    )
                    let regime: String
                    let probeResultLabel: String
                    switch probeResult {
                    case let .success(value: probeValue, tree: freshTree, decodingReport: _):
                        let freshSequence = ChoiceSequence(freshTree)
                        if property(probeValue) == false, freshSequence.shortLexPrecedes(sequence) {
                            // Elimination regime: failure is structural, not value-sensitive.
                            // Accept the simplest-values witness and skip the PRNG retries — no
                            // value assignment can improve on this. The shortlex guard ensures we
                            // never corrupt bestSequence by accepting a non-improving result (which
                            // can happen when zeroing bind-inner values expands the bound subtree).
                            regime = "elimination"
                            probeResultLabel = "success"
                            accept(
                                ReductionResult(
                                    sequence: freshSequence,
                                    tree: freshTree,
                                    output: probeValue,
                                    evaluations: 1,
                                    decodingReport: nil
                                ),
                                structureChanged: true
                            )
                            accepted += 1
                            skipRetries = true
                        } else {
                            // Value-sensitive regime: specific values are required to reproduce the
                            // failure. Proceed with PRNG retries.
                            regime = "value_sensitive"
                            probeResultLabel = "success"
                        }
                    case .rejected:
                        // Regime unknown: a value was out of range in exact mode. Fall back to retries.
                        regime = "unknown"
                        probeResultLabel = "rejected"
                    // OPPORTUNITY 3 (commented out — enable after measuring `rejected` frequency)
                    // Compute g!(semanticSimplest): materialize the candidate in guided mode
                    // with minimal values, then compute shortlex distance between the result
                    // and the current best sequence. Large distance → lossy reduction →
                    // treat as elimination regime and skip retries.
                    //
                    // let cocartesianResult = ReductionMaterializer.materialize(
                    //     gen,
                    //     prefix: sequence,
                    //     mode: .guided(
                    //         seed: ZobristHash.hash(of: sequence),
                    //         fallbackTree: fallbackTree ?? tree
                    //     ),
                    //     fallbackTree: fallbackTree
                    // )
                    // if case let .success(_, embeddedTree) = cocartesianResult {
                    //     let embeddedSeq = ChoiceSequence(embeddedTree)
                    //     let distance = ChoiceSequence.shortlexDistance(embeddedSeq, sequence)
                    //     if distance > /* threshold TBD */ 0 {
                    //         skipRetries = true
                    //     }
                    // }
                    case .failed:
                        regime = "unknown"
                        probeResultLabel = "failed"
                    }
                    if isInstrumented {
                        ExhaustLog.debug(
                            category: .reducer,
                            event: "bonsai_regime_probe",
                            metadata: ["regime": regime, "result": probeResultLabel]
                        )
                    }
                }

                let maxRetries = 4
                if skipRetries == false {
                    for attempt in 0 ..< maxRetries {
                        guard legBudget.isExhausted == false else { break }
                        let saltedDecoder: SequenceDecoder = .guided(
                            fallbackTree: nil, usePRNGFallback: true,
                            prngSalt: UInt64(cycle * maxRetries + attempt)
                        )
                        if try runBatch(
                            tier2Encoder, decoder: saltedDecoder,
                            targets: .wholeSequence, structureChanged: true,
                            budget: &legBudget
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
            productSpaceAdaptiveEncoder.bindIndex = bindSpanIndex
            while legBudget.isExhausted == false {
                if try runAdaptive(
                    productSpaceAdaptiveEncoder, decoder: adaptivePRNGDecoder,
                    targets: .wholeSequence, structureChanged: true,
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
        let subBudget = min(budget, BonsaiScheduler.fibreDescentBudget)
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
        let prePhaseFingerprint: StructuralFingerprint? = if hasBind, let bindSpanIndex = bindIndex {
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
                    return currentBindIndex.regions[regionIndex].boundRange.contains(leafRange.lowerBound)
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

                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    var slotAccepted = false
                    // Pass the guard into runAdaptive so the boundary fires per-acceptance, not after the full encoder run. Adaptive encoders capture seqIdx at start() time; a structural change mid-loop makes those indices stale before the encoder produces its next probe.
                    let guard_ = needsFingerprintGuard ? prePhaseFingerprint : nil
                    switch slot {
                    case .zeroValue where leafSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            zeroValueEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget,
                            fingerprintGuard: guard_,
                            convergedOrigins: cachedOrigins
                        )
                    case .binarySearchToZero where leafSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            binarySearchToZeroEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget,
                            fingerprintGuard: guard_,
                            convergedOrigins: cachedOrigins
                        )
                    case .binarySearchToTarget where leafSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            binarySearchToTargetEncoder, decoder: decoder,
                            targets: .spans(leafSpans), structureChanged: structureChanged,
                            budget: &legBudget,
                            fingerprintGuard: guard_,
                            convergedOrigins: cachedOrigins
                        )
                    case .reduceFloat where floatSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            reduceFloatEncoder, decoder: decoder,
                            targets: .spans(floatSpans), structureChanged: structureChanged,
                            budget: &legBudget,
                            fingerprintGuard: guard_,
                            convergedOrigins: cachedOrigins
                        )
                    default:
                        break
                    }
                    guard slotAccepted else { continue }

                    anyAccepted = true
                    ReductionScheduler.moveToFront(slot, in: &trainOrder)
                    if needsFingerprintGuard {
                        // A clean acceptance in a non-constant bind region means leafSpans and the decoder are stale (sequence changed). Restart the repeat loop to recompute both before the remaining slots run.
                        restartLeafRange = true
                        break
                    }
                }
            } while restartLeafRange && legBudget.isExhausted == false
        }

        // Covariant value sweep: reduce bound-content values at intermediate bind depths.
        // DAG leaf positions miss values inside nested bind regions (for example, parent node values in a recursive bind generator like a binary heap). Shallow depths first so that deeper depths reduce in the correct context.
        // vSpans at depth D can include nested bind-inner positions whose reduction changes the inner bound structure, which belongs in base descent. The fingerprintGuard in each runAdaptive call catches this per-acceptance and rolls back the structural probe while preserving any earlier clean value reductions.
        let maxBindDepth = bindIndex?.maxBindDepth ?? 0
        if maxBindDepth >= 1, legBudget.isExhausted == false {
            for depth in stride(from: 1, through: maxBindDepth, by: 1) {
                guard legBudget.isExhausted == false else { break }
                dominance.invalidate()
                let depthContext = DecoderContext(
                    depth: .specific(depth),
                    bindIndex: bindIndex,
                    fallbackTree: fallbackTree,
                    strictness: .normal
                )
                let depthDecoder = SequenceDecoder.for(depthContext)
                let vSpans = spanCache.valueSpans(at: depth, from: sequence, bindIndex: bindIndex)
                let fSpans = spanCache.floatSpans(at: depth, from: sequence, bindIndex: bindIndex)

                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    var slotAccepted = false
                    // structureChanged: hasBind ensures accept() rebuilds bindIndex before the per-acceptance fingerprint guard recomputes the fingerprint. Without a fresh bindIndex, StructuralFingerprint.from uses stale depth information and may miss structural changes.
                    switch slot {
                    case .zeroValue where vSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            zeroValueEncoder, decoder: depthDecoder,
                            targets: .spans(vSpans), structureChanged: hasBind,
                            budget: &legBudget,
                            fingerprintGuard: prePhaseFingerprint,
                            convergedOrigins: cachedOrigins
                        )
                    case .binarySearchToZero where vSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            binarySearchToZeroEncoder, decoder: depthDecoder,
                            targets: .spans(vSpans), structureChanged: hasBind,
                            budget: &legBudget,
                            fingerprintGuard: prePhaseFingerprint,
                            convergedOrigins: cachedOrigins
                        )
                    case .binarySearchToTarget where vSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            binarySearchToTargetEncoder, decoder: depthDecoder,
                            targets: .spans(vSpans), structureChanged: hasBind,
                            budget: &legBudget,
                            fingerprintGuard: prePhaseFingerprint,
                            convergedOrigins: cachedOrigins
                        )
                    case .reduceFloat where fSpans.isEmpty == false:
                        slotAccepted = try runAdaptive(
                            reduceFloatEncoder, decoder: depthDecoder,
                            targets: .spans(fSpans), structureChanged: hasBind,
                            budget: &legBudget,
                            fingerprintGuard: prePhaseFingerprint,
                            convergedOrigins: cachedOrigins
                        )
                    default:
                        break
                    }
                    guard slotAccepted else { continue }
                    anyAccepted = true
                    ReductionScheduler.moveToFront(slot, in: &trainOrder)
                }
            }
        }

        // Redistribution (once at end of fibre descent).
        if legBudget.isExhausted == false {
            let redistContext = DecoderContext(
                depth: .global,
                bindIndex: bindIndex,
                fallbackTree: fallbackTree,
                strictness: .normal
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
        dag: ChoiceDependencyGraph?
    ) throws -> Bool {
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
        var anyAccepted = false
        var kleisliProbes = 0
        var kleisliMaterializations = 0

        for edge in edges {
            guard budget > 0 else { break }
            compositionEdgesAttempted += 1

            // Build fresh upstream and downstream point encoders.
            // Upstream: binary search toward simplest bind-inner value.
            // Downstream: fibre search — enumerates the downstream fibre
            // to find ANY failure, not minimize an existing one. After a lift,
            // the bound content is PRNG-filled and likely passes the property.
            // The downstream needs to discover a failure, not minimize one.
            let upstreamAdapter = LegacyEncoderAdapter(
                inner: BinarySearchToSemanticSimplestEncoder()
            )
            let downstreamEncoder = FibreCoveringEncoder()

            var composed = KleisliComposition(
                upstream: upstreamAdapter,
                downstream: downstreamEncoder,
                lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: fallbackTree ?? tree)),
                rollback: .atomic,
                upstreamRange: edge.upstreamRange,
                downstreamRange: edge.downstreamRange
            )

            // Run via manual loop (same pattern as runRelaxRound).
            var legBudget = ReductionScheduler.LegBudget(hardCap: min(budget, 100))

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
            composed.start(
                sequence: sequence,
                targets: .wholeSequence,
                convergedOrigins: nil
            )

            var lastAccepted = false
            while true {
                // Warm-start validation: before the composition advances to the
                // next upstream probe and initializes the downstream, validate any
                // pending convergence transfer from the previous downstream.
                if let pending = composed.pendingTransferOrigins,
                   let delta = composed.upstreamDelta, delta == 1
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
                    composed.setValidatedOrigins(allValid ? pending : nil)
                } else {
                    // First probe, delta > 1, or no pending origins: cold-start.
                    composed.setValidatedOrigins(nil)
                }

                guard let probe = composed.nextProbe(lastAccepted: lastAccepted) else { break }
                guard legBudget.isExhausted == false else { break }
                if collectStats { kleisliProbes += 1 }
                legBudget.recordMaterialization()

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
            if legBudget.used > 0, lastAccepted == false {
                futileCompositions += 1
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

        // Rollback: net result was not an improvement.
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
                guard case let .structural(.bindInner(regionIndex: downstreamRegion)) = dag.nodes[dependentNodeIndex].kind else {
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
                    let probeChoice = ChoiceValue.fromShortlexKey(value, tag: upstreamAxis.choiceTag)

                    // Create modified sequence with upstream set to candidate value.
                    var modified = sequence
                    modified[upstreamAxis.seqIdx] = .value(.init(
                        choice: probeChoice,
                        validRange: upstreamAxis.validRange,
                        isRangeExplicit: upstreamAxis.isRangeExplicit
                    ))

                    // Lightweight replay to discover downstream domain.
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
