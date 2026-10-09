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

/// Keeps lifted-operation trace fixtures on the same domain proposal order.
func domainLeafProposals(scope: EncoderInput) -> LiftProposalSource? {
    guard let leafNodeID = scope.graph.leafNodes.first,
          case let .chooseBits(metadata) = scope.graph.nodes[leafNodeID].kind
    else {
        return nil
    }
    return LeafProposalCursor(
        scope: scope,
        leafNodeID: leafNodeID,
        candidates: LeafCandidates.candidates(
            in: metadata.validRange ?? metadata.typeTag.bitPatternRange,
            current: metadata.value.bitPattern64,
            target: metadata.value.reductionTarget(in: metadata.validRange),
            includesCurrent: false
        )
    ).map(LiftProposalSource.leaf)
}

/// Emits domain proposals through the live composition and one-shot stage, using matching lifted trees and sequences.
func domainFixtureEncoder() -> GraphComposedEncoder {
    GraphComposedEncoder(
        name: .composed,
        makeProposals: domainLeafProposals,
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
