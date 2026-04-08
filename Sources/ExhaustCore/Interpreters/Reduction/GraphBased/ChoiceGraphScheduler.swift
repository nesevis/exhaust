//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives scope-source-dispatched reduction until convergence or stall budget exhaustion.
///
/// Merges lazy ``ScopeSource`` iterators by yield, pulling from whichever has the highest-yield next scope. Dispatches to pure structural encoders (one probe) or search-based value encoders (multiple probes). On structural acceptance, rebuilds all sources from the new graph. On rejection, only the dispatched source advances.
///
/// - SeeAlso: ``ScopeSource``, ``ScopeSourceBuilder``, ``GraphEncoder``
enum ChoiceGraphScheduler {

    // MARK: - Entry Points

    /// Runs the graph-based reduction pipeline to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        try runCore(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: false,
            property: property
        ).reduced
    }

    /// Runs the graph-based reduction pipeline and returns both the result and accumulated statistics.
    static func runCollectingStats<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        try runCore(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: true,
            property: property
        )
    }

    // MARK: - Core Loop

    // swiftlint:disable function_parameter_count
    private static func runCore<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        collectStats: Bool,
        property: @escaping (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        // Re-materialize the initial tree with `materializePicks: true` so
        // non-selected branches at every pick site carry full minimized
        // subtrees. The tree we receive came from reflection, which only
        // includes the branch that actually produced the failing value; the
        // graph's branch-pivot / promotion / descendant-promotion encoders
        // need the alternative branches to have structure to pivot to.
        // Matches `BonsaiScheduler.runCore`'s branch projection bootstrap.
        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        if case let .success(_, fullTree, _) = Materializer.materialize(
            gen,
            prefix: sequence,
            mode: .exact,
            fallbackTree: initialTree,
            materializePicks: true
        ) {
            tree = fullTree
            sequence = ChoiceSequence(fullTree)
        }
        var output = initialOutput
        var stats = ReductionStats()
        var cycles = 0
        var stallBudget = config.maxStalls
        var rejectCache = Set<UInt64>()

        var graph = ChoiceGraph.build(from: tree)

        // Layer 7a lazy rematerialize: tracks whether the current graph
        // was rebuilt from a stripped tree (one produced by a decoder
        // call with `materializePicks: false`). When true, every pick
        // node's ``PickMetadata/branchElements`` contains only the
        // selected branch. The cycle loop's source-pulling iterations
        // check this flag before dispatching a path-changing operation
        // (one that reads inactive branches via
        // ``GraphReplacementEncoder``) and rematerialize on demand.
        // False at scheduler entry because the initial tree was just
        // re-materialized with `materializePicks: true` above.
        var graphIsStripped = false

        if collectStats {
            stats.graphNodeCount = graph.nodes.count
            stats.graphDependencyEdgeCount = graph.dependencyEdges.count
            stats.graphContainmentEdgeCount = graph.containmentEdges.count
            stats.graphSelfSimilarityEdgeCount = graph.selfSimilarityEdges.count
            stats.graphDeletionAntichainSize = graph.deletionAntichain.count
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_reducer_start",
                metadata: [
                    "seq_len": "\(sequence.count)",
                    "max_stalls": "\(config.maxStalls)",
                    "nodes": "\(graph.nodes.count)",
                ]
            )
        }

        // Scope rejection cache: tracks rejected structural operations
        // by position-scoped Zobrist hash. Naturally invalidates when
        // targeted values change. Cleared on structural acceptance.
        var scopeRejectionCache = ScopeRejectionCache()

        while stallBudget > 0 {
            cycles += 1
            let sequenceBeforeCycle = sequence

            // Partial Layer 5: the unconditional top-of-cycle rebuild has
            // been removed. The graph carries over from the previous cycle
            // already in sync with the live sequence and tree, because
            // every accepted probe in the previous cycle was either:
            //  - A value-only fast-path application: ``ChoiceGraph/apply(_:freshTree:)``
            //    mutated the graph in place to match the new sequence.
            //  - A bind-inner reshape, structural acceptance, or staleness
            //    detection acceptance: the cycle loop's mid-cycle rebuild
            //    path (or the staleness detection helper) immediately
            //    rebuilt the graph from the new tree.
            // The 1000-seed × 14-benchmark shadow run with a fatalError in
            // place of the warning never triggered, confirming that the
            // value-only fast path produces structurally identical results
            // to a fresh rebuild on the entire ECOOP suite.

            // Build scope sources from the carried-over graph.
            var sources = ScopeSourceBuilder.buildSources(from: graph)

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_start",
                    metadata: [
                        "cycle": "\(cycles)",
                        "seq_len": "\(sequence.count)",
                        "sources": "\(sources.count)",
                        "stall_budget": "\(stallBudget)",
                    ]
                )
            }

            var anyAccepted = false

            // Pull from highest-yield source until all exhausted.
            while true {
                // Find the source with the highest peekYield.
                guard let sourceIndex = highestYieldSourceIndex(sources) else {
                    break
                }

                // Pull the next scope from that source.
                guard let transformation = sources[sourceIndex].next(lastAccepted: false) else {
                    // Source exhausted — remove and continue.
                    sources.remove(at: sourceIndex)
                    continue
                }

                // Check precondition.
                guard transformation.precondition.isSatisfied(in: graph) else {
                    continue
                }

                // Skip structural scopes that were previously rejected
                // with identical values at the targeted positions.
                if scopeRejectionCache.isRejected(
                    operation: transformation.operation,
                    sequence: sequence,
                    graph: graph
                ) {
                    continue
                }

                // Layer 7a lazy rematerialize: a path-changing operation
                // (only ``GraphOperation/replace``) reads inactive branches
                // via ``PickMetadata/branchElements``. If the current graph
                // was rebuilt from a stripped tree (``graphIsStripped``
                // true), branchElements is incomplete and the encoder will
                // silently fail. Re-materialize the sequence with
                // `materializePicks: true`, rebuild the graph, refresh
                // sources, and restart the iteration. The current
                // transformation references node IDs from the stale graph
                // and is discarded — the next iteration pulls a fresh
                // transformation from the rebuilt sources.
                //
                // Non-path-changing operations (minimize, exchange, remove,
                // permute, migrate) do not read branchElements and run
                // safely against a stripped graph, so they bypass this
                // check entirely. The result is that we only pay the
                // rematerialize cost on cycles that actually exercise
                // branch pivot / descendant promotion / self-similar
                // replacement, instead of defensively on every rebuild.
                if graphIsStripped, transformation.operation.isPathChanging {
                    if case let .success(_, fullTree, _) = Materializer.materialize(
                        gen,
                        prefix: sequence,
                        mode: .exact,
                        fallbackTree: tree,
                        materializePicks: true
                    ) {
                        tree = fullTree
                    }
                    let oldConvergence = extractAllConvergence(from: graph)
                    graph = ChoiceGraph.build(from: tree)
                    transferConvergence(oldConvergence, to: graph)
                    stats.graphRebuilds += 1
                    sources = ScopeSourceBuilder.buildSources(from: graph)
                    graphIsStripped = false
                    continue
                }

                // Construct self-contained scope.
                let warmStarts = extractWarmStarts(from: graph)
                let scope = TransformationScope(
                    transformation: transformation,
                    baseSequence: sequence,
                    tree: tree,
                    graph: graph,
                    warmStartRecords: warmStarts
                )

                // Select encoder and run.
                var encoder = selectEncoder(for: transformation.operation)
                let outcome = try runProbeLoop(
                    encoder: &encoder,
                    scope: scope,
                    graph: graph,
                    sequence: &sequence,
                    tree: &tree,
                    output: &output,
                    gen: gen,
                    property: property,
                    rejectCache: &rejectCache,
                    stats: &stats,
                    collectStats: collectStats,
                    isInstrumented: isInstrumented
                )

                // Harvest convergence from value encoders.
                let convergence = encoder.convergenceRecords
                if convergence.isEmpty == false {
                    graph.recordConvergence(convergence)
                }

                if outcome.accepted {
                    anyAccepted = true

                    if outcome.requiresRebuild {
                        // Apply bailed out for at least one accepted probe
                        // (multi-bind reshape, structural mutation, etc.).
                        // Rebuild the graph from the live tree, refresh
                        // sources, and clear the scope rejection cache.
                        //
                        // Layer 7a: do NOT defensively rematerialize here.
                        // If the latest accepted probe stripped the tree,
                        // the rebuilt graph has incomplete branchElements
                        // — that is recorded via ``graphIsStripped`` and
                        // handled lazily by the rematerialize check at
                        // the top of the source-pulling iteration, only
                        // when a path-changing operation is about to
                        // dispatch. This avoids paying the materialize
                        // cost on cycles where branch pivot never fires.
                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
                        graphIsStripped = outcome.treeIsStripped
                        transferConvergence(oldConvergence, to: graph)
                        stats.graphRebuilds += 1
                        scopeRejectionCache.clear()
                        sources = ScopeSourceBuilder.buildSources(from: graph)

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "graph_structural_rebuild",
                                metadata: [
                                    "seq_len": "\(sequence.count)",
                                    "nodes": "\(graph.nodes.count)",
                                    "sources": "\(sources.count)",
                                ]
                            )
                        }
                    } else if outcome.requiresSourceRebuild {
                        // Layer 4 in-place reshape: graph is already in sync
                        // via apply, but the existing sources captured the
                        // old node set and miss any new leaves the splice
                        // added. Rebuild sources from the (already up-to-date)
                        // graph and clear convergence on the changed leaves.
                        //
                        // Do NOT clear the scope rejection cache. The cache
                        // is keyed by Zobrist hashes that incorporate the
                        // sequence positions of the targeted nodes. After a
                        // reshape, positions shift by the length delta — the
                        // *same* logical operation on the *same* logical
                        // leaves now hashes to a *different* value. Old cache
                        // entries don't collide with new probes; they sit as
                        // harmless orphans. Clearing the cache wastes the
                        // accumulated rejections from earlier in the same
                        // cycle and forces the encoder to re-decode probes
                        // it already tried.
                        sources = ScopeSourceBuilder.buildSources(from: graph)
                        clearConvergenceOnChangedLeaves(
                            for: transformation,
                            in: graph
                        )

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "graph_inplace_reshape",
                                metadata: [
                                    "seq_len": "\(sequence.count)",
                                    "nodes": "\(graph.nodes.count)",
                                    "sources": "\(sources.count)",
                                ]
                            )
                        }
                    } else {
                        // Every accepted probe was a value-only fast-path
                        // application that touched no node-set membership.
                        // Both graph and sources are still valid. Just
                        // clear convergence on the changed leaves; the
                        // scope rejection cache self-invalidates via hash
                        // change.
                        clearConvergenceOnChangedLeaves(
                            for: transformation,
                            in: graph
                        )
                    }
                } else {
                    // Rejection: record in scope cache for structural operations.
                    scopeRejectionCache.recordRejection(
                        operation: transformation.operation,
                        sequence: sequence,
                        graph: graph
                    )
                }
            }

            // Staleness detection: after all sources exhausted, probe
            // converged leaves at floor - 1 to detect stale convergence.
            if anyAccepted == false, allValuesConverged(in: sequence, graph: graph) {
                let stalenessResult = try detectStaleness(
                    sequence: &sequence,
                    tree: &tree,
                    output: &output,
                    graph: graph,
                    gen: gen,
                    property: property,
                    rejectCache: &rejectCache,
                    stats: &stats,
                    collectStats: collectStats,
                    isInstrumented: isInstrumented
                )
                if stalenessResult {
                    anyAccepted = true
                    // detectStaleness updates the sequence but only the
                    // convergence records on the graph; the graph's leaf
                    // values are now stale. With the top-of-cycle rebuild
                    // gone the carried-over graph would otherwise be out of
                    // sync, so rebuild here to restore the invariant before
                    // the next cycle.
                    //
                    // Layer 7a: ``detectStaleness`` always uses
                    // `materializePicks: false`, so the rebuilt graph is
                    // unconditionally stripped. Set the flag and let the
                    // lazy rematerialize check in the next cycle's
                    // source-pulling iteration handle it on demand.
                    let oldConvergence = extractAllConvergence(from: graph)
                    graph = ChoiceGraph.build(from: tree)
                    graphIsStripped = true
                    transferConvergence(oldConvergence, to: graph)
                    stats.graphRebuilds += 1
                    sources = ScopeSourceBuilder.buildSources(from: graph)
                }
            }

            // Cycle complete.
            let improved = sequence != sequenceBeforeCycle
            if improved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

            // Early exit: all values converged and no structural progress.
            let structurallyImproved = sequence.count < sequenceBeforeCycle.count
            if structurallyImproved == false,
               anyAccepted == false,
               allValuesConverged(in: sequence, graph: graph) {
                break
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_end",
                    metadata: [
                        "cycle": "\(cycles)",
                        "improved": "\(improved)",
                        "seq_len": "\(sequence.count)",
                        "total_mats": "\(stats.totalMaterializations)",
                    ]
                )
            }
        }

        if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "graph_reducer_complete",
                metadata: [
                    "cycles": "\(cycles)",
                    "seq_len": "\(sequence.count)",
                    "total_mats": "\(stats.totalMaterializations)",
                ]
            )
        }

        // Human-readable ordering pass: reorders type-homogeneous sibling groups into natural numeric order so seeds with the same multiset of values converge to the same canonical counterexample.
        let humanOrderingPass = HumanReadableOrderingPass()
        if let humanResult = humanOrderingPass.encode(
            gen: gen,
            sequence: sequence,
            tree: tree,
            property: property
        ) {
            sequence = humanResult.result.sequence
            tree = humanResult.result.tree
            output = humanResult.result.output
            if collectStats {
                stats.totalMaterializations += humanResult.materializations
                stats.encoderProbes[.humanOrderReorder, default: 0] += humanResult.materializations
            }
            if isInstrumented {
                ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
            }
        }

        stats.cycles = cycles
        return (reduced: (sequence, output), stats: stats)
    }
    // swiftlint:enable function_parameter_count

    // MARK: - Source Selection

    /// Returns the index of the source with the highest peekYield, or nil if all are exhausted.
    private static func highestYieldSourceIndex(_ sources: [any ScopeSource]) -> Int? {
        var bestIndex: Int?
        var bestYield: TransformationYield?
        for (index, source) in sources.enumerated() {
            guard let yield = source.peekYield else { continue }
            if let currentBest = bestYield {
                if yield < currentBest {
                    bestIndex = index
                    bestYield = yield
                }
            } else {
                bestIndex = index
                bestYield = yield
            }
        }
        return bestIndex
    }

    // MARK: - Encoder Selection

    /// Selects the appropriate encoder for a graph operation type.
    private static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
        switch operation {
        case .remove:
            return GraphRemovalEncoder()
        case .replace:
            return GraphReplacementEncoder()
        case .minimize:
            return GraphMinimizationEncoder()
        case .exchange:
            return GraphExchangeEncoder()
        case .permute:
            return GraphPermutationEncoder()
        case .migrate:
            return GraphMigrationEncoder()
        }
    }

    // MARK: - Probe Loop

    /// Outcome of a single ``runProbeLoop`` invocation.
    ///
    /// Three accepted states:
    ///
    /// - ``requiresRebuild`` true: at least one accepted probe set ``ChangeApplication/requiresFullRebuild``. The graph is stale; the cycle loop must do a full rebuild + source rebuild before the next dispatch.
    /// - ``requiresSourceRebuild`` true (and ``requiresRebuild`` false): at least one accepted probe was a successful in-place reshape that added or removed graph nodes (Layer 4). The graph is in sync via ``ChoiceGraph/apply(_:freshTree:)``, but the existing scope sources captured node IDs at construction time and do not know about the new nodes. The cycle loop must rebuild sources from the (already up-to-date) graph; the graph itself does not need a full rebuild.
    /// - both false: every accepted probe was a pure value-only fast-path application that touched no node-set membership. The graph and the existing sources are both still valid.
    ///
    /// ``treeIsStripped`` reports whether the *latest* accepted probe used `materializePicks: false`. The cycle loop reads it before any rebuild path: when true, the carried `tree` is missing inactive pick branches and must be re-materialized with `materializePicks: true` before ``ChoiceGraph/build(from:)``, otherwise the rebuilt graph's ``PickMetadata/branchElements`` would contain only the selected branch and silently break ``GraphReplacementEncoder``'s branch enumeration on the next cycle. False when no probe accepted, when only `materializePicks: true` probes accepted, or when the latest acceptance happened to be a non-stripped one.
    struct ProbeLoopOutcome {
        let accepted: Bool
        let requiresRebuild: Bool
        let requiresSourceRebuild: Bool
        let treeIsStripped: Bool
    }

    // swiftlint:disable function_parameter_count
    /// Runs an encoder's probe loop, accepting improvements.
    private static func runProbeLoop<Output>(
        encoder: inout any GraphEncoder,
        scope: TransformationScope,
        graph: ChoiceGraph,
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Output,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> ProbeLoopOutcome {
        encoder.start(scope: scope)

        var lastAccepted = false
        var anyAccepted = false
        var anyRequiresRebuild = false
        var anyRequiresSourceRebuild = false
        // Layer 7a: tracks whether the *latest* accepted probe used
        // `materializePicks: false`. The cycle loop reads it from the
        // outcome to decide whether the carried `tree` needs re-materializing
        // before any subsequent ``ChoiceGraph/build(from:)`` call. Only the
        // latest acceptance matters because each accepted probe overwrites
        // the tree state.
        var latestAcceptedTreeIsStripped = false
        var probeCount = 0
        var acceptCount = 0
        // Per-encoder rejection breakdown for the wasted-mats investigation
        // (Bonsai vs Graph mat-count gap). Cache hits cost zero materializations;
        // decoder rejections cost one materialization each. Aggregated into
        // `stats.encoderProbesAccepted` etc. at the end of the loop.
        var cacheHitCount = 0
        var decoderRejectCount = 0
        let baseHash = ZobristHash.hash(of: sequence)

        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = false

            let probeHash = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: sequence,
                probe: probe.candidate
            )
            if rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
            }

            let hasBind = sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
            // Layer 6 + Layer 7a: probes whose mutation does not change
            // which branch is selected at any pick site can skip
            // `materializePicks: true`. The graph's structural skeleton —
            // including non-selected pick branches — persists across
            // cycles via the in-place reshape path, so the decoder no
            // longer needs to re-materialize inactive branches on every
            // probe.
            //
            // Layer 6 covers value-only ``ProjectedMutation/leafValues(_:)``
            // with no reshape leaves. Layer 7a extends the same check to
            // ``ProjectedMutation/sequenceElementsRemoved(seqNodeID:removedNodeIDs:)``,
            // ``ProjectedMutation/sequenceElementsMigrated(sourceSeqID:receiverSeqID:movedNodeIDs:insertionOffset:)``,
            // and ``ProjectedMutation/siblingsSwapped(zipNodeID:idA:idB:)``
            // — none of these change branch selections, so any branch
            // pivot encoder dispatched on the next cycle still finds its
            // alternative branches in ``PickMetadata/branchElements``,
            // which is captured at graph construction time.
            //
            // Pivoting mutations (``ProjectedMutation/branchSelected(pickNodeID:newSelectedID:)``,
            // ``ProjectedMutation/selfSimilarReplaced(targetNodeID:donorNodeID:)``,
            // ``ProjectedMutation/descendantPromoted(ancestorPickNodeID:descendantPickNodeID:)``)
            // and reshape leafValues keep `materializePicks: true`
            // because the resulting tree feeds the splice path or future
            // branch pivots that need the inactive subtree content.
            //
            // Safety: when an accepted probe sets ``ChangeApplication/requiresFullRebuild``
            // true (which every Layer 7a structural case does until Layer 7
            // implements them in ``ChoiceGraph/apply(_:freshTree:)``), the
            // cycle loop's rebuild path at the call site re-materializes
            // the sequence with `materializePicks: true` before calling
            // ``ChoiceGraph/build(from:)``, so the rebuilt graph never
            // sees a stripped tree.
            let picksUnchanged: Bool
            switch probe.mutation {
            case let .leafValues(changes):
                picksUnchanged = changes.contains(where: \.mayReshape) == false
            case .sequenceElementsRemoved, .sequenceElementsMigrated, .siblingsSwapped:
                picksUnchanged = true
            case .branchSelected, .selfSimilarReplaced, .descendantPromoted:
                picksUnchanged = false
            }
            let materializePicks = picksUnchanged == false
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree, materializePicks: materializePicks)
                : .exact(materializePicks: materializePicks)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decode(
                candidate: probe.candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property,
                filterObservations: &filterObservations,
                precomputedHash: probeHash
            ) {
                sequence = result.sequence
                tree = result.tree
                output = result.output
                lastAccepted = true
                anyAccepted = true
                acceptCount += 1
                // Track whether the latest accepted probe stripped the
                // tree. The cycle loop reads this via ``ProbeLoopOutcome/treeIsStripped``
                // to decide whether to re-materialize before any rebuild.
                latestAcceptedTreeIsStripped = picksUnchanged

                // Partial Layer 5: route the encoder's mutation report
                // through ``ChoiceGraph/apply(_:freshTree:)``. When the
                // value-only fast path succeeds, the graph is mutated in
                // place and the cycle loop's mid-cycle rebuild is skipped.
                // When apply bails out (bind-inner reshape, all structural
                // cases until Layer 4 / Layer 7), `requiresFullRebuild` is
                // set and propagated up so the cycle loop falls back to a
                // full rebuild + source refresh.
                let application = graph.apply(probe.mutation, freshTree: tree)
                if application.requiresFullRebuild {
                    anyRequiresRebuild = true
                }
                // A successful in-place reshape adds or removes graph
                // nodes — the graph stays consistent via apply, but the
                // existing scope sources captured the old node set at
                // construction time and miss the new ones. Signal the
                // cycle loop to rebuild sources without rebuilding the
                // graph itself.
                if application.addedNodeIDs.isEmpty == false
                    || application.removedNodeIDs.isEmpty == false
                {
                    anyRequiresSourceRebuild = true
                }
                if isInstrumented, application.requiresFullRebuild == false {
                    let fresh = ChoiceGraph.build(from: tree)
                    if graph.structuralFingerprint != fresh.structuralFingerprint {
                        fatalError()
                        ExhaustLog.warning(
                            category: .reducer,
                            event: "graph_apply_shadow_mismatch",
                            metadata: [
                                "encoder": encoder.name.rawValue,
                                "live_fp": "\(graph.structuralFingerprint)",
                                "fresh_fp": "\(fresh.structuralFingerprint)",
                            ]
                        )
                    }
                }
            } else {
                rejectCache.insert(probeHash)
                decoderRejectCount += 1
            }

            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        if collectStats {
            stats.encoderProbes[encoder.name, default: 0] += probeCount
            stats.encoderProbesAccepted[encoder.name, default: 0] += acceptCount
            stats.encoderProbesRejectedByCache[encoder.name, default: 0] += cacheHitCount
            stats.encoderProbesRejectedByDecoder[encoder.name, default: 0] += decoderRejectCount
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_encoder_pass",
                metadata: [
                    "encoder": encoder.name.rawValue,
                    "probes": "\(probeCount)",
                    "accepted": "\(acceptCount)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        return ProbeLoopOutcome(
            accepted: anyAccepted,
            requiresRebuild: anyRequiresRebuild,
            requiresSourceRebuild: anyRequiresSourceRebuild,
            treeIsStripped: latestAcceptedTreeIsStripped
        )
    }
    // swiftlint:enable function_parameter_count

    // MARK: - Convergence

    /// Returns true when every leaf value is either at its reduction target or has a convergence record.
    private static func allValuesConverged(
        in sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            if currentBitPattern == targetBitPattern { continue }
            if metadata.convergedOrigin != nil { continue }
            return false
        }
        return true
    }

    /// Extracts warm-start convergence records from all leaf nodes.
    private static func extractWarmStarts(from graph: ChoiceGraph) -> [Int: ConvergedOrigin] {
        var records: [Int: ConvergedOrigin] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            records[range.lowerBound] = origin
        }
        return records
    }

    /// Extracts all convergence records with leaf metadata for transfer matching.
    private static func extractAllConvergence(from graph: ChoiceGraph) -> [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] {
        var records: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            let isConstant = isInStructurallyConstantContext(nodeID: nodeID, graph: graph)
            records[range.lowerBound] = (origin: origin, typeTag: metadata.typeTag, validRange: metadata.validRange, isStructurallyConstant: isConstant)
        }
        return records
    }

    /// Transfers convergence records from old graph positions to matching leaves in the new graph.
    ///
    /// Two-tier policy:
    /// - Leaves in structurally-constant bind subtrees (or outside any bind): match on position + typeTag only. The validRange may have changed but the materialiser handles clamping.
    /// - Leaves in non-constant bind subtrees: match on position + typeTag + validRange. The subtree was rebuilt — ranges may be different.
    private static func transferConvergence(
        _ records: [Int: (origin: ConvergedOrigin, typeTag: TypeTag, validRange: ClosedRange<UInt64>?, isStructurallyConstant: Bool)],
        to graph: ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard let oldRecord = records[range.lowerBound] else { continue }

            // Type tag must always match.
            guard oldRecord.typeTag == metadata.typeTag else { continue }

            // Two-tier: constant context requires only position + typeTag.
            // Non-constant requires validRange match too.
            if oldRecord.isStructurallyConstant == false {
                guard oldRecord.validRange == metadata.validRange else { continue }
            }

            graph.recordConvergence([range.lowerBound: oldRecord.origin])
        }
    }

    /// Checks whether a leaf node is in a structurally-constant context (all ancestor binds are structurally constant, or not in any bind).
    private static func isInStructurallyConstantContext(nodeID: Int, graph: ChoiceGraph) -> Bool {
        var current = nodeID
        while let parentID = graph.nodes[current].parent {
            if case let .bind(metadata) = graph.nodes[parentID].kind {
                if metadata.isStructurallyConstant == false {
                    // Check if this leaf is in the bound subtree (not the inner).
                    let boundChildID = graph.nodes[parentID].children[metadata.boundChildIndex]
                    if let boundRange = graph.nodes[boundChildID].positionRange,
                       let leafRange = graph.nodes[nodeID].positionRange,
                       boundRange.contains(leafRange.lowerBound) {
                        return false
                    }
                }
            }
            current = parentID
        }
        return true
    }


    // MARK: - Staleness Detection

    // swiftlint:disable function_parameter_count
    /// Probes each converged leaf at `floor - 1` to detect stale convergence bounds.
    ///
    /// If the property still fails at floor - 1, the convergence record was stale — the previous search stopped too early. Clears the stale record so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    private static func detectStaleness<Output>(
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Output,
        graph: ChoiceGraph,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> Bool {
        var anyStale = false
        // Per-encoder breakdown for the wasted-mats investigation.
        // The probe count here is bounded by the number of converged
        // leaves. Cache hits and decoder rejections both apply.
        var stalenessProbeCount = 0
        var stalenessAcceptCount = 0
        var stalenessCacheHitCount = 0
        var stalenessDecoderRejectCount = 0
        defer {
            if collectStats {
                stats.encoderProbes[.graphStaleness, default: 0] += stalenessProbeCount
                stats.encoderProbesAccepted[.graphStaleness, default: 0] += stalenessAcceptCount
                stats.encoderProbesRejectedByCache[.graphStaleness, default: 0] += stalenessCacheHitCount
                stats.encoderProbesRejectedByDecoder[.graphStaleness, default: 0] += stalenessDecoderRejectCount
            }
        }

        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            // Probe floor - 1 in bit-pattern space. The minimization
            // encoder searches in bit-pattern space (directional), so
            // convergence bounds are bit patterns and floor - 1 is the
            // next adjacent value in the same search direction.
            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let probeValue = origin.bound - 1
            var candidate = sequence
            candidate[range.lowerBound] = candidate[range.lowerBound]
                .withBitPattern(probeValue)
            guard candidate.shortLexPrecedes(sequence) else { continue }

            stalenessProbeCount += 1

            let probeHash = ZobristHash.incrementalHash(
                baseHash: ZobristHash.hash(of: sequence),
                baseSequence: sequence,
                probe: candidate
            )
            if rejectCache.contains(probeHash) {
                stalenessCacheHitCount += 1
                continue
            }

            let hasBind = sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
            // Layer 6: ``detectStaleness`` rewrites a single converged
            // leaf's bit pattern at `floor - 1` and re-runs the materializer.
            // By construction this is a pure value-only probe — no bind
            // reshape, no structural pivot — so `materializePicks: false`
            // is safe and avoids the per-probe cost of re-materializing
            // non-selected pick branches. The lazy rematerialize check
            // in the cycle loop covers any path-changing operation that
            // needs full branch metadata after a stale acceptance.
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree, materializePicks: false)
                : .exact(materializePicks: false)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decode(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property,
                filterObservations: &filterObservations,
                precomputedHash: probeHash
            ) {
                sequence = result.sequence
                tree = result.tree
                output = result.output
                anyStale = true
                stalenessAcceptCount += 1

                // Clear the stale convergence record.
                graph.recordConvergence([range.lowerBound: ConvergedOrigin(
                    bound: probeValue,
                    signal: .monotoneConvergence,
                    configuration: origin.configuration,
                    cycle: origin.cycle
                )])

                if isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "staleness_detected",
                        metadata: [
                            "position": "\(range.lowerBound)",
                            "old_floor": "\(origin.bound)",
                            "new_floor": "\(probeValue)",
                        ]
                    )
                }
            } else {
                rejectCache.insert(probeHash)
                stalenessDecoderRejectCount += 1
            }

            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        return anyStale
    }
    // swiftlint:enable function_parameter_count

    // MARK: - Convergence Invalidation

    /// Clears convergence records on leaves whose values were changed by a value transformation.
    ///
    /// Exchange (redistribution) changes leaf values but doesn't invalidate convergence records. Without clearing, the minimization source sees "converged" leaves and emits zero probes, even though the values are now different from when convergence was recorded.
    private static func clearConvergenceOnChangedLeaves(
        for transformation: GraphTransformation,
        in graph: ChoiceGraph
    ) {
        let leafNodeIDs: [Int]
        switch transformation.operation {
        case let .exchange(scope):
            switch scope {
            case let .redistribution(redistScope):
                leafNodeIDs = redistScope.pairs.flatMap { [$0.sourceNodeID, $0.sinkNodeID] }
            case let .tandem(tandemScope):
                leafNodeIDs = tandemScope.groups.flatMap(\.leafNodeIDs)
            }
        default:
            return
        }

        // Clear convergence on each affected leaf by recording a nil-equivalent.
        // The graph stores convergence on ChooseBitsMetadata — we need to clear it
        // by removing the convergedOrigin.
        for leafNodeID in leafNodeIDs {
            guard case var .chooseBits(metadata) = graph.nodes[leafNodeID].kind else { continue }
            guard metadata.convergedOrigin != nil else { continue }
            guard let range = graph.nodes[leafNodeID].positionRange else { continue }
            metadata.convergedOrigin = nil
            graph.nodes[leafNodeID] = ChoiceGraphNode(
                id: graph.nodes[leafNodeID].id,
                kind: .chooseBits(metadata),
                positionRange: graph.nodes[leafNodeID].positionRange,
                children: graph.nodes[leafNodeID].children,
                parent: graph.nodes[leafNodeID].parent
            )
        }
    }

}

