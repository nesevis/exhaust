//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives scope-source-dispatched reduction until convergence or stall budget exhaustion.
///
/// Merges lazy ``CandidateSource`` iterators by yield, pulling from whichever has the highest-yield next scope. Dispatches to pure structural encoders (one probe) or search-based value encoders (multiple probes). On structural acceptance, rebuilds all sources from the new graph. On rejection, only the dispatched source advances.
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
///
/// - SeeAlso: ``CandidateSource``, ``CandidateSourceBuilder``, ``GraphEncoder``
enum ChoiceGraphScheduler {
    /// Shared mutable state threaded through the reduction pipeline.
    ///
    /// Bundles the fields that every helper method (probe loop, convergence confirmation, relax round, reorder pass) previously took as separate parameters. Scheduler-level loop control (stall budget, cycle count, gate, deferral flags) stays local to ``runCore`` because no helper reads or writes them.
    struct ReductionState {
        var sequence: ChoiceSequence
        var tree: ChoiceTree
        var output: Any
        var graph: ChoiceGraph
        var stats: ReductionStats
        var rejectCache: Set<UInt64>
        let gen: ReflectiveGenerator<Any>
        let property: (Any) -> Bool
        let tuning: SchedulerTuning
        let collectStats: Bool
        let isInstrumented: Bool
    }

    // MARK: - Entry Points

    /// Orchestrates the full reduction loop: builds the initial choice graph, runs scope-based encoding passes until convergence or budget exhaustion, and returns the minimal counterexample.
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

    /// Wraps ``run(gen:initialTree:initialOutput:config:property:)`` with statistics collection, returning both the reduced result and accumulated ``ReductionStats``.
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
        let erasedGen = gen.erase()
        let wrappedProperty: (Any) -> Bool = { property($0 as! Output) }
        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
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

        var graph = ChoiceGraph.build(from: tree)
        graph.observeBindTopologies(tree: tree)

        var state = ReductionState(
            sequence: sequence,
            tree: tree,
            output: initialOutput,
            graph: graph,
            stats: ReductionStats(),
            rejectCache: [],
            gen: erasedGen,
            property: wrappedProperty,
            tuning: config.tuning,
            collectStats: collectStats,
            isInstrumented: ExhaustLog.isEnabled(.debug, for: .reducer)
        )
        var cycles = 0
        var stallBudget = config.maxStalls

        var graphIsStripped = false

        if state.collectStats {
            state.stats.graphStats = ChoiceGraphStats.from(state.graph)
        }

