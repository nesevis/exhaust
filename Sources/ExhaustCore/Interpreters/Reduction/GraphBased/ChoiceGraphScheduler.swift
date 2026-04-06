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

        // Scope rejection cache: tracks rejected structural operations
        // by position-scoped Zobrist hash. Naturally invalidates when
        // targeted values change. Cleared on structural acceptance.
        var scopeRejectionCache = ScopeRejectionCache()

        while stallBudget > 0 {
            cycles += 1
            let sequenceBeforeCycle = sequence

            // TODO: incremental refresh causes stale position mappings on
            // generators with structural changes mid-cycle (BinaryHeap).
            // Full rebuild until position tracking is fixed.
            let oldConvergenceForRebuild = extractAllConvergence(from: graph)
            graph = ChoiceGraph.build(from: tree)
            transferConvergence(oldConvergenceForRebuild, to: graph)
            // graph.refreshLeafValues(from: sequence)

            // Build scope sources from the refreshed graph.
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
                        // Structural acceptance: rebuild graph, clear scope cache, rebuild sources.
                        let oldConvergence = extractAllConvergence(from: graph)
                        graph = ChoiceGraph.build(from: tree)
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
                    } else {
                        // Value acceptance: clear convergence on changed leaves.
                        // Scope rejection cache self-invalidates via hash change.
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
                    // Stale floors cleared — rebuild sources. Scope rejection
                    // cache self-invalidates via hash change at affected positions.
                    sources = ScopeSourceBuilder.buildSources(from: graph)
                }
            }

            // Relax round: if all sources exhausted AND staleness found
            // nothing, try speculative redistribution with exploitation.
            if anyAccepted == false {
                let relaxResult = try runRelaxRound(
                    sequence: &sequence,
                    tree: &tree,
                    output: &output,
                    graph: &graph,
                    gen: gen,
                    property: property,
                    rejectCache: &rejectCache,
                    stats: &stats,
                    collectStats: collectStats,
                    isInstrumented: isInstrumented
                )
                if relaxResult {
                    anyAccepted = true
                    scopeRejectionCache.clear()
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

    // MARK: - Relax Round

    // swiftlint:disable function_parameter_count
    /// Runs the speculative relax round: checkpoint, redistribute without shortlex gate, exploit, compare, commit or rollback.
    ///
    /// - Returns: True if the relax round produced a net improvement (committed).
    private static func runRelaxRound<Output>(
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Output,
        graph: inout ChoiceGraph,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> Bool {
        // Checkpoint current state.
        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointConvergence = extractAllConvergence(from: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_start",
                metadata: ["seq_len": "\(sequence.count)"]
            )
        }

        // Build speculative exchange scopes (no position constraint).
        let speculativeScopes = graph.speculativeExchangeScopes()
        guard speculativeScopes.isEmpty == false else { return false }

        // Run exchange encoder with .exact() decoder (no shortlex gate).
        var anyRedistributionAccepted = false
        for exchangeScope in speculativeScopes {
            let transformation = GraphTransformation(
                operation: .exchange(exchangeScope),
                yield: TransformationYield(structural: 0, value: 0, slack: .exact, estimatedProbes: 24),
                precondition: .unconditional,
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            )
            let scope = TransformationScope(
                transformation: transformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            )

            var encoder = GraphExchangeEncoder()
            encoder.start(scope: scope)

            var lastAccepted = false
            while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
                lastAccepted = false

                // Use .exact() decoder — no shortlex check.
                // The final comparison against the checkpoint handles acceptance.
                let decoder: SequenceDecoder = .exact()
                var filterObservations: [UInt64: FilterObservation] = [:]

                if let result = try decoder.decode(
                    candidate: probe,
                    gen: gen,
                    tree: tree,
                    originalSequence: sequence,
                    property: property,
                    filterObservations: &filterObservations
                ) {
                    // Accept without shortlex check — speculative.
                    sequence = result.sequence
                    tree = result.tree
                    output = result.output
                    lastAccepted = true
                    anyRedistributionAccepted = true
                }

                if collectStats {
                    stats.totalMaterializations += 1
                }
            }
        }

        guard anyRedistributionAccepted else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "relax_round_no_redistribution",
                    metadata: [:]
                )
            }
            return false
        }

        // Exploitation: rebuild graph and run full source loop on relaxed state.
        graph = ChoiceGraph.build(from: tree)
        stats.graphRebuilds += 1
        var exploitSources = ScopeSourceBuilder.buildSources(from: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_exploitation_start",
                metadata: [
                    "seq_len": "\(sequence.count)",
                    "sources": "\(exploitSources.count)",
                ]
            )
        }

        // Run the standard source-pulling loop on the relaxed state.
        while true {
            guard let sourceIndex = highestYieldSourceIndex(exploitSources) else {
                break
            }
            guard let transformation = exploitSources[sourceIndex].next(lastAccepted: false) else {
                exploitSources.remove(at: sourceIndex)
                continue
            }
            guard transformation.precondition.isSatisfied(in: graph) else {
                continue
            }

            let warmStarts = extractWarmStarts(from: graph)
            let scope = TransformationScope(
                transformation: transformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: warmStarts
            )

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

            let convergence = encoder.convergenceRecords
            if convergence.isEmpty == false {
                graph.recordConvergence(convergence)
            }

            if accepted, transformation.postcondition.isStructural {
                graph = ChoiceGraph.build(from: tree)
                stats.graphRebuilds += 1
                exploitSources = ScopeSourceBuilder.buildSources(from: graph)
            }
        }

        // Final comparison: commit if improved, rollback otherwise.
        if sequence.shortLexPrecedes(checkpointSequence) {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "relax_round_committed",
                    metadata: [
                        "old_seq_len": "\(checkpointSequence.count)",
                        "new_seq_len": "\(sequence.count)",
                    ]
                )
            }
            return true
        }

        // Rollback: restore checkpoint state.
        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        graph = ChoiceGraph.build(from: tree)
        transferConvergence(checkpointConvergence, to: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_rolled_back",
                metadata: ["seq_len": "\(sequence.count)"]
            )
        }
        return false
    }
    // swiftlint:enable function_parameter_count

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

            let probeHash = ZobristHash.incrementalHash(
                baseHash: ZobristHash.hash(of: sequence),
                baseSequence: sequence,
                probe: candidate
            )
            if rejectCache.contains(probeHash) { continue }

            let hasBind = sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree)
                : .exact()

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
