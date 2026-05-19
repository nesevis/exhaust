//
//  CandidateSource.swift
//  Exhaust
//

// MARK: - Sorted Candidate Source

/// A stateless candidate source that emits pre-built transformations in priority order.
struct SortedCandidateSource {
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

// MARK: - Candidate Source Union

/// Inline-stored union of the three candidate source types. The dispatch loop iterates `[AnyCandidateSource]` and calls ``peekPriority`` and ``next(lastAccepted:)`` through a three-way switch, keeping all source data contiguous in the array buffer without heap-allocated boxes or indirect calls.
enum AnyCandidateSource {
    case sorted(SortedCandidateSource)
    case batchedCrossSequence(BatchedCrossSequenceRemovalSource)
    case batchRemoval(BatchRemovalSource)

    var peekPriority: DispatchPriority? {
        switch self {
        case let .sorted(source): source.peekPriority
        case let .batchedCrossSequence(source): source.peekPriority
        case let .batchRemoval(source): source.peekPriority
        }
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        switch self {
        case .sorted(var source):
            let result = source.next(lastAccepted: lastAccepted)
            self = .sorted(source)
            return result
        case .batchedCrossSequence(var source):
            let result = source.next(lastAccepted: lastAccepted)
            self = .batchedCrossSequence(source)
            return result
        case .batchRemoval(var source):
            let result = source.next(lastAccepted: lastAccepted)
            self = .batchRemoval(source)
            return result
        }
    }
}

// MARK: - Source Collection Builder

/// Builds the collection of candidate sources from a graph.
enum CandidateSourceBuilder {
    /// Assembles the full candidate source array by combining structural sources (removal, migration, replacement, permutation) with value sources (minimization, exchange). Structural sources are stable across structurally-identical rebuilds; value sources must be rebuilt after any leaf value change.
    static func buildSources(from graph: ChoiceGraph, deferBindInner: Bool = false, previousGraph: ChoiceGraph? = nil) -> [AnyCandidateSource] {
        buildStructuralSources(from: graph, previousGraph: previousGraph)
            + buildValueSources(from: graph, deferBindInner: deferBindInner)
    }

    /// Sources whose scopes depend on graph topology (node parent-child relationships, element counts, self-similarity edges) but not on leaf values. Stable across structurally-identical rebuilds.
    static func buildStructuralSources(from graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [AnyCandidateSource] {
        var sources: [AnyCandidateSource] = []

        let elementScopes = RemovalQuery.elementRemovalScopes(graph: graph)

        // Batched cross-sequence removal.
        let batchedSource = BatchedCrossSequenceRemovalSource(graph: graph)
        if batchedSource.peekPriority != nil {
            sources.append(.batchedCrossSequence(batchedSource))
        }

        // Sequence emptying.
        let emptyingCandidates = buildEmptyingCandidates(graph: graph, elementScopes: elementScopes)
        if emptyingCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(emptyingCandidates)))
        }

        // Batch removal — one source per sequence (stateful: geometric halving).
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else { continue }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekPriority != nil {
                sources.append(.batchRemoval(source))
            }
        }

        // Migration.
        let migrationCandidates = buildMigrationCandidates(graph: graph)
        if migrationCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(migrationCandidates)))
        }

        // Per-element removal.
        let perElementCandidates = buildPerElementCandidates(graph: graph, elementScopes: elementScopes)
        if perElementCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(perElementCandidates)))
        }

        // Aligned removal.
        let alignedCandidates = buildAlignedCandidates(graph: graph)
        if alignedCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(alignedCandidates)))
        }

        // Replacement.
        let replacementCandidates = buildReplacementCandidates(graph: graph, previousGraph: previousGraph)
        if replacementCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(replacementCandidates)))
        }

        // Permutation.
        let permutationCandidates = buildPermutationCandidates(graph: graph)
        if permutationCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(permutationCandidates)))
        }

        return sources
    }

    /// Sources whose scopes depend on leaf values (current ChoiceValue, valid ranges, distance-to-target). Must be rebuilt after any value change, even structurally-identical ones.
    static func buildValueSources(from graph: ChoiceGraph, deferBindInner: Bool = false) -> [AnyCandidateSource] {
        var sources: [AnyCandidateSource] = []

        // Minimization.
        let minimizationCandidates = buildMinimizationCandidates(graph: graph, deferBindInner: deferBindInner)
        if minimizationCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(minimizationCandidates)))
        }

        // Exchange.
        let exchangeCandidates = buildExchangeCandidates(graph: graph)
        if exchangeCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(exchangeCandidates)))
        }

        return sources
    }
}
