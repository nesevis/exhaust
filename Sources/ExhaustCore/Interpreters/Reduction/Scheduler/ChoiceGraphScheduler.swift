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
/// - `ChoiceGraphScheduler+BoundValueSearch.swift`: bound value composition construction and lift.
/// - `ChoiceGraphScheduler+Convergence.swift`: warm-start extraction and convergence transfer across rebuilds.
/// - `ChoiceGraphScheduler+ConvergenceConfirmation.swift`: convergence confirmation at end of stalled cycles.
///
/// - SeeAlso: ``ScopeSource``, ``ScopeSourceBuilder``, ``GraphEncoder``
enum ChoiceGraphScheduler {
    // MARK: - Futility Cap

    //
    // Some encoders are structurally futile on a given counterexample — they never find an accepted probe across the entire reduction because the property's constraint structure makes the encoder's search space empty. After ``futilityEmitThreshold`` cumulative probes with zero accepts, the encoder's per-cycle budget drops to ``futilityProbeBudget``.
    //
    // The budget acts as a heartbeat: enough probes per cycle to detect if the landscape changed (for example, a structural acceptance made the encoder viable), but not enough to waste significant materializations on a structurally hopeless search. If the encoder finds an accept, the cumulative accept count goes above zero and the cap lifts automatically.
    //
    // Value search, float search, and bound value composition are excluded because their acceptance pattern is dispatch-dependent — early dispatches often have zero accepts before later dispatches find progress. Any cumulative threshold would prematurely cap them.

    /// Cumulative probe count (with zero accepts) that triggers the futility cap.
    private static let futilityEmitThreshold = 10

    /// Per-cycle probe budget after the futility cap triggers.
    private static let futilityProbeBudget = 2

    // MARK: - Entry Points

    /// Runs the graph-based reduction pipeline to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.ReducerConfiguration,
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
        config: Interpreters.ReducerConfiguration,
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
        config: Interpreters.ReducerConfiguration,
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
        // Ensures alternative branches have structure for pivoting.
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
        // Hold ``output`` as ``Any`` internally so it can be passed to the non-generic ``runProbeLoop`` and ``confirmConvergence``. Cast back to ``Output`` at the very end before returning.
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
            stats.graphStats = ChoiceGraphStats.from(graph)
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

        // Per-cycle blocklist for bound value dispatches. Each bound value
        // composition runs a generator lift per upstream probe and a fibre
        // search per lift, all expensive operations that don't benefit from
        // the probe-level reject cache. After the first dispatch within a
        // cycle, the upstream encoder has explored its full search space
        // (up to ``GraphComposedEncoder/upstreamBudget``); re-dispatching
        // after a structural acceptance just re-runs the same upstream
        // exploration. The old reducer sidesteps this by
        // running once per cycle as a separate phase. We mirror that here
        // by tracking dispatched bind node IDs and skipping repeats until
        // the next cycle, when the set is cleared.
        var boundValueDispatchedThisCycle = Set<Int>()

        // Per-bind-node bound value stall counter. Incremented when a bound value dispatch produces zero accepts. Reset on any acceptance. Decays the upstream probe budget: `max(1, 15 >> stalls)` — 15, 7, 3, 1 over consecutive fruitless dispatches.
        var boundValueStallCount: [Int: Int] = [:]

        // Node IDs whose last dependent-node dispatch (composed or pivot-then-minimize) produced zero accepts. The scheduler skips dispatch for nodes in this set. Cleared entirely on structural graph rebuild.
        var fruitlessDependentNodes = Set<Int>()

        // Per-encoder cumulative probe counts for the futility cap. See ``futilityEmitThreshold`` and ``futilityProbeBudget``.
        var encoderEmits: [EncoderName: Int] = [:]
        var encoderAccepts: [EncoderName: Int] = [:]
        var encoderCycleBudget: [EncoderName: Int] = [:]

