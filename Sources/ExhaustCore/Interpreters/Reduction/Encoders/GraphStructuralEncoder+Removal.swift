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

        case .coveringAligned:
            // Covering aligned removal is handled by the multi-shot path
            // in ``GraphStructuralEncoder/nextCoveringAlignedProbe()``.
            return nil
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
        guard case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind
        else {
            return nil
        }
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

    // MARK: - Covering Aligned Removal

    /// Pulls the next row from the covering array generator and decodes it into a deletion probe.
    ///
    /// Each row is an array of `UInt64` values, one per sibling parameter. A value equal to the sibling's skip value (= element count) means "do not delete from this sibling." Any other value is an element index within that sibling's `elementNodeIDs`. Rows where fewer than two siblings participate are skipped — single-sequence deletion is already covered by ``PerElementRemovalSource``.
    mutating func nextCoveringAlignedProbe() -> EncoderProbe? {
        guard let state = coveringAlignedState else { return nil }

        while let row = state.scope.handle.generator.next() {
            // Decode the row into deletion targets.
            var targets: [SequenceRemovalTarget] = []
            var removedPairs: [(seqNodeID: Int, removedNodeIDs: [Int])] = []

            for (siblingIndex, value) in row.values.enumerated() {
                guard siblingIndex < state.scope.siblings.count else { continue }
                // Skip value = don't delete from this sibling.
                if value == state.scope.skipValues[siblingIndex] { continue }
                let elementIndex = Int(value)
                let sibling = state.scope.siblings[siblingIndex]
                guard elementIndex < sibling.elementNodeIDs.count else { continue }
                let nodeID = sibling.elementNodeIDs[elementIndex]
                targets.append(SequenceRemovalTarget(
                    sequenceNodeID: sibling.sequenceNodeID,
                    elementNodeIDs: [nodeID]
                ))
                removedPairs.append((
                    seqNodeID: sibling.sequenceNodeID,
                    removedNodeIDs: [nodeID]
                ))
            }

            // Require at least two siblings participating.
            guard targets.count >= 2 else { continue }

            let elementScope = ElementRemovalScope(
                targets: targets,
                maxBatch: 1,
                maxElementYield: state.scope.maxElementYield
            )

            guard let candidate = buildElementCandidate(
                scope: elementScope,
                sequence: state.baseSequence,
                graph: state.graph
            ) else {
                continue
            }

            return EncoderProbe(
                candidate: candidate,
                mutation: .sequenceElementsRemoved(removedPairs)
            )
        }

        // Generator exhausted.
        coveringAlignedState = nil
        return nil
    }
}
