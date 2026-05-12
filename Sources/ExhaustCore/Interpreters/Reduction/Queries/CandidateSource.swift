//
//  CandidateSource.swift
//  Exhaust
//

// MARK: - Candidate Source Protocol

/// A pull-based iterator that produces transformations in priority-descending order.
///
/// Concrete conformers are either stateless (``SortedCandidateSource``) or stateful (``BatchedCrossSequenceRemovalSource``, ``BatchRemovalSource``). On structural acceptance, all sources are rebuilt from the new graph. On rejection, only the dispatched source advances.
protocol CandidateSource {
    var peekPriority: DispatchPriority? { get }
    mutating func next(lastAccepted: Bool) -> GraphTransformation?
}

// MARK: - Sorted Candidate Source

/// A stateless candidate source that emits pre-built transformations in priority order.
///
/// Replaces the eight per-operation-type source structs that all followed the same pattern: eagerly sort candidates at init, emit via incrementing index, ignore `lastAccepted`.
struct SortedCandidateSource: CandidateSource {
    private let transformations: [GraphTransformation]
    private var index = 0

    init(_ transformations: [GraphTransformation]) {
        self.transformations = transformations
    }

    var peekPriority: DispatchPriority? {
        guard index < transformations.count else { return nil }
        return transformations[index].priority
    }

    /// The first remaining transformation, for type inspection without consuming.
    var peekTransformation: GraphTransformation? {
        guard index < transformations.count else { return nil }
        return transformations[index]
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < transformations.count else { return nil }
        let result = transformations[index]
        index += 1
        return result
    }
}

// MARK: - Source Collection Builder

/// Builds the collection of candidate sources from a graph.
enum CandidateSourceBuilder {
    /// Assembles the full candidate source array by combining structural sources (removal, migration, replacement, permutation) with value sources (minimization, exchange). Structural sources are stable across structurally-identical rebuilds; value sources must be rebuilt after any leaf value change.
    static func buildSources(from graph: ChoiceGraph, deferBindInner: Bool = false, previousGraph: ChoiceGraph? = nil) -> [any CandidateSource] {
        buildStructuralSources(from: graph, previousGraph: previousGraph)
            + buildValueSources(from: graph, deferBindInner: deferBindInner)
    }

    /// Sources whose scopes depend on graph topology (node parent-child relationships, element counts, self-similarity edges) but not on leaf values. Stable across structurally-identical rebuilds.
    static func buildStructuralSources(from graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [any CandidateSource] {
        var sources: [any CandidateSource] = []

        let elementScopes = RemovalQuery.elementRemovalScopes(graph: graph)

        // Batched cross-sequence removal.
        let batchedSource = BatchedCrossSequenceRemovalSource(graph: graph)
        if batchedSource.peekPriority != nil {
            sources.append(batchedSource)
        }

        // Sequence emptying.
        let emptyingCandidates = buildEmptyingCandidates(graph: graph, elementScopes: elementScopes)
        if emptyingCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(emptyingCandidates))
        }

        // Batch removal — one source per sequence (stateful: geometric halving).
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekPriority != nil {
                sources.append(source)
            }
        }

        // Migration.
        let migrationCandidates = buildMigrationCandidates(graph: graph)
        if migrationCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(migrationCandidates))
        }

        // Per-element removal.
        let perElementCandidates = buildPerElementCandidates(graph: graph, elementScopes: elementScopes)
        if perElementCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(perElementCandidates))
        }

        // Aligned removal.
        let alignedCandidates = buildAlignedCandidates(graph: graph)
        if alignedCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(alignedCandidates))
        }

        // Replacement.
        let replacementCandidates = buildReplacementCandidates(graph: graph, previousGraph: previousGraph)
        if replacementCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(replacementCandidates))
        }

        // Permutation.
        let permutationCandidates = buildPermutationCandidates(graph: graph)
        if permutationCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(permutationCandidates))
        }

        return sources
    }

    /// Sources whose scopes depend on leaf values (current ChoiceValue, valid ranges, distance-to-target). Must be rebuilt after any value change, even structurally-identical ones.
    static func buildValueSources(from graph: ChoiceGraph, deferBindInner: Bool = false) -> [any CandidateSource] {
        var sources: [any CandidateSource] = []

        // Minimization.
        let minimizationCandidates = buildMinimizationCandidates(graph: graph, deferBindInner: deferBindInner)
        if minimizationCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(minimizationCandidates))
        }

        // Exchange.
        let exchangeCandidates = buildExchangeCandidates(graph: graph)
        if exchangeCandidates.isEmpty == false {
            sources.append(SortedCandidateSource(exchangeCandidates))
        }

        return sources
    }
}
