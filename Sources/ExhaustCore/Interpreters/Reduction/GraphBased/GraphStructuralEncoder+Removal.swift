//
//  GraphStructuralEncoder+Removal.swift
//  Exhaust
//

extension GraphStructuralEncoder {
    /// Builds a removal probe from an element or subtree removal scope.
    func buildRemovalProbe(
        scope: RemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        switch scope {
        case let .elements(elementScope):
            guard let candidate = buildElementCandidate(scope: elementScope, sequence: sequence, graph: graph) else {
                return nil
            }
            return EncoderProbe(
                candidate: candidate,
                mutation: .sequenceElementsRemoved(
                    elementScope.targets.map { target in
                        (seqNodeID: target.sequenceNodeID, removedNodeIDs: target.elementNodeIDs)
                    }
                )
            )

        case let .subtree(subtreeScope):
            guard let candidate = buildSubtreeCandidate(scope: subtreeScope, sequence: sequence, graph: graph) else {
                return nil
            }
            return EncoderProbe(
                candidate: candidate,
                mutation: .sequenceElementsRemoved(
                    [(seqNodeID: graph.nodes[subtreeScope.nodeID].parent ?? -1, removedNodeIDs: [subtreeScope.nodeID])]
                )
            )
        }
    }

    /// Removes the specified elements across one or more parent sequences. Iterates each target, resolves element extents via the parent sequence's stored child position ranges, and removes them atomically.
    private func buildElementCandidate(
        scope: ElementRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for target in scope.targets {
            for nodeID in target.elementNodeIDs {
                guard let extent = elementExtent(for: nodeID, inSequence: target.sequenceNodeID, graph: graph) else {
                    continue
                }
                rangeSet.insert(contentsOf: extent.lowerBound ..< extent.upperBound + 1)
            }
        }
        guard rangeSet.isEmpty == false else { return nil }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Returns the full extent for an element child of a sequence node, including transparent wrapper markers.
    private func elementExtent(
        for elementNodeID: Int,
        inSequence sequenceNodeID: Int,
        graph: ChoiceGraph
    ) -> ClosedRange<Int>? {
        guard sequenceNodeID < graph.nodes.count else { return nil }
        guard case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind else { return nil }
        guard let childIndex = graph.nodes[sequenceNodeID].children.firstIndex(of: elementNodeID),
              childIndex < metadata.childPositionRanges.count
        else {
            return graph.nodes[elementNodeID].positionRange
        }
        return metadata.childPositionRanges[childIndex]
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