        Self.logReducer("graph_reducer_start", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)", "max_stalls": "\(config.maxStalls)", "nodes": "\(state.graph.nodes.count)",
        ])

        var scopeRejectionCache = CandidateRejectionCache()
        var gate = BoundValueGate(baseBudget: config.tuning.boundValueBaseBudget)
        var hadReplacementShortlexRejection = false
        var deferBindInner = state.graph.reductionEdges.isEmpty == false

        while stallBudget > 0 {
            cycles += 1
            gate.resetForNewCycle()
            scopeRejectionCache.clearCoarse()
            hadReplacementShortlexRejection = false
            let sequenceBeforeCycle = state.sequence

            var sources = CandidateSourceBuilder.buildSources(from: state.graph, deferBindInner: deferBindInner)

            Self.logReducer("graph_cycle_start", isInstrumented: state.isInstrumented, metadata: [
                "cycle": "\(cycles)", "seq_len": "\(state.sequence.count)",
                "sources": "\(sources.count)", "stall_budget": "\(stallBudget)",
            ])

            var anyAccepted = false

            while true {
                guard let sourceIndex = Self.highestPrioritySourceIndex(sources) else {
                    break
                }

                guard let transformation = sources[sourceIndex].next(lastAccepted: false) else {
                    sources.swapAt(sourceIndex, sources.count - 1)
                    sources.removeLast()
                    continue
                }

                var decision = Self.evaluateDispatch(
                    transformation: transformation,
                    graph: state.graph,
                    sequence: state.sequence,
                    gate: gate,
                    scopeCache: scopeRejectionCache,
                    graphIsStripped: graphIsStripped,
                    anyAccepted: anyAccepted
                )

                if case let .classifyBind(bindNodeID, fingerprint) = decision {
                    guard case let .minimize(.boundValue(bindScope)) = transformation.operation else {
                        continue
                    }
                    state.graph.classifyBind(
                        at: bindNodeID,
                        gen: state.gen,
                        baseSequence: state.sequence,
                        fallbackTree: state.tree,
                        upstreamLeafNodeID: bindScope.upstreamLeafNodeID
                    )
                    guard case let .bind(updatedMetadata) = state.graph.nodes[bindNodeID].kind,
                          let classification = updatedMetadata.classification
                    else {
                        continue
                    }
                    if classification.topology != .identical || classification.liftability != .both {
                        gate.markFruitless(fingerprint)
                        continue
                    }
                    decision = .readyToDispatch(boundValueFingerprint: fingerprint)
                }

                switch decision {
                case .skip:
                    continue

                case .classifyBind:
                    continue

                case .rematerialize:
                    // Re-materialization with `materializePicks` generates fresh inactive branch content via PRNG fallback, invalidating self-similarity edges and replacement candidates from the old graph. The structural source split cannot be used here.
                    if case let .success(_, fullTree, _) = Materializer.materializeAny(
                        state.gen,
                        prefix: state.sequence,
                        mode: .exact,
                        fallbackTree: state.tree,
                        materializePicks: true
                    ) {
                        state.tree = fullTree
                    }
                    let graphBeforeRebuild = state.graph
                    let rebuild = rebuildGraph(from: state.tree, replacing: state.graph, stats: &state.stats)
                    state.graph = rebuild.graph
                    sources = CandidateSourceBuilder.buildSources(from: state.graph, deferBindInner: deferBindInner, previousGraph: graphBeforeRebuild)
                    graphIsStripped = false
                    continue

                case let .readyToDispatch(boundValueFingerprint):
                    let warmStarts = extractWarmStarts(from: state.graph)
                    let scope = EncoderInput(
                        transformation: transformation,
                        baseSequence: state.sequence,
                        tree: state.tree,
                        graph: state.graph,
                        warmStartRecords: warmStarts
                    )

                    var encoder: any GraphEncoder
                    if case let .minimize(.boundValue(bindScope)) = transformation.operation,
                       let fingerprint = boundValueFingerprint
                    {
                        encoder = Self.makeBoundValueComposition(
                            bindScope: bindScope,
                            scope: scope,
                            graph: state.graph,
                            gen: state.gen,
                            upstreamBudget: gate.decayedBudget(fingerprint: fingerprint)
                        )
                        gate.markDispatched(fingerprint)
                    } else {
                        encoder = Self.selectEncoder(for: transformation.operation)
                    }
                    let outcome = try runProbeLoop(
                        encoder: &encoder,
                        scope: scope,
                        state: &state
                    )

                    encoder.flushPartialConvergence()

                    let convergence = encoder.convergenceRecords
                    if convergence.isEmpty == false {
                        state.graph.recordConvergence(byNodeID: convergence)
                    }

                    if let fingerprint = boundValueFingerprint {
                        gate.recordOutcome(fingerprint: fingerprint, accepted: outcome.accepted)
                    }

                    if hadReplacementShortlexRejection == false,
                       encoder.hadReplacementShortlexRejection
                    {
                        hadReplacementShortlexRejection = true
                    }

                    let acceptanceAction = Self.evaluateAcceptance(
                        outcome: outcome,
                        operation: transformation.operation
                    )

                    if outcome.accepted {
                        anyAccepted = true
                    }

                    switch acceptanceAction {
                    case .continueDispatching:
                        if outcome.accepted == false {
                            scopeRejectionCache.recordRejection(
                                operation: transformation.operation,
                                sequence: state.sequence,
                                graph: state.graph
                            )
                        }

                    case let .rebuildAndResume(treeIsStripped):
                        var boundPositionRange: ClosedRange<Int>?
                        if case let .minimize(.boundValue(bindScope)) = transformation.operation,
                           bindScope.bindNodeID < state.graph.nodes.count,
                           case let .bind(bindMetadata) = state.graph.nodes[bindScope.bindNodeID].kind,
                           state.graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
                        {
                            let boundChildID = state.graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
                            boundPositionRange = state.graph.nodes[boundChildID].positionRange
                        }

                        let graphBeforeRebuild = state.graph
                        let rebuild = rebuildGraph(from: state.tree, replacing: state.graph, stats: &state.stats)
                        state.graph = rebuild.graph
                        graphIsStripped = treeIsStripped

                        if let boundRange = boundPositionRange {
                            for nodeID in state.graph.leafNodes {
                                guard let nodeRange = state.graph.nodes[nodeID].positionRange else { continue }
                                guard boundRange.contains(nodeRange.lowerBound) else { continue }
                                guard case var .chooseBits(metadata) = state.graph.nodes[nodeID].kind else { continue }
                                guard metadata.convergedOrigin != nil else { continue }
                                metadata.convergedOrigin = nil
                                state.graph.nodes[nodeID] = state.graph.nodes[nodeID].with(kind: .chooseBits(metadata))
                            }
                        }
                        if rebuild.diff.isStructurallyIdentical {
                            // Topology unchanged — keep structural sources (removal, replacement,
                            // migration, permutation) and only rebuild value-dependent sources
                            // (minimization, exchange).
                            let structuralSources = sources.filter { source in
                                guard let sorted = source as? SortedCandidateSource,
                                      let first = sorted.peekTransformation
                                else {
                                    // Non-SortedCandidateSource (BatchRemovalSource, etc.) are structural.
                                    return true
                                }
                                return first.operation.isValueDependent == false
                            }
                            sources = structuralSources
                                + CandidateSourceBuilder.buildValueSources(from: state.graph, deferBindInner: deferBindInner)

                            Self.logReducer("graph_value_only_rebuild", isInstrumented: state.isInstrumented, metadata: [
                                "seq_len": "\(state.sequence.count)", "nodes": "\(state.graph.nodes.count)", "sources": "\(sources.count)",
                            ])
                        } else {
                            scopeRejectionCache.clear()
                            sources = CandidateSourceBuilder.buildSources(from: state.graph, deferBindInner: deferBindInner, previousGraph: graphBeforeRebuild)

                            Self.logReducer("graph_structural_rebuild", isInstrumented: state.isInstrumented, metadata: [
                                "seq_len": "\(state.sequence.count)", "nodes": "\(state.graph.nodes.count)", "sources": "\(sources.count)",
                            ])
                        }
                    }
                }
            }

            let postCycle = evaluatePostCycle(
                outcome: CycleOutcome(
                    anyAccepted: anyAccepted,
                    hadReplacementShortlexRejection: hadReplacementShortlexRejection,
                    allConverged: allValuesConverged(in: state.sequence, graph: state.graph),
                    improved: state.sequence != sequenceBeforeCycle,
                    structurallyImproved: state.sequence.count < sequenceBeforeCycle.count
                ),
                stallBudget: stallBudget,
                maxStalls: config.maxStalls,
                deferBindInner: deferBindInner
            )

            for action in postCycle.actions {
                switch action {
                case .confirmConvergence:
                    _ = try confirmConvergence(state: &state)
                case .relaxRound:
                    let relaxResult = try runRelaxRound(state: &state)
                    if relaxResult {
                        anyAccepted = true
                        scopeRejectionCache.clear()
                    }
                case .releaseDeferral:
                    Self.logReducer("bind_inner_deferral_released", isInstrumented: state.isInstrumented, metadata: [
                        "cycle": "\(cycles)", "seq_len": "\(state.sequence.count)",
                    ])
                }
            }

            stallBudget = postCycle.newStallBudget
            deferBindInner = postCycle.newDeferBindInner

            let structurallyImproved = state.sequence.count < sequenceBeforeCycle.count
            if structurallyImproved == false,
               anyAccepted == false,
               allValuesConverged(in: state.sequence, graph: state.graph)
            {
                break
            }

            Self.logReducer("graph_cycle_end", isInstrumented: state.isInstrumented, metadata: [
                "cycle": "\(cycles)", "improved": "\(postCycle.newStallBudget == config.maxStalls ? "true" : "false")",
                "seq_len": "\(state.sequence.count)", "total_mats": "\(state.stats.totalMaterializations)",
            ])
        }

        if state.isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "graph_reducer_complete",
                metadata: [
                    "cycles": "\(cycles)",
                    "seq_len": "\(state.sequence.count)",
                    "total_mats": "\(state.stats.totalMaterializations)",
                ]
            )
        }

        try runReorderPass(state: &state)

        state.stats.graphStats.dynamicRegionRebuilds += state.graph.graphStats.dynamicRegionRebuilds
        state.stats.graphStats.dynamicRegionNodesRebuilt += state.graph.graphStats.dynamicRegionNodesRebuilt
        state.stats.cycles = cycles
        // swiftlint:disable:next force_cast
        let typedOutput = state.output as! Output
        return (reduced: (state.sequence, typedOutput), stats: state.stats)
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Graph Rebuild

    static func rebuildGraph(
        from tree: ChoiceTree,
        replacing oldGraph: ChoiceGraph,
        stats: inout ReductionStats
    ) -> (graph: ChoiceGraph, diff: ChoiceGraphDiff) {
        stats.graphStats.dynamicRegionRebuilds += oldGraph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += oldGraph.graphStats.dynamicRegionNodesRebuilt
        let oldConvergence = extractAllConvergence(from: oldGraph)
        let inheritedClassifications = oldGraph.bindClassifications
        let inheritedObservations = oldGraph.bindTopologyObservations
        var newGraph = ChoiceGraph.build(
            from: tree,
            inheriting: inheritedClassifications,
            observations: inheritedObservations
        )
        newGraph.observeBindTopologies(tree: tree)
        transferConvergence(oldConvergence, to: &newGraph)
        let diff = ChoiceGraphDiff.diff(old: oldGraph, new: newGraph)
        stats.graphStats.fullGraphRebuilds += 1
        return (graph: newGraph, diff: diff)
    }

    // MARK: - Reorder Pass

    private static func runReorderPass(state: inout ReductionState) throws {
        guard let reorderScope = ReorderingQuery.build(graph: state.graph) else { return }
        let reorderTransformation = GraphTransformation(
            operation: .reorder(reorderScope),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        )
        let reorderScopeBundle = EncoderInput(
            transformation: reorderTransformation,
            baseSequence: state.sequence,
            tree: state.tree,
            graph: state.graph,
            warmStartRecords: [:]
        )
        var reorderEncoder: any GraphEncoder = GraphReorderEncoder()
        let savedRejectCache = state.rejectCache
        state.rejectCache = []
        let reorderOutcome = try runProbeLoop(
            encoder: &reorderEncoder,
            scope: reorderScopeBundle,
            state: &state
        )
        state.rejectCache = savedRejectCache
        if state.isInstrumented, reorderOutcome.accepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
    }

    // MARK: - Source Selection

    /// Returns the index of the source with the highest peekPriority, or nil if all are exhausted.
    static func highestPrioritySourceIndex(
        _ sources: [any CandidateSource]
    ) -> Int? {
        var bestIndex: Int?
        var bestPriority: DispatchPriority?
        for (index, source) in sources.enumerated() {
            guard let priority = source.peekPriority else { continue }
            if let currentBest = bestPriority {
                if priority > currentBest {
                    bestIndex = index
                    bestPriority = priority
                }
            } else {
                bestIndex = index
                bestPriority = priority
            }
        }
        return bestIndex
    }

    // MARK: - Instrumentation

    @inline(__always)
    static func logReducer(
        _ event: String,
        isInstrumented: Bool,
        metadata: @autoclosure () -> [String: String]
    ) {
        guard isInstrumented else { return }
        ExhaustLog.debug(category: .reducer, event: event, metadata: metadata())
    }

    // MARK: - Post-Acceptance Evaluation

    /// What the scheduler should do after a probe loop completes.
    enum PostAcceptanceAction: Equatable {
        /// Value-only change. The graph is still structurally valid; continue dispatching from the current source set.
        case continueDispatching

        /// Structural change or bound value acceptance. The graph must be rebuilt from the tree before the next dispatch.
        case rebuildAndResume(treeIsStripped: Bool)
    }

    /// Determines whether the scheduler should rebuild the graph after an accepted probe.
    ///
    /// Pure function of the probe outcome and the operation type. Does not perform the rebuild or any other effect.
    static func evaluateAcceptance(
        outcome: ProbeLoopOutcome,
        operation: GraphOperation
    ) -> PostAcceptanceAction {
        guard outcome.accepted else {
            return .continueDispatching
        }
        let isBoundValue = switch operation {
        case .minimize(.boundValue):
            true
        default:
            false
        }
        if outcome.requiresRebuild || isBoundValue {
            return .rebuildAndResume(treeIsStripped: outcome.treeIsStripped)
        }
        return .continueDispatching
    }

    // MARK: - Dispatch Evaluation

    /// Decision returned by ``evaluateDispatch`` indicating what the inner loop should do with a candidate transformation.
    enum DispatchDecision: Equatable {
        /// Skip this transformation and continue to the next candidate.
        case skip

        /// The operation targets a bound value scope whose bind has not been classified yet. The scheduler must run the classification effect and then re-evaluate with the classification result.
        case classifyBind(bindNodeID: Int, fingerprint: UInt64)

        /// The graph is stripped (picks not materialized) and the operation is path-changing. The scheduler must rematerialize and rebuild before continuing.
        case rematerialize

        /// The transformation passed all gates and is ready to dispatch.
        case readyToDispatch(boundValueFingerprint: UInt64?)
    }

    /// Determines whether a candidate transformation should be dispatched, skipped, or requires an effect before proceeding.
    ///
    /// Pure function of the transformation, graph state, caches, and flags. Does not mutate the graph, gate, or caches.
    static func evaluateDispatch(
        transformation: GraphTransformation,
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        gate: BoundValueGate,
        scopeCache: CandidateRejectionCache,
        graphIsStripped: Bool,
        anyAccepted: Bool
    ) -> DispatchDecision {
        guard transformation.operation.isValid(in: graph) else {
            return .skip
        }

        if scopeCache.isRejected(
            operation: transformation.operation,
            sequence: sequence,
            graph: graph
        ) {
            return .skip
        }

        if case let .minimize(.boundValue(bindScope)) = transformation.operation {
            guard bindScope.bindNodeID < graph.nodes.count,
                  case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind
            else {
                return .skip
            }
            let fingerprint = bindMetadata.fingerprint

            switch gate.shouldDispatch(fingerprint: fingerprint, anyAcceptedThisCycle: anyAccepted) {
            case .skip:
                return .skip
            case .classifyFirst:
                if let cached = graph.bindClassifications[fingerprint] {
                    if cached.topology != .identical || cached.liftability != .both {
                        return .skip
                    }
                } else {
                    return .classifyBind(bindNodeID: bindScope.bindNodeID, fingerprint: fingerprint)
                }
            case .dispatch:
                break
            }

            return .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        if graphIsStripped, transformation.operation.isPathChanging {
            return .rematerialize
        }

        return .readyToDispatch(boundValueFingerprint: nil)
    }

    // MARK: - Encoder Selection

    /// Selects the appropriate encoder for a graph operation type.
    ///
    /// Bound value minimization scopes are not handled here because they need the typed generator at construction time. The dispatch site in ``runCore(gen:initialTree:initialOutput:config:collectStats:property:)`` builds them via ``makeBoundValueComposition(bindScope:scope:graph:gen:upstreamBudget:)`` instead.
    static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
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

    // MARK: - Post-Cycle Evaluation

    /// Snapshot of what happened during a single reduction cycle, used by ``evaluatePostCycle`` to determine the next action.
    struct CycleOutcome: Sendable {
        let anyAccepted: Bool
        let hadReplacementShortlexRejection: Bool
        let allConverged: Bool
        let improved: Bool
        let structurallyImproved: Bool
    }

    /// Actions the scheduler should take after a reduction cycle completes.
    ///
    /// Termination is not an action — it depends on post-effect state (a successful relax round prevents termination; convergence confirmation can clear stale floors that change the `allValuesConverged` result). The caller re-checks termination conditions after executing all actions.
    enum PostCycleAction: Equatable, Sendable {
        case confirmConvergence
        case relaxRound
        case releaseDeferral
    }

    /// Result of evaluating a cycle's outcome, containing the actions to take and updated loop control state.
    struct PostCycleEvaluation: Equatable, Sendable {
        let actions: [PostCycleAction]
        let newStallBudget: Int
        let newDeferBindInner: Bool
    }

    /// Determines what should happen after a reduction cycle completes.
    ///
    /// Pure function of the cycle outcome, current stall budget, deferral state, and max stalls. Returns the ordered list of actions to attempt and the updated loop control values.
    static func evaluatePostCycle(
        outcome: CycleOutcome,
        stallBudget: Int,
        maxStalls: Int,
        deferBindInner: Bool
    ) -> PostCycleEvaluation {
        var actions: [PostCycleAction] = []

        if outcome.anyAccepted == false, outcome.allConverged {
            actions.append(.confirmConvergence)
        }

        if outcome.anyAccepted == false, outcome.hadReplacementShortlexRejection {
            actions.append(.relaxRound)
        }

        let newStallBudget = outcome.improved ? maxStalls : stallBudget - 1

        var newDeferBindInner = deferBindInner
        if deferBindInner, outcome.structurallyImproved == false {
            newDeferBindInner = false
            actions.append(.releaseDeferral)
        }

        return PostCycleEvaluation(
            actions: actions,
            newStallBudget: newStallBudget,
            newDeferBindInner: newDeferBindInner
        )
    }
}
