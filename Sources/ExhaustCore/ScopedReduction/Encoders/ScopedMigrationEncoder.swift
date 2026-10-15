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
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false
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
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedMigrationEncoder {
    static func gate(_ _: MigrationScope) -> ScopedDispatchGate {
        .demotedAfterRejects
    }

    static func convergenceInvalidatedByAcceptance(_: MigrationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: MigrationScope, in graph: ChoiceGraph) -> Bool {
        let donorSequenceNodeID = scope.sourceParentSequenceNodeID ?? scope.sourceSequenceNodeID
        guard graph.sequenceCanShrink(donorSequenceNodeID) else {
            return false
        }
        return scope.receiverSequenceNodeID < graph.nodes.count
            && graph.nodes[scope.receiverSequenceNodeID].positionRange != nil
    }

    static func rejectionKey(_ scope: MigrationScope) -> ScopedRejectionKey? {
        ScopedRejectionKey(
            discriminator: 0x6372_8190_A0B0_C0D0,
            isCoarse: true,
            affectedNodeIDs: scope.elementNodeIDs + [scope.receiverSequenceNodeID]
        )
    }
}
