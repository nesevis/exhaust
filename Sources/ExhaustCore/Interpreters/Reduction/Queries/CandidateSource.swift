//
//  CandidateSource.swift
//  Exhaust
//

// MARK: - Candidate Source Contract

/// Adds scheduling and invalidation metadata to a cursor over graph transformations.
///
/// Priority inspection must not advance enumeration. Adaptive sources may advertise the next rejection continuation while awaiting feedback; the scheduler rebuilds sources after invalidating acceptances. Invalidation metadata describes the whole prepared source and remains available after exhaustion.
protocol CandidateSource: ScopeCursor where Scope == GraphTransformation {
    var peekPriority: DispatchPriority? { get }
    var isValueDependent: Bool { get }
    var isPermutationSource: Bool { get }
}

extension CandidateSource {
    /// Leaf-kind changes invalidate value-dependent scopes and sibling-shape groups, even when node identities remain stable.
    var canReuseAfterLeafKindChange: Bool {
        isValueDependent == false && isPermutationSource == false
    }
}

// MARK: - Sorted Candidate Source

/// Adapts a buffered scope cursor whose transformations are already in dispatch priority order.
struct SortedCandidateSource {
    private var cursor: BufferedScopeCursor<GraphTransformation>
    let isValueDependent: Bool
    let isPermutationSource: Bool

    init(_ transformations: [GraphTransformation]) {
        cursor = BufferedScopeCursor(transformations)
        isValueDependent = transformations.contains { $0.operation.isValueDependent }
        isPermutationSource = transformations.contains { transformation in
            guard case .permute = transformation.operation else {
                return false
            }
            return true
        }
    }
}

extension SortedCandidateSource: CandidateSource {
    var peekPriority: DispatchPriority? {
        cursor.peekScope?.priority
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        cursor.next(lastAccepted: lastAccepted)
    }
}

// MARK: - Candidate Source Union

/// Bridges buffered and generated scope cursors to the scheduler without heap-allocated existential boxes.
///
/// Each case implements ``CandidateSource``. The union forwards advancement, feedback, priority inspection, and invalidation metadata while keeping the concrete source state inline in the scheduler's array.
enum AnyCandidateSource {
    case sorted(SortedCandidateSource)
    case batchedCrossSequence(BatchedCrossSequenceRemovalSource)
    case batchRemoval(BatchRemovalSource)
    case replacement(ReplacementCandidateSource)
    case migration(MigrationCandidateSource)
}

extension AnyCandidateSource: CandidateSource {
    var peekPriority: DispatchPriority? {
        switch self {
            case let .sorted(source):
                source.peekPriority
            case let .batchedCrossSequence(source):
                source.peekPriority
            case let .batchRemoval(source):
                source.peekPriority
            case let .replacement(source):
                source.peekPriority
            case let .migration(source):
                source.peekPriority
        }
    }

    /// Whether the source contains operations whose scopes depend on current leaf values.
    var isValueDependent: Bool {
        switch self {
            case let .sorted(source):
                source.isValueDependent
            case let .batchedCrossSequence(source):
                source.isValueDependent
            case let .batchRemoval(source):
                source.isValueDependent
            case let .replacement(source):
                source.isValueDependent
            case let .migration(source):
                source.isValueDependent
        }
    }

    /// Whether the source groups zip children by structural node kind for permutation.
    var isPermutationSource: Bool {
        switch self {
            case let .sorted(source):
                source.isPermutationSource
            case let .batchedCrossSequence(source):
                source.isPermutationSource
            case let .batchRemoval(source):
                source.isPermutationSource
            case let .replacement(source):
                source.isPermutationSource
            case let .migration(source):
                source.isPermutationSource
        }
    }

    mutating func next(lastAccepted: Bool) -> GraphTransformation? {
        switch self {
            case var .sorted(source):
                let result = source.next(lastAccepted: lastAccepted)
                self = .sorted(source)
                return result
            case var .batchedCrossSequence(source):
                self = .sorted(SortedCandidateSource([]))
                let result = source.next(lastAccepted: lastAccepted)
                self = .batchedCrossSequence(source)
                return result
            case var .batchRemoval(source):
                self = .sorted(SortedCandidateSource([]))
                let result = source.next(lastAccepted: lastAccepted)
                self = .batchRemoval(source)
                return result
            case var .replacement(source):
                // Release the enum's ownership before mutating the extracted cursor's heap buffer.
                self = .sorted(SortedCandidateSource([]))
                let result = source.next(lastAccepted: lastAccepted)
                self = .replacement(source)
                return result
            case var .migration(source):
                self = .sorted(SortedCandidateSource([]))
                let result = source.next(lastAccepted: lastAccepted)
                self = .migration(source)
                return result
        }
    }
}

// MARK: - Source Collection Builder

/// Builds the collection of candidate sources from a graph.
enum CandidateSourceBuilder {
    /// Assembles the full candidate source array by combining structural sources (removal, migration, replacement, permutation) with value sources (minimization, exchange). Structural sources are stable across structurally-identical rebuilds; value sources must be rebuilt after any leaf value change.
    static func buildSources(
        from graph: ChoiceGraph,
        deferBindInner: Bool = false,
        previousGraph: ChoiceGraph? = nil
    ) -> [AnyCandidateSource] {
        buildStructuralSources(from: graph, previousGraph: previousGraph)
            + buildValueSources(from: graph, deferBindInner: deferBindInner)
    }

    /// Sources whose scopes depend on graph topology (node parent-child relationships, element counts, self-similarity edges) but not on leaf values. Stable across structurally-identical rebuilds.
    static func buildStructuralSources(
        from graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil
    ) -> [AnyCandidateSource] {
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
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            let source = BatchRemovalSource(
                sequenceNodeID: target.sequenceNodeID,
                graph: graph
            )
            if source.peekPriority != nil {
                sources.append(.batchRemoval(source))
            }
        }

        // Migration.
        let migrationSource = MigrationCandidateSource(graph: graph)
        if migrationSource.peekPriority != nil {
            sources.append(.migration(migrationSource))
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
        let replacementSource = ReplacementQuery.cursor(graph: graph, previousGraph: previousGraph)
        if replacementSource.peekPriority != nil {
            sources.append(.replacement(replacementSource))
        }

        // Permutation.
        sources += buildPermutationSources(from: graph)

        return sources
    }

    /// Builds the structural source whose sibling-shape groups depend on graph node kinds.
    static func buildPermutationSources(from graph: ChoiceGraph) -> [AnyCandidateSource] {
        let permutationCandidates = buildPermutationCandidates(graph: graph)
        guard permutationCandidates.isEmpty == false else {
            return []
        }
        return [.sorted(SortedCandidateSource(permutationCandidates))]
    }

    /// Sources whose scopes depend on leaf values (current ChoiceValue, valid ranges, distance-to-target). Must be rebuilt after any value change, even structurally-identical ones.
    static func buildValueSources(from graph: ChoiceGraph, deferBindInner: Bool = false) -> [AnyCandidateSource] {
        var sources: [AnyCandidateSource] = []

        // Lane collapse.
        let laneCollapseCandidates = buildLaneCollapseCandidates(graph: graph)
        if laneCollapseCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(laneCollapseCandidates)))
        }

        // Depth collapse.
        let depthCollapseCandidates = buildDepthCollapseCandidates(graph: graph)
        if depthCollapseCandidates.isEmpty == false {
            sources.append(.sorted(SortedCandidateSource(depthCollapseCandidates)))
        }

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
