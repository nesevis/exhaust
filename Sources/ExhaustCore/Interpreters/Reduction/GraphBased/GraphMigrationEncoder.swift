//
//  GraphMigrationEncoder.swift
//  Exhaust
//

// MARK: - Graph Migration Encoder

/// Moves elements between antichain-independent sequences to improve shortlex ordering.
///
/// Pure structural encoder: the scope specifies exactly which elements to move from which source sequence to which receiver sequence. The encoder removes the elements from the source's position range and inserts them after the receiver's last element in the flat sequence. One scope = one probe.
struct GraphMigrationEncoder: GraphEncoder {
    let name: EncoderName = .graphMigration

    private var candidate: ChoiceSequence?
    private var mutation: ProjectedMutation?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil
        mutation = nil

        guard case let .migrate(migrationScope) = scope.transformation.operation else {
            return
        }

        candidate = buildMigrationCandidate(
            scope: migrationScope,
            sequence: scope.baseSequence,
            graph: scope.graph
        )
        if candidate != nil {
            mutation = .sequenceElementsMigrated(
                sourceSeqID: migrationScope.sourceSequenceNodeID,
                receiverSeqID: migrationScope.receiverSequenceNodeID,
                movedNodeIDs: migrationScope.elementNodeIDs,
                insertionOffset: migrationScope.receiverPositionRange.upperBound
            )
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard emitted == false else { return nil }
        emitted = true
        guard let candidate, let mutation else { return nil }
        return EncoderProbe(candidate: candidate, mutation: mutation)
    }

    // MARK: - Candidate Construction

    /// Moves all elements from the source sequence into the receiver sequence and removes the now-empty source sequence's full extent.
    ///
    /// The source's children migrate with their wrapper markers, and the source's full extent (including its own structural markers) is removed entirely. Without removing the source wrappers, the candidate would not shortlex-precede the original — empty wrapper markers compare larger than the wrapped content they replace.
    private func buildMigrationCandidate(
        scope: MigrationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard scope.elementNodeIDs.isEmpty == false else { return nil }
        guard let sourceFullRange = graph.nodes[scope.sourceSequenceNodeID].positionRange else {
            return nil
        }

        // Collect the entries being moved.
        var movedEntries: [ChoiceSequenceValue] = []
        for range in scope.elementPositionRanges {
            for position in range.lowerBound ... range.upperBound {
                movedEntries.append(sequence[position])
            }
        }
        guard movedEntries.isEmpty == false else { return nil }

        // Remove the source sequence's FULL extent (including its wrappers),
        // since after moving all children out the source is just empty markers.
        var removalRangeSet = RangeSet<Int>()
        removalRangeSet.insert(contentsOf: sourceFullRange.lowerBound ..< sourceFullRange.upperBound + 1)

        // Adjust insertion point for the removal of the source's full extent.
        let insertionPoint = scope.receiverPositionRange.upperBound
        let removedBeforeInsertion = sourceFullRange.upperBound < insertionPoint
            ? sourceFullRange.count
            : 0
        let adjustedInsertionPoint = insertionPoint - removedBeforeInsertion

        var candidate = sequence
        candidate.removeSubranges(removalRangeSet)
        candidate.insert(contentsOf: movedEntries, at: adjustedInsertionPoint)

        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
