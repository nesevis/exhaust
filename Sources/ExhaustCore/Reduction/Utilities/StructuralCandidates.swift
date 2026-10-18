//
//  StructuralCandidates.swift
//  Exhaust
//

// MARK: - Structural Candidates

/// Builds the candidate sequences for structural scopes: removal, migration, and replacement.
///
/// Removal and migration candidates must precede the base sequence, or there is no candidate. Replacement candidates are returned without that check, because a replacement the ordering drops is reported as unresolved rather than discarded silently.
enum StructuralCandidates {
    // MARK: - Removal

    /// Removes the specified elements across one or more parent sequences. Iterates each target, resolves element extents via the parent sequence's stored child position ranges, and removes them atomically.
    static func elementRemoval(
        _ scope: ElementRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        var rangeSet = ExhaustRangeSet<Int>()
        for target in scope.targets {
            for nodeID in target.elementNodeIDs {
                guard let extent = elementExtent(for: nodeID, inSequence: target.sequenceNodeID, graph: graph) else {
                    continue
                }
                rangeSet.insert(contentsOf: extent.lowerBound ..< extent.upperBound + 1)
            }
        }
        guard rangeSet.isEmpty == false else {
            return nil
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else {
            return nil
        }
        return candidate
    }

    // MARK: - Migration

    /// Prepends the earlier source's elements to the receiver so merging preserves their relative order, then removes the source's full extent.
    static func migration(
        _ scope: MigrationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard scope.elementNodeIDs.isEmpty == false else {
            return nil
        }
        guard let sourceFullRange = graph.nodes[scope.sourceSequenceNodeID].positionRange else {
            return nil
        }

        var movedEntries: [ChoiceSequenceValue] = []
        for range in scope.elementPositionRanges {
            for position in range.lowerBound ... range.upperBound {
                movedEntries.append(sequence[position])
            }
        }
        guard movedEntries.isEmpty == false else {
            return nil
        }

        var removalRangeSet = ExhaustRangeSet<Int>()
        removalRangeSet.insert(contentsOf: sourceFullRange.lowerBound ..< sourceFullRange.upperBound + 1)

        let insertionPoint = scope.receiverPositionRange.lowerBound + 1
        let removedBeforeInsertion = sourceFullRange.upperBound < insertionPoint
            ? sourceFullRange.count
            : 0
        let adjustedInsertionPoint = insertionPoint - removedBeforeInsertion

        var candidate = sequence
        candidate.removeSubranges(removalRangeSet)
        candidate.insert(contentsOf: movedEntries, at: adjustedInsertionPoint)

        guard candidate.shortLexPrecedes(sequence) else {
            return nil
        }
        return candidate
    }

    // MARK: - Replacement

    /// Copies donor entries into the target's position range, expanding depth-zero leaf entries to full pick-site equivalents for depth-crossing compatibility. No ordering check.
    static func selfSimilarReplacement(
        targetNodeID: Int,
        donorNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[targetNodeID].positionRange,
              let donorRange = graph.nodes[donorNodeID].positionRange
        else {
            return nil
        }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        let expanded = PivotCandidates.expandDepthZeroLeaves(
            donorEntries,
            donorNodeID: donorNodeID,
            donorRangeStart: donorRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: expanded)
        return candidate
    }

    /// Replaces the ancestor's range with the descendant's content, expanded as for self-similar replacement. No ordering check.
    static func descendantPromotion(
        ancestorPickNodeID: Int,
        descendantPickNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[descendantPickNodeID].positionRange
        else {
            return nil
        }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        let expanded = PivotCandidates.expandDepthZeroLeaves(
            descendantEntries,
            donorNodeID: descendantPickNodeID,
            donorRangeStart: descendantRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: expanded)
        return candidate
    }

    // MARK: - Helpers

    /// Returns the full extent for an element child of a sequence node, including transparent wrapper markers.
    private static func elementExtent(
        for elementNodeID: Int,
        inSequence sequenceNodeID: Int,
        graph: ChoiceGraph
    ) -> ClosedRange<Int>? {
        guard sequenceNodeID < graph.nodes.count else {
            return nil
        }
        guard case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind
        else {
            return nil
        }
        guard let childIndex = metadata.childIndexByNodeID[elementNodeID],
              childIndex < metadata.childPositionRanges.count
        else {
            return graph.nodes[elementNodeID].positionRange
        }
        return metadata.childPositionRanges[childIndex]
    }
}
