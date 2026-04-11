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
        // Erase ``gen`` once at the runner boundary so the entire probe loop operates on a single non-generic ``ReflectiveGenerator<Any>``. The wrapped property closure casts ``Any`` back to ``Output`` exactly once per probe, where the original typed property is invoked. This collapses the per-Output-type generic specialization that was dominating runtime metadata cache traffic.
        let erasedGen = gen.erase()
        let wrappedProperty: (Any) -> Bool = { property($0 as! Output) }
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            erasedGen,
            prefix: sequence,
            mode: .exact,
            fallbackTree: initialTree,
            materializePicks: true
        ) {
            tree = fullTree
            sequence = ChoiceSequence(fullTree)
        }
        // Hold ``output`` as ``Any`` internally so it can be passed to the non-generic ``runProbeLoop`` and ``detectStaleness``. Cast back to ``Output`` at the very end before returning.
        var output: Any = initialOutput
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

        // Per-cycle blocklist for kleisli fibre dispatches. Each kleisli
        // composition runs a generator lift per upstream probe and a fibre
        // search per lift, all expensive operations that don't benefit from
        // the probe-level reject cache. After the first dispatch within a
        // cycle, the upstream encoder has explored its full search space
        // (up to ``GraphComposedEncoder/upstreamBudget``); re-dispatching
        // after a structural acceptance just re-runs the same upstream
        // exploration. Bonsai's runKleisliExploration sidesteps this by
        // running once per cycle as a separate phase. We mirror that here
        // by tracking dispatched bind node IDs and skipping repeats until
        // the next cycle, when the set is cleared.
        var kleisliDispatchedThisCycle = Set<Int>()

        // Per-bind-node Kleisli stall counter. Incremented when a Kleisli dispatch produces zero accepts. Reset on any acceptance. Decays the upstream probe budget: `max(1, 15 >> stalls)` — 15, 7, 3, 1 over consecutive fruitless dispatches.
        var kleisliStallCount: [Int: Int] = [:]

        // Migration probe budget. Migration on coupled generators (for example, Bound5) has a 0% acceptance rate — the constraint prevents element transfer between sequences. After 10+ cumulative emits with zero accepts, cap migration at 3 probes per cycle to avoid burning materializations on a structurally futile operation.
        var migrationEmits = 0
        var migrationAccepts = 0
        var migrationCycleBudget: Int? = nil

        while stallBudget > 0 {
            cycles += 1
            kleisliDispatchedThisCycle.removeAll(keepingCapacity: true)
            if migrationAccepts == 0, migrationEmits >= 10 {
                migrationCycleBudget = 3
            } else {
                migrationCycleBudget = nil
            }
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

                // Kleisli fibre scopes are deferred to stall cycles. Two skip rules
                // protect against the cost of running the composition unnecessarily:
                //
                // 1. Per-cycle de-duplication: each kleisli fibre composition runs an
                //    upstream search whose internal state is recreated on every dispatch
                //    and a generator lift per upstream probe — neither benefits from the
                //    probe-level reject cache. After the first dispatch within a cycle
                //    the second and third dispatches add little value at high cost.
                //
                // 2. Stall-cycle gating: if any non-kleisli encoder has already accepted
                //    progress in this cycle, the kleisli composition is redundant — the
                //    cheaper encoders are still finding improvements and the next cycle
                //    will re-evaluate. Kleisli only fires in cycles where the cheap
                //    encoders couldn't make progress, mirroring Bonsai's Stage-2 design
                //    where ``runKleisliExploration`` is the explicit fallback after
                //    ``runFibreDescent`` exhausts.
                if case let .minimize(.kleisliFibre(fibreScope)) = transformation.operation {
                    if kleisliDispatchedThisCycle.contains(fibreScope.bindNodeID) {
                        continue
                    }
                    if anyAccepted {
                        continue
                    }
                }

                // Migration cycle budget: skip if the budget has been exhausted.
                if case .migrate = transformation.operation,
                   let budget = migrationCycleBudget, budget <= 0
                {
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
                    if case let .success(_, fullTree, _) = Materializer.materializeAny(
                        erasedGen,
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

                // Select encoder and run. Kleisli fibre scopes route through the
                // generic ``GraphComposedEncoder`` primitive constructed at this call
                // site (where Output and gen are in scope) rather than the non-generic
                // ``selectEncoder(for:)`` switch.
                var encoder: any GraphEncoder
                if case let .minimize(.kleisliFibre(fibreScope)) = transformation.operation {
                    let stalls = kleisliStallCount[fibreScope.bindNodeID, default: 0]
                    let decayedBudget = max(1, 15 >> stalls)
                    encoder = Self.makeKleisliComposition(
                        fibreScope: fibreScope,
                        scope: scope,
                        gen: erasedGen,
                        upstreamBudget: decayedBudget
                    )
                } else {
                    encoder = Self.selectEncoder(for: transformation.operation)
                }
                // Mark the kleisli edge as dispatched for this cycle so the
                // per-cycle skip above blocks repeat dispatches after any
                // structural acceptance triggers a source rebuild.
                if case let .minimize(.kleisliFibre(fibreScope)) = transformation.operation {
                    kleisliDispatchedThisCycle.insert(fibreScope.bindNodeID)
                }
                let outcome = try runProbeLoop(
                    encoder: &encoder,
                    scope: scope,
                    graph: graph,
                    sequence: &sequence,
                    tree: &tree,
                    output: &output,
                    gen: erasedGen,
                    property: wrappedProperty,
                    rejectCache: &rejectCache,
                    stats: &stats,
                    collectStats: collectStats,
                    isInstrumented: isInstrumented
                )

                // Harvest convergence from value encoders. The encoder's
                // ``convergenceRecords`` is keyed by graph nodeID (so it
                // survives in-pass position shifts triggered by
                // ``GraphEncoder/refreshScope(graph:sequence:)``); the
                // graph writes them through the matching nodeID-keyed
                // overload to skip the O(N) per-record positional walk.
                let convergence = encoder.convergenceRecords
                if convergence.isEmpty == false {
                    graph.recordConvergence(byNodeID: convergence)
                }

                // Update migration history and cycle budget.
                if case .migrate = transformation.operation {
                    migrationEmits += outcome.probeCount
                    migrationAccepts += outcome.acceptCount
                    if var budget = migrationCycleBudget {
                        budget -= outcome.probeCount
                        migrationCycleBudget = budget
                    }
                }

                // Kleisli stall tracking: increment the per-bind-node counter when a dispatch produces zero accepts, reset on any acceptance. The stall count decays the upstream budget on subsequent dispatches.
                if case let .minimize(.kleisliFibre(fibreScope)) = transformation.operation {
                    if outcome.acceptCount > 0 {
                        kleisliStallCount[fibreScope.bindNodeID] = 0
                    } else {
                        kleisliStallCount[fibreScope.bindNodeID, default: 0] += 1
                    }
                }

                if outcome.accepted {
                    anyAccepted = true

                    // Force a full graph rebuild after every accepted kleisli composition
                    // dispatch. The composition's repeated bind reshapes accumulate
                    // partial-rebuild state on the live graph that the shadow check has
                    // observed diverging from a fresh build (`graph_apply_shadow_mismatch`),
                    // and which causes downstream encoders to crash on stale leaf positions.
                    // Until the in-place reshape path is fixed for chained applications,
                    // the safe option is to rebuild the graph from the live tree after the
                    // composition exits.
                    let isKleisliFibre = switch transformation.operation {
                    case .minimize(.kleisliFibre):
                        true
                    default:
                        false
                    }

                    if outcome.requiresRebuild || isKleisliFibre {
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
                        // For Kleisli rebuilds, the upstream bind-inner changed value,
                        // so any convergence floors recorded for downstream leaves under
                        // the old upstream value are now stale — the failure threshold
                        // in n-space may have shifted. Save the bound subtree's position
                        // range before the rebuild so we can clear those floors after
                        // transferConvergence has run.
                        var kleisliBoundPositionRange: ClosedRange<Int>? = nil
                        if isKleisliFibre,
                           case let .minimize(.kleisliFibre(fs)) = transformation.operation,
                           fs.bindNodeID < graph.nodes.count,
                           case let .bind(bm) = graph.nodes[fs.bindNodeID].kind,
                           graph.nodes[fs.bindNodeID].children.count > bm.boundChildIndex
                        {
                            let boundChildID = graph.nodes[fs.bindNodeID].children[bm.boundChildIndex]
                            kleisliBoundPositionRange = graph.nodes[boundChildID].positionRange
                        }

                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
                        graphIsStripped = outcome.treeIsStripped
                        transferConvergence(oldConvergence, to: graph)

                        // Clear stale downstream convergence after Kleisli rebuild.
                        if let boundRange = kleisliBoundPositionRange {
                            for nodeID in graph.leafNodes {
                                guard let nodeRange = graph.nodes[nodeID].positionRange else { continue }
                                guard boundRange.contains(nodeRange.lowerBound) else { continue }
                                guard case var .chooseBits(md) = graph.nodes[nodeID].kind else { continue }
                                guard md.convergedOrigin != nil else { continue }
                                md.convergedOrigin = nil
                                graph.nodes[nodeID] = ChoiceGraphNode(
                                    id: graph.nodes[nodeID].id,
                                    kind: .chooseBits(md),
                                    positionRange: graph.nodes[nodeID].positionRange,
                                    children: graph.nodes[nodeID].children,
                                    parent: graph.nodes[nodeID].parent
                                )
                            }
                        }
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
                    gen: erasedGen,
                    property: wrappedProperty,
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
               allValuesConverged(in: sequence, graph: graph)
            {
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
        // swiftlint:disable:next force_cast
        let typedOutput = output as! Output
        return (reduced: (sequence, typedOutput), stats: stats)
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
    ///
    /// Kleisli fibre minimization scopes are not handled here because they need the typed generator at construction time. The dispatch site in ``runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` builds them via ``makeKleisliComposition(fibreScope:scope:gen:)`` instead.
    private static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
        switch operation {
        case .remove:
            GraphRemovalEncoder()
        case .replace:
            GraphReplacementEncoder()
        case .minimize:
            GraphMinimizationEncoder()
        case .exchange:
            GraphExchangeEncoder()
        case .permute:
            GraphPermutationEncoder()
        case .migrate:
            GraphMigrationEncoder()
        }
    }

    // MARK: - Kleisli Composition Construction

    /// Builds a ``GraphComposedEncoder`` for a kleisli fibre scope.
    ///
    /// The upstream encoder is a ``GraphMinimizationEncoder`` operating on a synthesised one-leaf integer scope targeting the fibre's ``KleisliFibreScope/upstreamLeafNodeID``. The downstream encoder is another ``GraphMinimizationEncoder`` started by the lift closure on the lifted graph's bound-subtree leaves. The lift materialises each upstream candidate through `gen`, copies the parent graph, applies the upstream change to the copy via ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)``, and constructs the downstream scope on the resulting graph.
    ///
    /// - Parameters:
    ///   - fibreScope: The kleisli fibre scope from the source pipeline.
    ///   - scope: The dispatched ``TransformationScope``. Used to seed the upstream encoder's one-leaf scope and to provide the parent tree as the lift's fallback.
    ///   - gen: The generator. Captured by the lift closure for materialisation.
    private static func makeKleisliComposition(
        fibreScope: KleisliFibreScope,
        scope: TransformationScope,
        gen: ReflectiveGenerator<Any>,
        upstreamBudget: Int = 15
    ) -> any GraphEncoder {
        // Synthesise the upstream scope: a one-leaf integer minimization on the
        // bind-inner. ``mayReshapeOnAcceptance`` is false here because the
        // composition synthesises the reshape change in ``GraphComposedEncoder/wrap``
        // when wrapping each downstream probe — the upstream encoder produces a
        // pure value-only mutation and the composition flips ``mayReshape`` on
        // its way out.
        let upstreamLeafEntry = LeafEntry(
            nodeID: fibreScope.upstreamLeafNodeID,
            mayReshapeOnAcceptance: false
        )
        let upstreamScope = TransformationScope(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: [upstreamLeafEntry],
                    batchZeroEligible: false
                ))),
                yield: scope.transformation.yield,
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            baseSequence: scope.baseSequence,
            tree: scope.tree,
            graph: scope.graph,
            warmStartRecords: [:]
        )
        // Upstream: pure binary search over the bind-inner leaf, no inline linear
        // scan or cross-zero phases. ``GraphMinimizationEncoder``'s extra phases
        // are wasted in a kleisli context — every upstream probe spawns one lift
        // and a full downstream search, so the standalone encoder's recovery
        // strategies multiply the cost without finding more failures.
        let upstreamEncoder = PreStartedAdapter(
            inner: GraphBinarySearchEncoder(),
            scope: upstreamScope
        )
        // Downstream: choose encoder based on fibre dimensionality.
        // Single-leaf fibres use binary search — the covering encoder requires ≥ 2 parameters
        // for pairwise covering and falls through with zero probes for large single-parameter
        // domains. Binary search converges in O(log domain) steps and correctly handles the
        // cross-zero phase for signed types, finding the minimum failing value directly.
        // Multi-leaf fibres use FibreCoveringEncoder to discover failures across combinations.
        let downstreamEncoder: any GraphEncoder = fibreScope.downstreamNodeIDs.count == 1
            ? GraphBinarySearchEncoder()
            : GraphFibreCoveringEncoder()

        let lift: (EncoderProbe, TransformationScope) -> TransformationScope? = { upstreamProbe, parent in
            Self.kleisliFibreLift(
                upstreamProbe: upstreamProbe,
                parent: parent,
                fibreScope: fibreScope,
                gen: gen
            )
        }

        return GraphComposedEncoder(
            name: .graphKleisliFibre,
            upstream: upstreamEncoder,
            downstream: downstreamEncoder,
            upstreamBudget: upstreamBudget,
            lift: lift
        )
    }

    /// Lifts an upstream probe into a downstream ``TransformationScope`` for the kleisli fibre composition.
    ///
    /// 1. Materialises the upstream candidate through `gen` to obtain the new fibre's choice tree.
    /// 2. Copies the parent graph and applies the upstream change to the copy as a reshape (`mayReshape: true`), so ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` splices the rebuilt bound subtree from the freshTree on the throwaway copy. Falls back to a full ``ChoiceGraph/build(from:)`` if the partial path bails.
    /// 3. Locates the bind's bound child in the lifted graph and collects its descendant leaves as the downstream search range.
    /// 4. Constructs an integer-leaves minimization scope on the lifted graph; the downstream encoder operates on it without knowing it is downstream.
    private static func kleisliFibreLift(
        upstreamProbe: EncoderProbe,
        parent: TransformationScope,
        fibreScope: KleisliFibreScope,
        gen: ReflectiveGenerator<Any>
    ) -> TransformationScope? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        // Read the proposed upstream value for instrumentation.
        let upstreamSeqIndex = parent.graph.nodes[fibreScope.upstreamLeafNodeID].positionRange?.lowerBound
        let upstreamProposedBP: UInt64? = upstreamSeqIndex.flatMap { idx in
            idx < upstreamProbe.candidate.count
                ? upstreamProbe.candidate[idx].value?.choice.bitPattern64
                : nil
        }

        // 1. Materialise through the generator to get the new fibre. Use guided mode
        //    so that downstream coordinates outside the new range get re-resolved from
        //    the fallback tree (or PRNG when the fallback has no info) instead of
        //    being rejected. The upstream candidate carries the *previous* downstream
        //    values, which are typically out-of-range for the new upstream value
        //    (Coupling: dropping `n` from 2 to 1 makes the array element value `2`
        //    out-of-range for the new `int(in: 0...1)` element generator). Mirrors
        //    ``ReductionState/compositionDescriptors``'s lift configuration.
        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            gen,
            prefix: upstreamProbe.candidate,
            mode: .guided(seed: 0, fallbackTree: parent.tree),
            fallbackTree: parent.tree,
            materializePicks: true
        ) else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_lift_failed",
                    metadata: [
                        "upstream_bp": upstreamProposedBP.map { "\($0)" } ?? "nil",
                        "candidate_len": "\(upstreamProbe.candidate.count)",
                    ]
                )
            }
            return nil
        }

        // 2. Build a reshape change from the upstream's mutation. The upstream
        //    encoder reports a value-only LeafChange (mayReshape: false); we lift
        //    it to mayReshape: true so applyBindReshape rebuilds the bound subtree.
        guard case let .leafValues(upstreamChanges) = upstreamProbe.mutation,
              let upstreamChange = upstreamChanges.first
        else {
            return nil
        }
        let reshapeChange = LeafChange(
            leafNodeID: upstreamChange.leafNodeID,
            newValue: upstreamChange.newValue,
            mayReshape: true
        )

        // 3. Copy the parent graph and apply the reshape on the copy. COW means
        //    only the bind subtree region is duplicated; the rest of the graph
        //    stays shared with the parent.
        let copy = parent.graph.copy()
        let application = copy.apply(.leafValues([reshapeChange]), freshTree: freshTree)

        // 4. Fall back to a full rebuild if applyBindReshape bailed (multi-pick,
        //    structural mismatch, missing metadata). Same fallback the live accept
        //    path uses; we just absorb it in the lift instead.
        let liftedGraph: ChoiceGraph = application.requiresFullRebuild
            ? ChoiceGraph.build(from: freshTree)
            : copy

        // 5. Find the bound child of the kleisli bind in the lifted graph, then
        //    collect its descendant leaves as the downstream search range.
        guard fibreScope.bindNodeID < liftedGraph.nodes.count,
              case let .bind(metadata) = liftedGraph.nodes[fibreScope.bindNodeID].kind,
              liftedGraph.nodes[fibreScope.bindNodeID].children.count > metadata.boundChildIndex
        else {
            return nil
        }
        let boundChildID = liftedGraph.nodes[fibreScope.bindNodeID].children[metadata.boundChildIndex]
        guard let boundRange = liftedGraph.nodes[boundChildID].positionRange else {
            return nil
        }

        let downstreamLeaves = liftedGraph.leafNodes.filter { leafID in
            guard let range = liftedGraph.nodes[leafID].positionRange else { return false }
            return boundRange.contains(range.lowerBound)
        }
        guard downstreamLeaves.isEmpty == false else { return nil }

        // 6. Build the downstream scope as a plain integer-leaves minimization on
        //    the lifted graph. The downstream encoder doesn't know it's downstream.
        let liftedSequence = ChoiceSequence(freshTree)
        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "kleisli_lift_built",
                metadata: [
                    "upstream_bp": upstreamProposedBP.map { "\($0)" } ?? "nil",
                    "parent_seq_len": "\(parent.baseSequence.count)",
                    "lifted_seq_len": "\(liftedSequence.count)",
                    "downstream_leaves": "\(downstreamLeaves.count)",
                    "bound_range": "\(boundRange.lowerBound)...\(boundRange.upperBound)",
                    "rebuild_fallback": "\(application.requiresFullRebuild)",
                ]
            )
        }
        return TransformationScope(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(ValueMinimizationScope(
                    leaves: downstreamLeaves.map {
                        LeafEntry(nodeID: $0, mayReshapeOnAcceptance: false)
                    },
                    batchZeroEligible: downstreamLeaves.count > 1
                ))),
                yield: parent.transformation.yield,
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ),
            baseSequence: liftedSequence,
            tree: freshTree,
            graph: liftedGraph,
            warmStartRecords: [:]
        )
    }

    // MARK: - Pre-Started Adapter

    /// Wraps a ``GraphEncoder`` so its ``GraphEncoder/start(scope:)`` always uses a pre-supplied scope instead of the one passed by the caller.
    ///
    /// Used by ``makeKleisliComposition(fibreScope:scope:gen:)`` so that the upstream encoder of a ``GraphComposedEncoder`` operates on a synthesised one-leaf integer scope rather than the kleisli fibre scope the composition was started with. The composition's ``GraphComposedEncoder/start(scope:)`` will pass the original parent scope to its upstream; the adapter swaps it for the synthesised one before forwarding to the inner encoder.
    private struct PreStartedAdapter: GraphEncoder {
        var name: EncoderName {
            inner.name
        }

        var requiresExactDecoder: Bool {
            inner.requiresExactDecoder
        }

        private var inner: any GraphEncoder
        private let scope: TransformationScope

        init(inner: any GraphEncoder, scope: TransformationScope) {
            self.inner = inner
            self.scope = scope
        }

        mutating func start(scope _: TransformationScope) {
            inner.start(scope: scope)
        }

        mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
            inner.nextProbe(lastAccepted: lastAccepted)
        }

        var convergenceRecords: [Int: ConvergedOrigin] {
            inner.convergenceRecords
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
        let probeCount: Int
        let acceptCount: Int
    }

    // swiftlint:disable function_parameter_count
    /// Runs an encoder's probe loop, accepting improvements.
    private static func runProbeLoop(
        encoder: inout any GraphEncoder,
        scope: TransformationScope,
        graph: ChoiceGraph,
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
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
        // Bind status is structural — value-only mutations within the probe
        // loop cannot add or remove bind markers. Hoisted to avoid an O(N)
        // scan on every probe iteration.
        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = false
            // True when this probe's acceptance structurally mutated the graph
            // (in-place reshape that added/removed nodes, or any change that
            // forced ``ChangeApplication/requiresFullRebuild``). The encoder's
            // ``IntegerState/leafPositions`` (and equivalent caches in float
            // and exchange encoders) are built once at ``start(scope:)`` and
            // are no longer valid against the live graph after such a
            // mutation. The scheduler calls ``encoder.refreshScope`` at the
            // bottom of the iteration when this is true so the encoder can
            // re-derive its scope state in place against the post-mutation
            // graph. See ExhaustDocs/graph-reducer-position-drift-bug.md.
            var mutatedStructurally = false

            let probeHash = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: sequence,
                probe: probe.candidate
            )
            if rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
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
            let picksUnchanged = switch probe.mutation {
            case let .leafValues(changes):
                changes.contains(where: \.mayReshape) == false
            case .sequenceElementsRemoved, .sequenceElementsMigrated, .siblingsSwapped:
                true
            case .branchSelected, .selfSimilarReplaced, .descendantPromoted:
                false
            }
            let materializePicks = picksUnchanged == false
            // Composed encoders (kleisli fibre) emit post-lift candidates whose
            // bound subtree differs from the parent ``tree``. Guided decoding
            // would substitute stale fallback content; force the exact decoder
            // when the encoder requests it.
            let preferExact = encoder.requiresExactDecoder || hasBind == false
            let decoder: SequenceDecoder = preferExact
                ? .exact(materializePicks: materializePicks)
                : .guided(fallbackTree: tree, materializePicks: materializePicks)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
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

                // Composed encoders (``GraphComposedEncoder``) skip the
                // in-place ``ChoiceGraph/apply(_:freshTree:)`` path entirely.
                // The dispatch site forces a full ``ChoiceGraph/build(from:)``
                // rebuild after every kleisli pass anyway (see the
                // `isKleisliFibre || outcome.requiresRebuild` branch in
                // ``runCore``), which discards any in-place mutations the
                // probe loop would have made. Calling ``applyBindReshape``
                // on every accepted probe is pure waste — for BinaryHeap
                // that was 250K applyBindReshape calls per 1000-seed run,
                // each tombstoning the old bound subtree and splicing the
                // new one, only to be thrown away seconds later by the
                // post-pass rebuild.
                //
                // Standard encoders still take the in-place fast path so
                // value-only acceptances don't pay the rebuild cost.
                let application: ChangeApplication
                if encoder.requiresExactDecoder {
                    application = ChangeApplication()
                    anyRequiresRebuild = true
                    // Signal structural mutation so refreshScope is called below.
                    // Encoders with requiresExactDecoder (kleisli compositions) skip
                    // graph.apply, so requiresFullRebuild is never set on the
                    // ChangeApplication — but their cached state is equally stale after
                    // an acceptance and needs the same reset treatment.
                    mutatedStructurally = true
                } else {
                    application = graph.apply(probe.mutation, freshTree: tree)
                    if application.requiresFullRebuild {
                        anyRequiresRebuild = true
                        mutatedStructurally = true
                    }
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
                    mutatedStructurally = true
                }
                if isInstrumented, application.requiresFullRebuild == false {
                    let fresh = ChoiceGraph.build(from: tree)
                    if graph.structuralFingerprint != fresh.structuralFingerprint {
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

            // Refresh the encoder's scope on structural mutation. The
            // encoder's cached state (e.g. ``IntegerState/leafPositions``)
            // was built at ``start(scope:)`` against the pre-mutation
            // graph and cannot be safely re-used after a reshape
            // tombstones leaves and splices in new nodes. Continuing to
            // iterate without a refresh would let the encoder address
            // ``state.sequence`` at stale indices and silently corrupt
            // either the live sequence or the new spliced leaves' values,
            // producing the position drift bug documented in
            // ExhaustDocs/graph-reducer-position-drift-bug.md. Calling
            // ``refreshScope`` lets the encoder re-derive its scope state
            // from the live graph in place — preserving in-pass
            // convergence records keyed by nodeID, picking up new leaves
            // the splice created, and dropping tombstoned ones — without
            // paying the full source-rebuild + dispatch overhead the
            // earlier `break`-out fix imposed.
            if mutatedStructurally {
                encoder.refreshScope(graph: graph, sequence: sequence)
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
                    "cache_hits": "\(cacheHitCount)",
                    "decoder_rejects": "\(decoderRejectCount)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        return ProbeLoopOutcome(
            accepted: anyAccepted,
            requiresRebuild: anyRequiresRebuild,
            requiresSourceRebuild: anyRequiresSourceRebuild,
            treeIsStripped: latestAcceptedTreeIsStripped,
            probeCount: probeCount,
            acceptCount: acceptCount
        )
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Convergence

    /// Returns true when every leaf value is either at its reduction target or has a convergence record.
    private static func allValuesConverged(
        in _: ChoiceSequence,
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

    /// Extracts warm-start convergence records from all leaf nodes, keyed by graph nodeID.
    ///
    /// NodeID keying lets the encoder look up records via `state.warmStartRecords[leaf.nodeID]` and survives any in-pass refresh that shifts the leaf's sequence position. The previous positional keying broke as soon as a refresh re-derived `leaf.sequenceIndex`.
    private static func extractWarmStarts(from graph: ChoiceGraph) -> [Int: ConvergedOrigin] {
        var records: [Int: ConvergedOrigin] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            records[nodeID] = origin
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
                       boundRange.contains(leafRange.lowerBound)
                    {
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
    private static func detectStaleness(
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        graph: ChoiceGraph,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
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

        // Bind status is structural — staleness probes are value-only and
        // cannot add or remove bind markers. Hoisted to avoid an O(N) scan
        // on every converged leaf.
        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
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

            if let result = try decoder.decodeAny(
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
                graph.recordConvergence(byNodeID: [nodeID: ConvergedOrigin(
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

    /// No-op. Previously cleared convergence on leaves changed by redistribution to compensate for the coarse `convergedOrigin == nil` guard in ``minimizationScopes()``. The guard now checks `convergedOrigin.bound == currentBP`, so a leaf whose value moved away from its floor naturally passes the guard and re-enters value search with the surviving convergence record as a warm-start bound.
    private static func clearConvergenceOnChangedLeaves(
        for _: GraphTransformation,
        in _: ChoiceGraph
    ) {}
}

// MARK: - Scope Rejection Cache

/// Deterministic duplicate detection for structural graph operations using position-scoped Zobrist hashes.
///
/// For each rejected structural operation, computes a hash from the operation discriminator and the ``ZobristHash`` contributions at the targeted positions. The hash naturally invalidates when any targeted value changes — no explicit dirty tracking needed.
///
/// Cleared on structural acceptance (graph rebuild changes positions). Persists across cycles for value-only changes.
struct ScopeRejectionCache {
    private var rejectedHashes = Set<UInt64>()

    /// Value-independent hash for structural operations. Keyed by (operation type, targeted node IDs) without leaf values. A deletion that was rejected at one set of leaf values is almost always rejected at another — the property cares about the *absence* of the element, not what value it had. Cleared per cycle to guard against the rare case where value changes at other positions shift the property's acceptance boundary enough to make a previously-rejected deletion viable.
    private var coarseRejectedHashes = Set<UInt64>()

    /// Records a rejected structural transformation.
    mutating func recordRejection(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        if let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) {
            rejectedHashes.insert(hash)
        }
        if operation.affectedNodeIDs(in: graph) != nil, let hash = coarseScopeHash(operation: operation, graph: graph) {
            coarseRejectedHashes.insert(hash)
        }
    }

    /// Returns true if this transformation was previously rejected. Checks the coarse (value-independent) cache first for structural operations, then the fine-grained (value-dependent) cache.
    func isRejected(
        operation: GraphOperation,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> Bool {
        if let hash = coarseScopeHash(operation: operation, graph: graph) {
            if coarseRejectedHashes.contains(hash) { return true }
        }
        guard let hash = scopeHash(operation: operation, sequence: sequence, graph: graph) else {
            return false
        }
        return rejectedHashes.contains(hash)
    }

    /// Clears all cached rejections. Called on structural acceptance (graph rebuild).
    mutating func clear() {
        rejectedHashes.removeAll(keepingCapacity: true)
        coarseRejectedHashes.removeAll(keepingCapacity: true)
    }

    /// Clears only the coarse cache. Called at the top of each cycle to guard against stale value-independent rejections when leaf values changed since the rejection was recorded.
    mutating func clearCoarse() {
        coarseRejectedHashes.removeAll(keepingCapacity: true)
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

        var hash = operationDiscriminator(operation)

        // Mix in Zobrist contributions at each targeted position.
        for nodeID in nodeIDs {
            guard nodeID < graph.nodes.count,
                  let range = graph.nodes[nodeID].positionRange
            else {
                continue
            }
            for position in range {
                guard position < sequence.count else { break }
                hash ^= ZobristHash.contribution(at: position, sequence[position])
            }
        }

        return hash
    }

    /// Value-independent hash for structural operations. Uses node IDs instead of sequence values, so a deletion targeting the same nodes produces the same hash regardless of leaf values.
    private func coarseScopeHash(
        operation: GraphOperation,
        graph: ChoiceGraph
    ) -> UInt64? {
        guard let nodeIDs = operation.affectedNodeIDs(in: graph) else {
            return nil
        }

        // Use a different discriminator salt to avoid collisions with the fine-grained hash.
        var hash: UInt64 = operationDiscriminator(operation) ^ 0xC0A8_5E00_DEAD_BEEF

        for nodeID in nodeIDs {
            var bits = UInt64(nodeID) &* 0x9E37_79B9_7F4A_7C15
            bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
            bits ^= bits >> 31
            hash ^= bits
        }

        return hash
    }

    private func operationDiscriminator(_ operation: GraphOperation) -> UInt64 {
        switch operation {
        case .remove: 0xA1B2_C3D4_E5F6_0718
        case .replace: 0x1827_3645_5463_7281
        case .permute: 0x9182_7364_5546_3728
        case .migrate: 0x6372_8190_A0B0_C0D0
        case .minimize, .exchange: 0
        }
    }
}
