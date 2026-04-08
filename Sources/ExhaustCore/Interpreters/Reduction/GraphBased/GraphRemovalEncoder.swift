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
    private var mutation: ProjectedMutation?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil
        mutation = nil

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch scope.transformation.operation {
        case let .remove(.perParent(perParentScope)):
            candidate = buildPerParentCandidate(
                scope: perParentScope,
                sequence: sequence,
                graph: graph
            )
            if candidate != nil {
                mutation = .sequenceElementsRemoved(
                    seqNodeID: perParentScope.sequenceNodeID,
                    removedNodeIDs: perParentScope.elementNodeIDs
                )
            }

        case let .remove(.aligned(alignedScope)):
            candidate = buildAlignedCandidate(
                scope: alignedScope,
                sequence: sequence,
                graph: graph
            )
            if candidate != nil {
                // Aligned removal touches multiple sequences. Layer 7 will
                // model this with a richer mutation case; for Layer 3 we
                // attribute the mutation to the first participating sibling
                // and rely on the requiresFullRebuild fallback.
                let firstSibling = alignedScope.siblings.first
                mutation = .sequenceElementsRemoved(
                    seqNodeID: firstSibling?.sequenceNodeID ?? -1,
                    removedNodeIDs: alignedScope.siblings.flatMap(\.elementNodeIDs)
                )
            }

        case let .remove(.subtree(subtreeScope)):
            candidate = buildSubtreeCandidate(
                scope: subtreeScope,
                sequence: sequence,
                graph: graph
            )
            if candidate != nil {
                mutation = .sequenceElementsRemoved(
                    seqNodeID: graph.nodes[subtreeScope.nodeID].parent ?? -1,
                    removedNodeIDs: [subtreeScope.nodeID]
                )
            }

        default:
            candidate = nil
            mutation = nil
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard emitted == false else { return nil }
        emitted = true
        guard let candidate, let mutation else { return nil }
        return EncoderProbe(candidate: candidate, mutation: mutation)
    }

    // MARK: - Candidate Construction

    /// Removes the specified elements from the sequence.
    ///
    /// Uses the parent sequence's ``SequenceMetadata/childPositionRanges`` to compute the full extent of each element, including any transparent wrapper markers (getSize-bind, transform-bind). Removing only the inner chooseBits position would leave orphan markers that the materializer cannot decode.
    ///
    /// Skips the scope entirely if any element extent overflows the live sequence — `SequenceMetadata.childPositionRanges` is captured at graph construction time and is not updated by ``ChoiceGraph/propagatePositionShift(after:delta:excluding:)``, so a parent sequence whose children have shifted carries stale extents that will crash ``Array/removeSubranges(_:)``.
    private func buildPerParentCandidate(
        scope: PerParentRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for nodeID in scope.elementNodeIDs {
            guard let extent = elementExtent(
                for: nodeID,
                inSequence: scope.sequenceNodeID,
                graph: graph
            ) else { continue }
            // Defend against stale childPositionRanges. If any extent overflows
            // the live sequence, the parent's metadata is out of date — bail.
            guard extent.upperBound < sequence.count else { return nil }
            rangeSet.insert(contentsOf: extent.lowerBound ..< extent.upperBound + 1)
        }
        guard rangeSet.isEmpty == false else { return nil }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Removes aligned elements across all participating siblings.
    ///
    /// Skips the scope entirely if any element extent overflows the live sequence (see ``buildPerParentCandidate(scope:sequence:graph:)`` for the same drift defence).
    private func buildAlignedCandidate(
        scope: AlignedRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for sibling in scope.siblings {
            for elementNodeID in sibling.elementNodeIDs {
                guard let extent = elementExtent(
                    for: elementNodeID,
                    inSequence: sibling.sequenceNodeID,
                    graph: graph
                ) else { continue }
                guard extent.upperBound < sequence.count else { return nil }
                rangeSet.insert(contentsOf: extent.lowerBound ..< extent.upperBound + 1)
            }
        }
        guard rangeSet.isEmpty == false else { return nil }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Returns the full ``ChoiceSequence`` extent for an element child of a sequence node, including any transparent wrapper markers.
    private func elementExtent(
        for elementNodeID: Int,
        inSequence sequenceNodeID: Int,
        graph: ChoiceGraph
    ) -> ClosedRange<Int>? {
        guard sequenceNodeID < graph.nodes.count else { return nil }
        guard case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind else { return nil }
        guard let childIndex = graph.nodes[sequenceNodeID].children.firstIndex(of: elementNodeID),
              childIndex < metadata.childPositionRanges.count else {
            // Fall back to the chooseBits single position if the parent isn't a
            // sequence with stored extents (defensive — shouldn't normally happen).
            return graph.nodes[elementNodeID].positionRange
        }
        return metadata.childPositionRanges[childIndex]
    }

    /// Removes a structural subtree.
    ///
    /// Skips the scope if the stored extent overflows the live sequence (drift defence; see ``buildPerParentCandidate(scope:sequence:graph:)``).
    private func buildSubtreeCandidate(
        scope: SubtreeRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let range = graph.nodes[scope.nodeID].positionRange else { return nil }
        guard range.upperBound < sequence.count else { return nil }
        var rangeSet = RangeSet<Int>()
        rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