// MARK: - Scope Rejection Cache

/// Deterministic duplicate detection for structural graph operations using position-scoped Zobrist hashes.
///
/// For each rejected structural operation, computes a hash from the operation discriminator and the ``ZobristHash`` contributions at the targeted positions. The hash naturally invalidates when any targeted value changes — no explicit dirty tracking needed.
///
/// Cleared on structural acceptance (graph rebuild changes positions). Persists across cycles for value-only changes.
struct ScopeRejectionCache {
    private var rejectedHashes = Set<UInt64>()

    /// Records a rejected structural transformation.
    mutating func recordRejection(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        if let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) {
            rejectedHashes.insert(hash)
        }
    }

    /// Returns true if this transformation was previously rejected and the targeted values have not changed.
    func isRejected(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        guard let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) else {
            return false
        }
        return rejectedHashes.contains(hash)
    }

    /// Clears all cached rejections. Called on structural acceptance (graph rebuild).
    mutating func clear() {
        rejectedHashes.removeAll(keepingCapacity: true)
    }

    /// Computes a deterministic Zobrist-based hash from the operation discriminator and the values at targeted positions.
    ///
    /// Returns nil for search-based operations (minimize, exchange) whose outcomes are nondeterministic.
    private func scopeHash(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> UInt64? {
        guard let nodeIDs = operation.affectedNodeIDs(in: graph) else {
            return nil
        }

        // Operation-type discriminator to avoid collisions between
        // different operations targeting the same positions.
        var hash: UInt64 = switch operation {
        case .remove: 0xA1B2_C3D4_E5F6_0718
        case .replace: 0x1827_3645_5463_7281
        case .permute: 0x9182_7364_5546_3728
        case .migrate: 0x6372_8190_A0B0_C0D0
        case .minimize, .exchange: 0
        }

        // Mix in Zobrist contributions at each targeted position.
        for nodeID in nodeIDs {
            guard nodeID < graph.nodes.count,
                  let range = graph.nodes[nodeID].positionRange else {
                continue
            }
            for position in range {
                guard position < sequence.count else { break }
                hash ^= ZobristHash.contribution(at: position, sequence[position])
            }
        }

        return hash
    }
}
