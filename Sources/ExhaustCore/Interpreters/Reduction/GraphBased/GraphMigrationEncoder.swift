//
//  GraphMigrationEncoder.swift
//  Exhaust
//

// MARK: - Graph Migration Encoder

/// Moves elements between antichain-independent sequences to improve shortlex ordering.
///
/// Pure structural encoder: the scope specifies exactly which elements to move from which source sequence to which receiver sequence. The encoder removes the elements from the source's position range and inserts them after the receiver's last element in the flat sequence. One scope = one probe.
struct GraphMigrationEncoder: GraphEncoder {
    let name: EncoderName = .graphDeletion // Reuse deletion name for now

    private var candidate: ChoiceSequence?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil

        guard case let .migrate(migrationScope) = scope.transformation.operation else {
            return
        }

        candidate = buildMigrationCandidate(
            scope: migrationScope,
            sequence: scope.baseSequence,
            graph: scope.graph
        )
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard emitted == false else { return nil }
        emitted = true
        return candidate
    }

    // MARK: - Candidate Construction

    /// Moves elements from the source sequence to the end of the receiver sequence.
    ///
    /// Removes the specified elements from their current positions and inserts them just before the receiver sequence's closing marker.
    private func buildMigrationCandidate(
        scope: MigrationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard scope.elementNodeIDs.isEmpty == false else { return nil }

        // Collect the entries being moved.
        var movedEntries: [ChoiceSequenceValue] = []
        var removalRangeSet = RangeSet<Int>()
        for range in scope.elementPositionRanges {
            for position in range.lowerBound ... range.upperBound {
                movedEntries.append(sequence[position])
            }
            removalRangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        }

        guard movedEntries.isEmpty == false else { return nil }

        // Find the insertion point: just before the receiver sequence's
        // closing marker (the position after the last element).
        let insertionPoint = scope.receiverPositionRange.upperBound

        // Build the candidate: remove from source, insert at receiver.
        var candidate = sequence

        // Insert first (at higher index), then remove (at lower indices),
        // so removal indices aren't shifted by the insertion.
        // But this only works if source positions are all before the insertion point.
        // For safety, do removal first, adjust insertion point, then insert.
        let sourcePositionsBefore = scope.elementPositionRanges.filter {
            $0.lowerBound < insertionPoint
        }
        let adjustedInsertionPoint = insertionPoint - sourcePositionsBefore.reduce(0) {
            $0 + $1.count
        }

        candidate.removeSubranges(removalRangeSet)
        candidate.insert(contentsOf: movedEntries, at: adjustedInsertionPoint)

        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
