//
//  GraphStructuralEncoder+Migration.swift
//  Exhaust
//

extension GraphStructuralEncoder {
    /// Builds a migration probe that moves elements from a source sequence to a receiver sequence.
    func buildMigrationProbe(
        into candidate: inout ChoiceSequence,
        scope: MigrationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ProjectedMutation? {
        guard let built = buildMigrationCandidate(scope: scope, sequence: sequence, graph: graph) else {
            return nil
        }
        candidate = built
        return .sequenceElementsMigrated(
            sourceSeqID: scope.sourceSequenceNodeID,
            receiverSeqID: scope.receiverSequenceNodeID,
            movedNodeIDs: scope.elementNodeIDs,
            insertionOffset: scope.receiverPositionRange.upperBound
        )
    }

    /// Moves all elements from the source sequence into the receiver and removes the now-empty source's full extent.
    private func buildMigrationCandidate(
        scope: MigrationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard scope.elementNodeIDs.isEmpty == false else { return nil }
        guard let sourceFullRange = graph.nodes[scope.sourceSequenceNodeID].positionRange else {
            return nil
        }

        var movedEntries: [ChoiceSequenceValue] = []
        for range in scope.elementPositionRanges {
            for position in range.lowerBound ... range.upperBound {
                movedEntries.append(sequence[position])
            }
        }
        guard movedEntries.isEmpty == false else { return nil }

        var removalExhaustRangeSet = ExhaustRangeSet<Int>()
        removalExhaustRangeSet.insert(contentsOf: sourceFullRange.lowerBound ..< sourceFullRange.upperBound + 1)

        let insertionPoint = scope.receiverPositionRange.upperBound
        let removedBeforeInsertion = sourceFullRange.upperBound < insertionPoint
            ? sourceFullRange.count
            : 0
        let adjustedInsertionPoint = insertionPoint - removedBeforeInsertion

        var candidate = sequence
        candidate.removeSubranges(removalExhaustRangeSet)
        candidate.insert(contentsOf: movedEntries, at: adjustedInsertionPoint)

        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
