//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Drives the four graph encoders in a cycle loop until convergence or stall budget exhaustion.
///
/// Each cycle:
/// 1. Builds a ``ChoiceGraph`` from the current tree.
/// 2. Runs ``GraphBranchPivotEncoder`` (structural simplification).
/// 3. Runs ``GraphDeletionEncoder`` (structural removal).
/// 4. Runs ``GraphValueSearchEncoder`` (value minimisation).
/// 5. Runs ``GraphRedistributionEncoder`` (speculative, on stall only).
/// 6. If improved, rebuilds the graph and repeats. If stalled, decrements the stall counter.
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
        var state = SchedulerState(
            sequence: ChoiceSequence.flatten(initialTree),
            tree: initialTree,
            output: initialOutput,
            collectStats: collectStats
        )

        var branchPivotEncoder = GraphBranchPivotEncoder()
        var substitutionEncoder = GraphSubstitutionEncoder()
        var deletionEncoder = GraphDeletionEncoder()
        var valueSearchEncoder = GraphValueSearchEncoder()
        var redistributionEncoder = GraphRedistributionEncoder()
        var kleisliFibreEncoder = GraphKleisliFibreEncoder(gen: gen, property: property)

        var stallBudget = config.maxStalls

        while stallBudget > 0 {
            state.cycles += 1
            let graph = ChoiceGraph.build(from: state.tree)
            var improved = false

            // Phase 1: Branch pivot (structural simplification).
            if try state.runEncoder(&branchPivotEncoder, graph: graph, gen: gen, property: property) {
                improved = true
            }

            // Phase 2: Subtree substitution (self-similarity edge splicing).
            if try state.runEncoder(&substitutionEncoder, graph: graph, gen: gen, property: property) {
                improved = true
            }

            // Phase 3: Deletion (structural removal).
            if try state.runEncoder(&deletionEncoder, graph: graph, gen: gen, property: property) {
                improved = true
            }

            // Rebuild graph after structural changes before value minimisation.
            let valueGraph = improved ? ChoiceGraph.build(from: state.tree) : graph

            // Phase 4: Value search (value minimisation).
            if try state.runEncoder(&valueSearchEncoder, graph: valueGraph, gen: gen, property: property) {
                improved = true
            }

            // Phase 5: Kleisli fibre search (joint upstream/downstream exploration).
            if try state.runEncoder(&kleisliFibreEncoder, graph: valueGraph, gen: gen, property: property) {
                improved = true
            }

            // Phase 6: Redistribution (speculative, on stall only).
            if improved == false {
                let redistGraph = ChoiceGraph.build(from: state.tree)
                if try state.runEncoder(&redistributionEncoder, graph: redistGraph, gen: gen, property: property) {
                    improved = true
                }
            }

            if improved {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }
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

    /// Reject cache using Zobrist hashing.
    var rejectCache = Set<UInt64>()

    /// Runs a single graph encoder through its probe loop, accepting improvements.
    ///
    /// - Returns: Whether any probe was accepted during this encoder pass.
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

        return anyAccepted
    }
}
