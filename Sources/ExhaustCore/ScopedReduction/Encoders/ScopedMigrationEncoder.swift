//
//  ScopedMigrationEncoder.swift
//  Exhaust
//

// MARK: - Migration Encoder

/// Moves every element of an earlier sequence to the front of a later compatible one, removing the earlier sequence's markers.
///
/// The scope fully determines the probe, and an accepted migration requires a rebuild, which ends the pass.
struct ScopedMigrationEncoder: ScopedEncoder {
    static let name: EncoderName = .migration
    static let isValueDependent = false
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: MigrationScope, input: ScopedEncoderInput) -> ScopedReducer {
        let search = switch ScopedStructuralCandidates.migration(scope, sequence: input.baseSequence, graph: input.graph) {
            case let .some(candidate):
                ScopedSingleCandidateSearch(
                    candidate: candidate,
                    mutation: .sequenceElementsMigrated(
                        sourceSeqID: scope.sourceSequenceNodeID,
                        receiverSeqID: scope.receiverSequenceNodeID,
                        movedNodeIDs: scope.elementNodeIDs,
                        insertionOffset: scope.receiverPositionRange.lowerBound + 1
                    )
                )
            case .none:
                ScopedSingleCandidateSearch()
        }
        return .search(
            .singleCandidate(search),
            configuration: ScopedSearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
