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
/// - `ChoiceGraphScheduler+ProbeLoop.swift`: per-encoder probe loop.
/// - `ChoiceGraphScheduler+BoundValueSearch.swift`: bound value composition construction and lift.
/// - `ChoiceGraphScheduler+Convergence.swift`: warm-start extraction and convergence transfer across rebuilds.
/// - `ChoiceGraphScheduler+ConvergenceConfirmation.swift`: convergence confirmation at end of stalled cycles.
///
/// State clusters that were previously inline local variables are factored into dedicated types:
/// - ``BoundValueGate``: per-cycle dedup, fruitless tracking, and stall-count decay for bound value composition dispatches.
/// - ``FutilityTracker``: cumulative per-encoder probe history and per-cycle budget caps for structurally futile encoders.
///
/// - SeeAlso: ``ScopeSource``, ``ScopeSourceBuilder``, ``GraphEncoder``
enum ChoiceGraphScheduler {
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
        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
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
        var output: Any = initialOutput
        var stats = ReductionStats()
        var cycles = 0
        var stallBudget = config.maxStalls
        var rejectCache = Set<UInt64>()

        var graph = ChoiceGraph.build(from: tree)
        graph.observeBindTopologies(tree: tree)

        // Tracks whether the current graph was rebuilt from a stripped tree (materializePicks: false).
        // False at scheduler entry because the initial tree was just re-materialized with materializePicks: true above.
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

        var scopeRejectionCache = ScopeRejectionCache()
        var gate = BoundValueGate()
        var futility = FutilityTracker()

