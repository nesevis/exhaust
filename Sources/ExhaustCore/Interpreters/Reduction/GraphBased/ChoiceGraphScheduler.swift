//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives graph encoders in a two-pass priority-ordered cycle until convergence or stall budget exhaustion.
///
/// Each cycle:
/// 1. Builds a yield-ordered queue from the ``ChoiceGraph`` via ``TransformationQueueBuilder``.
/// 2. **Pass 1 (structural):** runs structural encoders (deletion, substitution, pivot, swap) in yield order. On any structural acceptance, rebuilds the graph and restarts pass 1.
/// 3. **Pass 2 (value):** runs value encoders (value search, float search) in value-yield order. Records convergence on graph nodes for warm-start.
/// 4. **Stall escape:** if neither pass made progress, runs redistribution and tandem.
///
/// - SeeAlso: ``BonsaiScheduler``, ``TransformationQueueBuilder``
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

        // Encoder instances — preserved across cycles for internal state continuity.
        var encoders = EncoderSet(gen: gen, property: property)

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

            // Build the yield-ordered queue for this cycle.
            let queue = TransformationQueueBuilder.buildQueue(from: graph)

            // Pass 1: structural encoders, ordered by yield.
            // Run all structural encoders. On any acceptance, rebuild the graph
            // and restart pass 1 within this cycle. Only proceed to pass 2 when
            // all structural encoders are exhausted.
            let structuralSlots = queue.filter { $0.yield.tier == .structural }
            var structuralProgress = false
            var restartPass1 = true

            while restartPass1 {
                restartPass1 = false
                for entry in structuralSlots {
                    let accepted = try state.runSlot(
                        entry.slot,
                        encoders: &encoders,
                        graph: graph,
                        gen: gen,
                        property: property
                    )
                    if accepted {
                        structuralProgress = true
                        graph = ChoiceGraph.build(from: state.tree)
                        state.stats.graphRebuilds += 1
                        restartPass1 = true
                        break
                    }
                }
            }

            // Pass 2: value encoders, ordered by value yield.
            // Always runs after pass 1 — value reduction unlocks further
            // structural deletions in subsequent cycles.
            if state.sequence != sequenceBeforeCycle {
                // Structure changed in pass 1 — rebuild graph for value pass.
                graph = ChoiceGraph.build(from: state.tree)
                state.stats.graphRebuilds += 1
            }

            let valueSlots = queue.filter { $0.yield.tier == .value }
            for entry in valueSlots {
                try state.runSlot(
                    entry.slot,
                    encoders: &encoders,
                    graph: graph,
                    gen: gen,
                    property: property
                )
            }

            // Harvest convergence records onto graph nodes.
            let intConvergence = encoders.valueSearchEncoder.convergenceRecords
            if intConvergence.isEmpty == false {
                graph.recordConvergence(intConvergence)
            }
            let floatConvergence = encoders.floatSearchEncoder.convergenceRecords
            if floatConvergence.isEmpty == false {
                graph.recordConvergence(floatConvergence)
            }

            // Stall escape: redistribution and tandem when no progress.
            let improved = state.sequence != sequenceBeforeCycle
            if improved == false {
                graph.invalidateDerivedEdges()
                try state.runSlot(
                    .redistribution,
                    encoders: &encoders,
                    graph: graph,
                    gen: gen,
                    property: property
                )
                try state.runSlot(
                    .tandem,
                    encoders: &encoders,
                    graph: graph,
                    gen: gen,
                    property: property
                )
            }

            // Rebuild graph next cycle if structure changed.
            let structurallyImproved = state.sequence.count < sequenceBeforeCycle.count
            let valueImproved = state.sequence != sequenceBeforeCycle
            if structurallyImproved {
                graph = ChoiceGraph.build(from: state.tree)
                state.stats.graphRebuilds += 1
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_end",
                    metadata: [
                        "cycle": "\(state.cycles)",
                        "improved": "\(valueImproved)",
                        "structural": "\(structurallyImproved)",
                        "seq_len": "\(state.sequence.count)",
                        "total_mats": "\(state.stats.totalMaterializations)",
                    ]
                )
            }

            if structurallyImproved || valueImproved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

            // Early exit: all value coordinates converged and no structural
            // progress — the counterexample is at a fixed point.
            if structurallyImproved == false, allValuesConverged(in: state.sequence, graph: graph) {
                break
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

    /// Returns true when every leaf value is either at its reduction target or has a convergence record indicating it has been searched.
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
}

// MARK: - Encoder Set

/// Holds all encoder instances, preserved across cycles for internal state continuity.
private struct EncoderSet<Output> {
    var branchPivotEncoder = GraphBranchPivotEncoder()
    var substitutionEncoder = GraphSubstitutionEncoder()
    var siblingSwapEncoder = GraphSiblingSwapEncoder()
    var deletionEncoder = GraphDeletionEncoder()
    var valueSearchEncoder = GraphValueSearchEncoder()
    var floatSearchEncoder = GraphFloatSearchEncoder()
    var redistributionEncoder = GraphRedistributionEncoder()
    var tandemEncoder = GraphTandemReductionEncoder()
    var kleisliFibreEncoder: GraphKleisliFibreEncoder<Output>

    init(gen: ReflectiveGenerator<Output>, property: @escaping (Output) -> Bool) {
        kleisliFibreEncoder = GraphKleisliFibreEncoder(gen: gen, property: property)
    }
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

    /// Runs the encoder for a given slot through its probe loop.
    @discardableResult
    mutating func runSlot(
        _ slot: EncoderSlot,
        encoders: inout EncoderSet<Output>,
        graph: ChoiceGraph,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool
    ) throws -> Bool {
        switch slot {
        case .branchPivot:
            return try runEncoder(&encoders.branchPivotEncoder, graph: graph, gen: gen, property: property)
        case .substitution:
            return try runEncoder(&encoders.substitutionEncoder, graph: graph, gen: gen, property: property)
        case .siblingSwap:
            return try runEncoder(&encoders.siblingSwapEncoder, graph: graph, gen: gen, property: property)
        case .deletion:
            return try runEncoder(&encoders.deletionEncoder, graph: graph, gen: gen, property: property)
        case .valueSearch:
            return try runEncoder(&encoders.valueSearchEncoder, graph: graph, gen: gen, property: property)
        case .floatSearch:
            return try runEncoder(&encoders.floatSearchEncoder, graph: graph, gen: gen, property: property)
        case .redistribution:
            return try runEncoder(&encoders.redistributionEncoder, graph: graph, gen: gen, property: property)
        case .tandem:
            return try runEncoder(&encoders.tandemEncoder, graph: graph, gen: gen, property: property)
        }
    }

    /// Runs a single graph encoder through its probe loop, accepting improvements.
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
