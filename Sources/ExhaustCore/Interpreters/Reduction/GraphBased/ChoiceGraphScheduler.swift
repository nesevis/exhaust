//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives the six graph encoders in a cycle loop until convergence or stall budget exhaustion.
///
/// Each cycle:
/// 1. Builds a ``ChoiceGraph`` from the current tree.
/// 2. Runs ``GraphBranchPivotEncoder`` (structural simplification).
/// 3. Runs ``GraphSubstitutionEncoder`` (self-similarity edge splicing).
/// 4. Runs ``GraphDeletionEncoder`` (structural removal).
/// 5. Runs ``GraphValueSearchEncoder`` (value minimisation).
/// 6. Runs ``GraphKleisliFibreEncoder`` (joint upstream/downstream exploration).
/// 7. Runs ``GraphRedistributionEncoder`` (speculative, on stall only).
///
/// - SeeAlso: ``BonsaiScheduler``
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
        var state = SchedulerState(
            sequence: ChoiceSequence.flatten(initialTree),
            tree: initialTree,
            output: initialOutput,
            collectStats: collectStats,
            isInstrumented: isInstrumented
        )

        var branchPivotEncoder = GraphBranchPivotEncoder()
        var substitutionEncoder = GraphSubstitutionEncoder()
        var siblingSwapEncoder = GraphSiblingSwapEncoder()
        var deletionEncoder = GraphDeletionEncoder()
        var valueSearchEncoder = GraphValueSearchEncoder()
        var floatSearchEncoder = GraphFloatSearchEncoder()
        var redistributionEncoder = GraphRedistributionEncoder()
        var tandemEncoder = GraphTandemReductionEncoder()
        var kleisliFibreEncoder = GraphKleisliFibreEncoder(gen: gen, property: property)

        var stallBudget = config.maxStalls

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_reducer_start",
                metadata: [
                    "seq_len": "\(state.sequence.count)",
                    "max_stalls": "\(config.maxStalls)",
                ]
            )
        }

        var graph = ChoiceGraph.build(from: state.tree)
        var graphDirty = false

        if collectStats {
            state.stats.graphNodeCount = graph.nodes.count
            state.stats.graphDependencyEdgeCount = graph.dependencyEdges.count
            state.stats.graphContainmentEdgeCount = graph.containmentEdges.count
            state.stats.graphSelfSimilarityEdgeCount = graph.selfSimilarityEdges.count
            state.stats.graphDeletionAntichainSize = graph.deletionAntichain.count
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_construction",
                metadata: [
                    "nodes": "\(graph.nodes.count)",
                    "dependency_edges": "\(graph.dependencyEdges.count)",
                    "containment_edges": "\(graph.containmentEdges.count)",
                    "self_similarity_edges": "\(graph.selfSimilarityEdges.count)",
                    "type_compat_edges": "\(graph.typeCompatibilityEdges.count)",
                    "deletion_antichain": "\(graph.deletionAntichain.count)",
                ]
            )
        }

        while stallBudget > 0 {
            state.cycles += 1
            let sequenceBeforeCycle = state.sequence

            // Rebuild graph only when the previous cycle made structural changes.
            if graphDirty {
                graph = ChoiceGraph.build(from: state.tree)
                graphDirty = false
                state.stats.graphRebuilds += 1
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_start",
                    metadata: [
                        "cycle": "\(state.cycles)",
                        "seq_len": "\(state.sequence.count)",
                        "nodes": "\(graph.nodes.count)",
                        "stall_budget": "\(stallBudget)",
                    ]
                )
            }

            // Phase 1: Branch pivot (structural simplification).
            try state.runEncoder(&branchPivotEncoder, graph: graph, gen: gen, property: property)

            // Phase 2: Subtree substitution (self-similarity edge splicing).
            try state.runEncoder(&substitutionEncoder, graph: graph, gen: gen, property: property)

            // Phase 3: Sibling swap (reorder same-shaped siblings for shortlex improvement).
            try state.runEncoder(&siblingSwapEncoder, graph: graph, gen: gen, property: property)

            // Phase 4: Deletion (structural removal).
            try state.runEncoder(&deletionEncoder, graph: graph, gen: gen, property: property)

            // If structural encoders changed the sequence, rebuild the graph for value passes.
            let structurallyChanged = state.sequence != sequenceBeforeCycle
            if structurallyChanged {
                graph = ChoiceGraph.build(from: state.tree)
                state.stats.graphRebuilds += 1
            }

            // Phase 4: Value search (value minimisation).
            try state.runEncoder(&valueSearchEncoder, graph: graph, gen: gen, property: property)

            // Write convergence records onto leaf nodes for warm-start in subsequent cycles.
            let convergenceRecords = valueSearchEncoder.convergenceRecords
            if convergenceRecords.isEmpty == false {
                graph.recordConvergence(convergenceRecords)
            }

            // Phase 4b: Float search (four-stage IEEE 754 pipeline).
            try state.runEncoder(&floatSearchEncoder, graph: graph, gen: gen, property: property)

            let floatConvergenceRecords = floatSearchEncoder.convergenceRecords
            if floatConvergenceRecords.isEmpty == false {
                graph.recordConvergence(floatConvergenceRecords)
            }

            // Phase 5: Kleisli fibre search (joint upstream/downstream exploration).
            // TODO: Re-enable once downstream scoping and covering array performance are resolved.
            // try state.runEncoder(&kleisliFibreEncoder, graph: graph, gen: gen, property: property)

            // Phase 6: Redistribution and tandem (speculative, on stall only).
            let improved = state.sequence != sequenceBeforeCycle
            if improved == false {
                graph.invalidateDerivedEdges()
                try state.runEncoder(&redistributionEncoder, graph: graph, gen: gen, property: property)
                try state.runEncoder(&tandemEncoder, graph: graph, gen: gen, property: property)
            }

            // Mark graph dirty if structure changed this cycle so it's rebuilt next cycle.
            if state.sequence.count != sequenceBeforeCycle.count {
                graphDirty = true
            }

            let cycleImproved = state.sequence != sequenceBeforeCycle

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_end",
                    metadata: [
                        "cycle": "\(state.cycles)",
                        "improved": "\(cycleImproved)",
                        "seq_len": "\(state.sequence.count)",
                        "total_mats": "\(state.stats.totalMaterializations)",
                    ]
                )
            }

            if cycleImproved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }
        }

        if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "graph_reducer_complete",
                metadata: [
                    "cycles": "\(state.cycles)",
                    "seq_len": "\(state.sequence.count)",
                    "total_mats": "\(state.stats.totalMaterializations)",
                ]
            )
        }

        state.stats.cycles = state.cycles
        return (reduced: (state.sequence, state.output), stats: state.stats)
    }
    // swiftlint:enable function_parameter_count
}