        while stallBudget > 0 {
            cycles += 1
            gate.resetForNewCycle()
            futility.prepareForNewCycle()
            scopeRejectionCache.clearCoarse()
            let sequenceBeforeCycle = sequence

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

            while true {
                guard let sourceIndex = Self.highestYieldSourceIndex(sources) else {
                    break
                }

                guard let transformation = sources[sourceIndex].next(lastAccepted: false) else {
                    sources.remove(at: sourceIndex)
                    continue
                }

                guard transformation.precondition.isSatisfied(in: graph) else {
                    continue
                }

                if scopeRejectionCache.isRejected(
                    operation: transformation.operation,
                    sequence: sequence,
                    graph: graph
                ) {
                    continue
                }

                // Bound value gating.
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    switch gate.shouldDispatch(bindNodeID: fibreScope.bindNodeID, anyAcceptedThisCycle: anyAccepted) {
                    case .skip:
                        continue
                    case .classifyFirst:
                        guard case let .bind(bindMetadata) = graph.nodes[fibreScope.bindNodeID].kind else {
                            continue
                        }
                        let classification: BindClassification
                        if let cached = graph.bindClassifications[bindMetadata.fingerprint] {
                            classification = cached
                        } else {
                            graph.classifyBind(
                                at: fibreScope.bindNodeID,
                                gen: erasedGen,
                                baseSequence: sequence,
                                fallbackTree: tree,
                                upstreamLeafNodeID: fibreScope.upstreamLeafNodeID
                            )
                            guard case let .bind(updatedMetadata) = graph.nodes[fibreScope.bindNodeID].kind,
                                  let verdict = updatedMetadata.classification
                            else {
                                continue
                            }
                            classification = verdict
                        }
                        if classification.topology != .identical || classification.liftability != .both {
                            gate.markFruitless(fibreScope.bindNodeID)
                            continue
                        }
                    case .dispatch:
                        break
                    }
                }

                // Futility budget check.
                let pendingEncoderName = FutilityTracker.encoderName(for: transformation.operation)
                if futility.isBudgetExhausted(for: pendingEncoderName) {
                    continue
                }

                // Lazy rematerialize for stripped graphs before path-changing operations.
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
                    graph = rebuildGraph(from: tree, replacing: graph, stats: &stats)
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

                // Select encoder and dispatch.
                var encoder: any GraphEncoder
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    encoder = Self.makeBoundValueComposition(
                        fibreScope: fibreScope,
                        scope: scope,
                        graph: graph,
                        gen: erasedGen,
                        upstreamBudget: gate.decayedBudget(bindNodeID: fibreScope.bindNodeID)
                    )
                } else {
                    encoder = Self.selectEncoder(for: transformation.operation)
                }
                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    gate.markDispatched(fibreScope.bindNodeID)
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
                    materializationBudget: futility.remainingBudget(for: pendingEncoderName)
                )

                encoder.flushPartialConvergence()

                let convergence = encoder.convergenceRecords
                if convergence.isEmpty == false {
                    graph.recordConvergence(byNodeID: convergence)
                }

                futility.recordOutcome(
                    encoder: pendingEncoderName,
                    materializations: outcome.materializationCount,
                    accepts: outcome.acceptCount
                )

                if case let .minimize(.boundValue(fibreScope)) = transformation.operation {
                    gate.recordOutcome(bindNodeID: fibreScope.bindNodeID, accepted: outcome.acceptCount > 0)
                }

                if outcome.accepted {
                    anyAccepted = true

                    let isBoundValue = switch transformation.operation {
                    case .minimize(.boundValue):
                        true
                    default:
                        false
                    }

                    if outcome.requiresRebuild || isBoundValue {
                        // Save bound subtree's position range before rebuild for stale convergence clearing.
                        var boundPositionRange: ClosedRange<Int>?
                        if isBoundValue,
                           case let .minimize(.boundValue(fibreScope)) = transformation.operation,
                           fibreScope.bindNodeID < graph.nodes.count,
                           case let .bind(bindMetadata) = graph.nodes[fibreScope.bindNodeID].kind,
                           graph.nodes[fibreScope.bindNodeID].children.count > bindMetadata.boundChildIndex
                        {
                            let boundChildID = graph.nodes[fibreScope.bindNodeID].children[bindMetadata.boundChildIndex]
                            boundPositionRange = graph.nodes[boundChildID].positionRange
                        }

                        graph = rebuildGraph(from: tree, replacing: graph, stats: &stats)
                        graphIsStripped = outcome.treeIsStripped

                        // Clear stale downstream convergence after bound value rebuild.
                        if let boundRange = boundPositionRange {
                            for nodeID in graph.leafNodes {
                                guard let nodeRange = graph.nodes[nodeID].positionRange else { continue }
                                guard boundRange.contains(nodeRange.lowerBound) else { continue }
                                guard case var .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
                                guard metadata.convergedOrigin != nil else { continue }
                                metadata.convergedOrigin = nil
                                graph.nodes[nodeID] = graph.nodes[nodeID].with(kind: .chooseBits(metadata))
                            }
                        }
                        scopeRejectionCache.clear()
                        gate.resetAfterRebuild()
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
                } else {
                    scopeRejectionCache.recordRejection(
                        operation: transformation.operation,
                        sequence: sequence,
                        graph: graph
                    )
                }
            }

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

            let improved = sequence != sequenceBeforeCycle
            if improved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

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

        try runReorderPass(
            graph: graph,
            sequence: &sequence,
            tree: &tree,
            output: &output,
            gen: erasedGen,
            property: wrappedProperty,
            stats: &stats,
            collectStats: collectStats,
            isInstrumented: isInstrumented
        )

        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        stats.cycles = cycles
        // swiftlint:disable:next force_cast
        let typedOutput = output as! Output
        return (reduced: (sequence, typedOutput), stats: stats)
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Graph Rebuild

    /// Rebuilds the graph from a tree, inheriting classification and convergence caches from the old graph.
    ///
    /// Consolidates the 9-step rebuild sequence used by both the lazy rematerialize path and the post-acceptance rebuild path: accumulate dynamic stats, extract convergence, capture classifications and observations, build the new graph with inherited caches, observe bind topologies, transfer convergence, and increment the rebuild counter.
    ///
    /// Post-rebuild actions that differ between call sites (clearing the rejection cache, resetting the bound value gate, rebuilding sources, clearing downstream convergence) stay at each call site.
    private static func rebuildGraph(
        from tree: ChoiceTree,
        replacing oldGraph: ChoiceGraph,
        stats: inout ReductionStats
    ) -> ChoiceGraph {
        stats.graphStats.dynamicRegionRebuilds += oldGraph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += oldGraph.graphStats.dynamicRegionNodesRebuilt
        let oldConvergence = extractAllConvergence(from: oldGraph)
        let inheritedClassifications = oldGraph.bindClassifications
        let inheritedObservations = oldGraph.bindTopologyObservations
        let newGraph = ChoiceGraph.build(
            from: tree,
            inheriting: inheritedClassifications,
            observations: inheritedObservations
        )
        newGraph.observeBindTopologies(tree: tree)
        transferConvergence(oldConvergence, to: newGraph)
        stats.graphStats.fullGraphRebuilds += 1
        return newGraph
    }

    // MARK: - Reorder Pass

    /// Runs the human-readable ordering pass after all other reduction is complete.
    ///
    /// Reorders type-homogeneous sibling groups into natural numeric order so seeds with the same multiset of values converge to the same canonical counterexample.
    private static func runReorderPass(
        graph: ChoiceGraph,
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws {
        guard let reorderScope = ReorderingScopeQuery.build(graph: graph) else { return }
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
            gen: gen,
            property: property,
            rejectCache: &reorderCache,
            stats: &stats,
            collectStats: collectStats,
            isInstrumented: isInstrumented
        )
        if isInstrumented, reorderOutcome.accepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
    }

    // MARK: - Source Selection

    /// Returns the index of the source with the highest peekYield, or nil if all are exhausted.
    private static func highestYieldSourceIndex(
        _ sources: [any ScopeSource]
    ) -> Int? {
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
    /// Bound value minimization scopes are not handled here because they need the typed generator at construction time. The dispatch site in ``runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` builds them via ``makeBoundValueComposition(fibreScope:scope:graph:gen:upstreamBudget:)`` instead.
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
