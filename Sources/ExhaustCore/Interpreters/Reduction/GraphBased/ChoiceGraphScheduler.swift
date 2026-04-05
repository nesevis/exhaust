//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives scope-dispatched graph encoders in a yield-ordered cycle until convergence or stall budget exhaustion.
///
/// Each cycle:
/// 1. Enumerates all transformation scopes from the graph via ``TransformationEnumerator``.
/// 2. Walks the sorted queue in yield order, checking preconditions and dispatching to encoders.
/// 3. On structural acceptance: rebuilds the graph, transfers convergence, and restarts the queue.
/// 4. On value acceptance: harvests convergence records and continues the queue.
/// 5. On stall (no acceptance in the full queue): decrements stall budget.
///
/// - SeeAlso: ``TransformationEnumerator``, ``GraphEncoder``, ``TransformationScope``
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
        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        var output = initialOutput
        var stats = ReductionStats()
        var cycles = 0
        var stallBudget = config.maxStalls
        var rejectCache = Set<UInt64>()

        var graph = ChoiceGraph.build(from: tree)

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

        while stallBudget > 0 {
            cycles += 1
            let sequenceBeforeCycle = sequence

            // Enumerate scopes and build yield-ordered queue.
            let queue = TransformationEnumerator.enumerate(from: graph)

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "graph_cycle_start",
                    metadata: [
                        "cycle": "\(cycles)",
                        "seq_len": "\(sequence.count)",
                        "scopes": "\(queue.count)",
                        "stall_budget": "\(stallBudget)",
                    ]
                )
            }

            // Walk queue in yield order.
            var anyAccepted = false
            var restartQueue = false

            for transformation in queue {
                guard transformation.precondition.isSatisfied(in: graph) else {
                    continue
                }

                // Construct self-contained scope.
                let warmStarts = extractWarmStarts(
                    for: transformation,
                    from: graph
                )
                let scope = TransformationScope(
                    transformation: transformation,
                    baseSequence: sequence,
                    tree: tree,
                    graph: graph,
                    warmStartRecords: warmStarts
                )

                // Select encoder and run probe loop.
                var encoder = selectEncoder(for: transformation.operation)
                let accepted = try runProbeLoop(
                    encoder: &encoder,
                    scope: scope,
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

                // Harvest convergence records.
                let convergence = encoder.convergenceRecords
                if convergence.isEmpty == false {
                    graph.recordConvergence(convergence)
                }

                if accepted {
                    anyAccepted = true

                    if transformation.postcondition.isStructural {
                        // Structural change: rebuild graph and restart queue.
                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
                        transferConvergence(oldConvergence, to: graph)
                        stats.graphRebuilds += 1
                        restartQueue = true
                        break
                    }
                }
            }

            // If a structural acceptance restarted the queue, loop back to
            // re-enumerate from the new graph.
            if restartQueue {
                continue
            }

            // Stall handling.
            let improved = sequence != sequenceBeforeCycle
            if improved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

            // Early exit: all values converged and no structural progress.
            let structurallyImproved = sequence.count < sequenceBeforeCycle.count
            if structurallyImproved == false, allValuesConverged(in: sequence, graph: graph) {
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

        stats.cycles = cycles
        return (reduced: (sequence, output), stats: stats)
    }
    // swiftlint:enable function_parameter_count

    // MARK: - Encoder Selection

    /// Selects the appropriate encoder for a graph operation type.
    private static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
        switch operation {
        case .removal:
            return GraphRemovalEncoder()
        case .replacement:
            return GraphReplacementEncoder()
        case .minimisation:
            return GraphMinimisationEncoder()
        case .exchange:
            return GraphExchangeEncoder()
        case .permutation:
            return GraphPermutationEncoder()
        }
    }

    // MARK: - Probe Loop

    // swiftlint:disable function_parameter_count
    /// Runs an encoder's probe loop, accepting improvements.
    private static func runProbeLoop<Output>(
        encoder: inout any GraphEncoder,
        scope: TransformationScope,
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Output,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> Bool {
        encoder.start(scope: scope)

        var lastAccepted = false
        var anyAccepted = false
        var probeCount = 0
        var acceptCount = 0
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
                continue
            }

            let hasBind = sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
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

                // On structural acceptance, stop the encoder immediately.
                // The scheduler will rebuild the graph and restart.
                if scope.transformation.postcondition.isStructural {
                    break
                }
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
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        return anyAccepted
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

    /// Extracts warm-start convergence records for leaves relevant to a transformation.
    private static func extractWarmStarts(
        for transformation: GraphTransformation,
        from graph: ChoiceGraph
    ) -> [Int: ConvergedOrigin] {
        var records: [Int: ConvergedOrigin] = [:]
        // Collect convergence records from all leaf nodes that might
        // be relevant to this transformation.
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            records[range.lowerBound] = origin
        }
        return records
    }

    /// Extracts all convergence records from graph nodes.
    private static func extractAllConvergence(
        from graph: ChoiceGraph
    ) -> [Int: ConvergedOrigin] {
        var records: [Int: ConvergedOrigin] = [:]
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            records[range.lowerBound] = origin
        }
        return records
    }

    /// Transfers convergence records from old graph positions to matching leaves in the new graph.
    private static func transferConvergence(
        _ records: [Int: ConvergedOrigin],
        to graph: ChoiceGraph
    ) {
        // Two-tier transfer: structurally-constant bind subtrees match on
        // position + typeTag only. Non-constant subtrees require validRange match too.
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard let oldRecord = records[range.lowerBound] else { continue }

            // Position matches. Check type tag.
            // For simplicity in Phase 2, accept all position + typeTag matches.
            // The two-tier policy (structurally-constant vs non-constant) will
            // be refined in Phase 5.
            graph.recordConvergence([range.lowerBound: oldRecord])
        }
    }
}
