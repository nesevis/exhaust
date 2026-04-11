//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives scope-source-dispatched reduction until convergence or stall budget exhaustion.
///
/// Merges lazy ``ScopeSource`` iterators by yield, pulling from whichever has the highest-yield next scope. Dispatches to pure structural encoders (one probe) or search-based value encoders (multiple probes). On structural acceptance, rebuilds all sources from the new graph. On rejection, only the dispatched source advances.
///
/// The scheduler is split across several files for readability:
/// - This file: entry points, the cycle loop (``runCore(gen:initialTree:initialOutput:config:collectStats:property:)``), source/encoder selection.
/// - `ChoiceGraphScheduler+ProbeLoop.swift`: per-encoder probe loop and the ``PreStartedAdapter``.
/// - `ChoiceGraphScheduler+Kleisli.swift`: kleisli fibre composition construction and lift.
/// - `ChoiceGraphScheduler+Convergence.swift`: warm-start extraction and convergence transfer across rebuilds.
/// - `ChoiceGraphScheduler+Staleness.swift`: stale-floor detection at end of stalled cycles.
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
                        // (multi-bind reshape, structural mutation, and so on).
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
                        // graph.
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
                    }
                    // Pure value-only fast-path acceptances need no
                    // bookkeeping here: graph and sources are still valid,
                    // and the scope rejection cache self-invalidates via
                    // hash change.
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
    /// Kleisli fibre minimization scopes are not handled here because they need the typed generator at construction time. The dispatch site in ``runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` builds them via ``makeKleisliComposition(fibreScope:scope:gen:upstreamBudget:)`` instead.
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
}
