//
//  MigrationEncoder.swift
//  Exhaust
//

// MARK: - Migration Encoder

/// Moves every element of an earlier sequence to the front of a later compatible one, removing the earlier sequence's markers.
///
/// The scope fully determines the probe, and an accepted migration requires a rebuild, which ends the pass.
enum MigrationEncoder: ReductionEncoder {
    static let name: EncoderName = .migration
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: MigrationScope, input: EncoderInput) -> Reduction {
        let search = switch StructuralCandidates.migration(scope, sequence: input.baseSequence, graph: input.graph) {
            case let .some(candidate):
                SingleCandidateSearch(
                    candidate: candidate,
                    mutation: .sequenceElementsMigrated(
                        sourceSeqID: scope.sourceSequenceNodeID,
                        receiverSeqID: scope.receiverSequenceNodeID,
                        movedNodeIDs: scope.elementNodeIDs,
                        insertionOffset: scope.receiverPositionRange.lowerBound + 1
                    )
                )
            case .none:
                SingleCandidateSearch()
        }
        return .search(
            search,
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension MigrationEncoder {
    static func gate(_ _: MigrationScope) -> DispatchGate {
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
}
