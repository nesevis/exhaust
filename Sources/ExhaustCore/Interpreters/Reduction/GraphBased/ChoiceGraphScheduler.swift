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

        // Track which sequence nodes have had value changes since the
        // last structural rebuild. Deletion sources skip "clean" sequences
        // whose children haven't changed — re-probing them is wasted work.
        // All sequences start dirty (first cycle should try everything).
        var dirtySequenceNodeIDs: Set<Int>? = nil // nil = all dirty

        while stallBudget > 0 {
            cycles += 1
            let sequenceBeforeCycle = sequence

            // Build scope sources from the graph.
            var sources = ScopeSourceBuilder.buildSources(
                from: graph,
                dirtySequenceNodeIDs: dirtySequenceNodeIDs
            )

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

                // Harvest convergence from value encoders.
                let convergence = encoder.convergenceRecords
                if convergence.isEmpty == false {
                    graph.recordConvergence(convergence)
                }

                if accepted {
                    anyAccepted = true

                    if transformation.postcondition.isStructural {
                        // Structural acceptance: rebuild graph and ALL sources.
                        // All sequences are dirty after rebuild.
                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
                        transferConvergence(oldConvergence, to: graph)
                        stats.graphRebuilds += 1
                        dirtySequenceNodeIDs = nil // nil = all dirty
                        sources = ScopeSourceBuilder.buildSources(
                            from: graph,
                            dirtySequenceNodeIDs: dirtySequenceNodeIDs
                        )

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
                    } else {
                        // Value acceptance: mark the affected sequences as dirty.
                        // Find which sequence nodes contain the changed leaves.
                        if dirtySequenceNodeIDs == nil {
                            dirtySequenceNodeIDs = Set<Int>()
                        }
                        markDirtySequences(
                            for: transformation,
                            in: graph,
                            dirtySet: &dirtySequenceNodeIDs
                        )
                    }
                }
                // Rejection: the source already advanced via next(lastAccepted:).
                // Continue pulling from the highest-yield source.
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

    /// Extracts all convergence records from graph nodes.
    private static func extractAllConvergence(from graph: ChoiceGraph) -> [Int: ConvergedOrigin] {
        extractWarmStarts(from: graph)
    }

    /// Transfers convergence records from old graph positions to matching leaves in the new graph.
    private static func transferConvergence(
        _ records: [Int: ConvergedOrigin],
        to graph: ChoiceGraph
    ) {
        for nodeID in graph.leafNodes {
            guard case .chooseBits = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard let oldRecord = records[range.lowerBound] else { continue }
            graph.recordConvergence([range.lowerBound: oldRecord])
        }
    }

    // MARK: - Dirty Sequence Tracking

    /// Marks sequence nodes whose children were affected by a value transformation as dirty.
    private static func markDirtySequences(
        for transformation: GraphTransformation,
        in graph: ChoiceGraph,
        dirtySet: inout Set<Int>?
    ) {
        // Find leaf node IDs involved in the transformation.
        let leafNodeIDs: [Int]
        switch transformation.operation {
        case let .minimize(scope):
            switch scope {
            case let .integerLeaves(integerScope):
                leafNodeIDs = integerScope.leafNodeIDs
            case let .floatLeaves(floatScope):
                leafNodeIDs = floatScope.leafNodeIDs
            case let .kleisliFibre(fibreScope):
                leafNodeIDs = [fibreScope.upstreamLeafNodeID] + fibreScope.downstreamNodeIDs
            }
        case let .exchange(scope):
            switch scope {
            case let .redistribution(redistScope):
                leafNodeIDs = redistScope.pairs.flatMap { [$0.sourceNodeID, $0.sinkNodeID] }
            case let .tandem(tandemScope):
                leafNodeIDs = tandemScope.groups.flatMap(\.leafNodeIDs)
            }
        default:
            return // Structural operations don't mark dirty — they rebuild.
        }

        // Walk up from each leaf to find its containing sequence node.
        for leafNodeID in leafNodeIDs {
            var current = leafNodeID
            while let parentID = graph.nodes[current].parent {
                if case .sequence = graph.nodes[parentID].kind {
                    if dirtySet == nil { dirtySet = Set() }
                    dirtySet?.insert(parentID)
                    break
                }
                current = parentID
            }
        }
    }
}