        while stallBudget > 0 {
            cycles += 1
            boundValueDispatchedThisCycle.removeAll(keepingCapacity: true)
            encoderCycleBudget.removeAll(keepingCapacity: true)
            scopeRejectionCache.clearCoarse()
            for (name, emits) in encoderEmits {
                let accepts = encoderAccepts[name, default: 0]
                guard accepts == 0 else { continue }
                // Search encoders and deletion are excluded. Search encoders have dispatch-dependent acceptance patterns (early dispatches have zero accepts, later ones find accepts). Bound value search has its own stall-cycle gating. Deletion is excluded because per-element deletion of zero-valued elements becomes viable after value search zeroes them — the scope rejection cache (which naturally invalidates on value change) handles deletion waste. Capping deletion under a shared budget starves per-element probes behind whole-array probes that exhaust the budget first.
                switch name {
                case .valueSearch, .floatSearch, .composed, .deletion:
                    continue
                default:
                    break
                }
                if emits >= Self.futilityEmitThreshold {
                    encoderCycleBudget[name] = Self.futilityProbeBudget
                }
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

                // bound value scopes are deferred to stall cycles. Two skip rules
                // protect against the cost of running the composition unnecessarily:
                //
                // 1. Per-cycle de-duplication: each bound value composition runs an
                //    upstream search whose internal state is recreated on every dispatch
                //    and a generator lift per upstream probe — neither benefits from the
                //    probe-level reject cache. After the first dispatch within a cycle
                //    the second and third dispatches add little value at high cost.
                //
                // 2. Stall-cycle gating: if any non-bound-value encoder has already accepted
                //    progress in this cycle, the bound value composition is redundant — the
                //    cheaper encoders are still finding improvements and the next cycle
                //    will re-evaluate. Bound value search only fires in cycles where the cheap
                //    encoders couldn't make progress — bound value search is the
                //    explicit fallback after cheaper encoders exhaust.
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    if boundValueDispatchedThisCycle.contains(fibreScope.bindNodeID) {
                        continue
                    }
                    if anyAccepted {
                        continue
                    }
                    // Fruitless gate: skip composed dispatch for binds whose last dispatch produced zero accepts. Cleared on structural graph rebuild.
                    if fruitlessDependentNodes.contains(fibreScope.bindNodeID) {
                        continue
                    }
                }

                // Per-encoder cycle budget: skip if the budget has been exhausted for this encoder.
                let pendingEncoderName: EncoderName = switch transformation.operation {
                case .remove: .deletion
                case .replace: .substitution
                case .minimize(.boundValue): .composed
                case .minimize(.valueLeaves): .valueSearch
                case .minimize(.floatLeaves): .floatSearch
                case .exchange(.redistribution): .redistribution
                case .exchange(.tandem): .lockstep
                case .permute: .siblingSwap
                case .migrate: .migration
                case .reorder: .numericReorder
                }
                if let budget = encoderCycleBudget[pendingEncoderName], budget <= 0 {
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
                    stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
                    stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
                    let oldConvergence = extractAllConvergence(from: graph)
                    graph = ChoiceGraph.build(from: tree)
                    transferConvergence(oldConvergence, to: graph)
                    stats.graphStats.fullGraphRebuilds += 1
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

                // Select encoder and run. bound value scopes route through the
                // generic ``GraphComposedEncoder`` primitive constructed at this call
                // site (where Output and gen are in scope) rather than the non-generic
                // ``selectEncoder(for:)`` switch.
                var encoder: any GraphEncoder
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    let stalls = boundValueStallCount[fibreScope.bindNodeID, default: 0]
                    let decayedBudget = max(1, 15 >> stalls)
                    encoder = Self.makeBoundValueComposition(
                        fibreScope: fibreScope,
                        scope: scope,
                        gen: erasedGen,
                        upstreamBudget: decayedBudget
                    )
                } else {
                    encoder = Self.selectEncoder(for: transformation.operation)
                }
                // Mark the bound value edge as dispatched for this cycle so the
                // per-cycle skip above blocks repeat dispatches after any
                // structural acceptance triggers a source rebuild.
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    boundValueDispatchedThisCycle.insert(fibreScope.bindNodeID)
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
                    isInstrumented: isInstrumented,
                    materializationBudget: encoderCycleBudget[pendingEncoderName]
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

                // Update per-encoder history and cycle budget.
                encoderEmits[pendingEncoderName, default: 0] += outcome.probeCount
                encoderAccepts[pendingEncoderName, default: 0] += outcome.acceptCount
                if var budget = encoderCycleBudget[pendingEncoderName] {
                    budget -= outcome.probeCount
                    encoderCycleBudget[pendingEncoderName] = budget
                }

                // Dependent-node stall tracking: mark nodes fruitless on zero-accept dispatch, clear on any acceptance.
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    if outcome.acceptCount > 0 {
                        boundValueStallCount[fibreScope.bindNodeID] = 0
                        fruitlessDependentNodes.remove(fibreScope.bindNodeID)
                    } else {
                        boundValueStallCount[fibreScope.bindNodeID, default: 0] += 1
                        fruitlessDependentNodes.insert(fibreScope.bindNodeID)
                    }
                }
                if outcome.accepted {
                    anyAccepted = true

                    // Force a full graph rebuild after every accepted bound value composition
                    // dispatch. The composition's repeated bind reshapes accumulate
                    // partial-rebuild state on the live graph that the shadow check has
                    // observed diverging from a fresh build (`graph_apply_shadow_mismatch`),
                    // and which causes downstream encoders to crash on stale leaf positions.
                    // Until the in-place reshape path is fixed for chained applications,
                    // the safe option is to rebuild the graph from the live tree after the
                    // composition exits.
                    let isBoundValue = switch transformation.operation {
                    case .minimize(.boundValue):
                        true
                    default:
                        false
                    }

                    if outcome.requiresRebuild || isBoundValue {
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
                        // For bound value rebuilds, the upstream bind-inner changed value,
                        // so any convergence floors recorded for downstream leaves under
                        // the old upstream value are now stale — the failure threshold
                        // in n-space may have shifted. Save the bound subtree's position
                        // range before the rebuild so we can clear those floors after
                        // transferConvergence has run.
                        var boundPositionRange: ClosedRange<Int>? = nil
                        if isBoundValue,
                           case let .minimize(.boundValue(fs)) = transformation.operation,
                           fs.bindNodeID < graph.nodes.count,
                           case let .bind(bm) = graph.nodes[fs.bindNodeID].kind,
                           graph.nodes[fs.bindNodeID].children.count > bm.boundChildIndex
                        {
                            let boundChildID = graph.nodes[fs.bindNodeID].children[bm.boundChildIndex]
                            boundPositionRange = graph.nodes[boundChildID].positionRange
                        }

                        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
                        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
                        graphIsStripped = outcome.treeIsStripped
                        transferConvergence(oldConvergence, to: graph)

                        // Clear stale downstream convergence after bound value rebuild.
                        if let boundRange = boundPositionRange {
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
                        stats.graphStats.fullGraphRebuilds += 1
                        scopeRejectionCache.clear()
                        fruitlessDependentNodes.removeAll(keepingCapacity: true)
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
                    // Pure value-only fast-path acceptances need no structural bookkeeping: graph and sources are still valid, and the scope rejection cache self-invalidates via hash change.
                } else {
                    // Rejection: record in scope cache for structural operations.
                    scopeRejectionCache.recordRejection(
                        operation: transformation.operation,
                        sequence: sequence,
                        graph: graph
                    )
                }
            }

            // Staleness detection: after all sources exhausted, probe converged leaves at `floor - 1` to detect stale convergence. ``confirmConvergence`` is a validator, not a search — when it proves a recorded floor was stale it clears the convergence record in place but does not mutate sequence, tree, or output. ``GraphValueEncoder`` re-enters the cleared leaf next cycle from its original state and runs its full bp binary search and cross-zero phase. No graph rebuild is needed: sequence and tree are unchanged, and the in-place clearing leaves every node's ``ChoiceGraphNode/positionRange`` and ``ChoiceGraphNode/children`` intact.
            if anyAccepted == false, allValuesConverged(in: sequence, graph: graph) {
                _ = try confirmConvergence(
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
        if let reorderScope = ReorderingScopeQuery.build(graph: graph) {
            let reorderTransformation = GraphTransformation(
                operation: .reorder(reorderScope),
                yield: TransformationYield(structural: 0, value: 0, slack: .exact, estimatedProbes: 1),
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            )
            let reorderScopeBundle = TransformationScope(
                transformation: reorderTransformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            )
            var reorderEncoder: any GraphEncoder = GraphReorderEncoder()
            var reorderCache = Set<UInt64>()
            let reorderOutcome = try ChoiceGraphScheduler.runProbeLoop(
                encoder: &reorderEncoder,
                scope: reorderScopeBundle,
                graph: graph,
                sequence: &sequence,
                tree: &tree,
                output: &output,
                gen: erasedGen,
                property: wrappedProperty,
                rejectCache: &reorderCache,
                stats: &stats,
                collectStats: collectStats,
                isInstrumented: isInstrumented
            )
            if isInstrumented, reorderOutcome.accepted {
                ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
            }
        }

        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
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
    /// bound value minimization scopes are not handled here because they need the typed generator at construction time. The dispatch site in ``runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` builds them via ``makeBoundValueComposition(fibreScope:scope:gen:upstreamBudget:)`` instead.
    private static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
        switch operation {
        case .remove, .replace, .migrate:
            GraphStructuralEncoder()
        case .permute:
            GraphSwapEncoder()
        case .minimize:
            GraphValueEncoder()
        case .exchange(.redistribution):
            GraphRedistributionEncoder()
        case .exchange(.tandem):
            GraphLockstepEncoder()
        case .reorder:
            GraphReorderEncoder()
        }
    }
}
