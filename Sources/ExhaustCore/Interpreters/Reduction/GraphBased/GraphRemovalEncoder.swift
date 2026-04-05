//
//  GraphRemovalEncoder.swift
//  Exhaust
//

// MARK: - Graph Removal Encoder

/// Applies a fully specified removal to the base sequence.
///
/// Pure structural encoder: the scope specifies exactly which positions to remove. The encoder applies ``ChoiceSequence/removeSubranges(_:)`` and returns one candidate. One scope = one probe. No search logic, no binary search, no head/tail alternation — all of that lives in the ``ScopeSource`` that generated this scope.
struct GraphRemovalEncoder: GraphEncoder {
    let name: EncoderName = .graphDeletion

    private var candidate: ChoiceSequence?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch scope.transformation.operation {
        case let .remove(.perParent(perParentScope)):
            candidate = buildPerParentCandidate(
                scope: perParentScope,
                sequence: sequence,
                graph: graph
            )

        case let .remove(.aligned(alignedScope)):
            candidate = buildAlignedCandidate(
                scope: alignedScope,
                sequence: sequence,
                graph: graph
            )

        case let .remove(.subtree(subtreeScope)):
            candidate = buildSubtreeCandidate(
                scope: subtreeScope,
                sequence: sequence,
                graph: graph
            )

        default:
            candidate = nil
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard emitted == false else { return nil }
        emitted = true
        return candidate
    }

    // MARK: - Candidate Construction

    /// Removes the specified elements from the sequence.
    private func buildPerParentCandidate(
        scope: PerParentRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for nodeID in scope.elementNodeIDs {
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        }
        guard rangeSet.isEmpty == false else { return nil }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Removes aligned elements across all participating siblings.
    private func buildAlignedCandidate(
        scope: AlignedRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for sibling in scope.siblings {
            for elementNodeID in sibling.elementNodeIDs {
                guard let range = graph.nodes[elementNodeID].positionRange else { continue }
                rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
            }
        }
        guard rangeSet.isEmpty == false else { return nil }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Removes a structural subtree.
    private func buildSubtreeCandidate(
        scope: SubtreeRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let range = graph.nodes[scope.nodeID].positionRange else { return nil }
        var rangeSet = RangeSet<Int>()
        rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
