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

/// Pins trace fixtures to known proposals so admission, cache, and interruption checks stay independent of the controller candidate heuristic.
func traceLeafProposals(scope: EncoderInput) -> LiftProposalSource? {
    guard let leafNodeID = scope.graph.leafNodes.first,
          case let .chooseBits(metadata) = scope.graph.nodes[leafNodeID].kind
    else {
        return nil
    }
    let candidates: [UInt64]
    switch metadata.value.bitPattern64 {
        case 1:
            candidates = [2, 0, 3]
        case 2:
            candidates = [3, 1, 0]
        default:
            return nil
    }
    return LeafProposalCursor(
        scope: scope,
        leafNodeID: leafNodeID,
        candidates: candidates
    ).map(LiftProposalSource.leaf)
}

/// Emits domain proposals through the live composition and one-shot stage, using matching lifted trees and sequences.
func traceFixtureEncoder() -> GraphComposedEncoder {
    GraphComposedEncoder(
        name: .composed,
        makeProposals: traceLeafProposals,
        policy: CompositionPolicy(acceptanceHandling: .applyMutation),
        lift: liftLeafProposal,
        downstreamFactory: { proposal, lifted, parent in
            .stage(
                encoder: .init(GraphLiftedStageEncoder(name: .boundExchange, mutation: proposal.mutation)),
                scope: EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: lifted.sequence,
                    tree: lifted.tree,
                    graph: ChoiceGraph.build(from: lifted.tree),
                    warmStartRecords: [:]
                )
            )
        }
    )
}
