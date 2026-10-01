import ExhaustTestSupport
import Testing
@testable import ExhaustCore

/// Uses the real fixed ladder while allowing fixtures to supply ordinary minimization scopes.
func rejectedLeafProposals(scope: EncoderInput) -> LiftProposalSource? {
    guard let leafNodeID = scope.graph.leafNodes.first,
          case let .chooseBits(metadata) = scope.graph.nodes[leafNodeID].kind
    else {
        return nil
    }
    return LeafProposalCursor(
        scope: scope,
        leafNodeID: leafNodeID,
        candidates: LeafCandidates.rejectedBinarySearch(
            current: metadata.value.bitPattern64,
            target: metadata.value.reductionTarget(in: metadata.validRange)
        )
    ).map(LiftProposalSource.leaf)
}