// MARK: - Scheduler State

/// Mutable state for the graph-based reduction cycle loop.
private struct SchedulerState<Output> {
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Output
    var stats = ReductionStats()
    var cycles = 0
    let collectStats: Bool
    let isInstrumented: Bool

    /// Reject cache using Zobrist hashing.
    var rejectCache = Set<UInt64>()

    /// Convergence cache keyed by flat sequence index.
    var convergenceCache: [Int: ConvergedOrigin] = [:]

    mutating func recordConvergence(_ records: [Int: ConvergedOrigin]) {
        for (index, origin) in records {
            convergenceCache[index] = origin
        }
    }

    /// Runs a single graph encoder through its probe loop, accepting improvements.
    ///
    /// - Returns: Whether any probe was accepted during this encoder pass.
    @discardableResult
    mutating func runEncoder<Encoder: GraphEncoder>(
        _ encoder: inout Encoder,
        graph: ChoiceGraph,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool
    ) throws -> Bool {
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        var lastAccepted = false
        var anyAccepted = false
        var probeCount = 0
        var acceptCount = 0
        var rejectCacheHits = 0
        let baseHash = ZobristHash.hash(of: sequence)

        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = false

            let probeHash = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: sequence,
                probe: probe
            )
            if rejectCache.contains(probeHash) {
                rejectCacheHits += 1
                continue
            }

            // Determine decoder mode based on whether binds exist.
            let hasBind = sequence.contains(where: { entry in
                if case .bind = entry { return true }
                return false
            })
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree)
                : .exact()

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decode(
                candidate: probe,
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
            } else {
                rejectCache.insert(probeHash)
            }

            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        if collectStats {
            stats.encoderProbes[encoder.name, default: 0] += probeCount
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "graph_encoder_pass",
                metadata: [
                    "encoder": encoder.name.rawValue,
                    "probes": "\(probeCount)",
                    "accepted": "\(acceptCount)",
                    "cache_hits": "\(rejectCacheHits)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        return anyAccepted
    }
}
