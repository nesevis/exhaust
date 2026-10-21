//
//  BoundExchangeEncoder.swift
//  Exhaust
//

// MARK: - Bound Exchange Encoder

/// Moves magnitude from a bind inner into a leaf its bind determines, preserving their sum, and keeps a proposal only when the lifted sink still holds its share.
///
/// Lowering the source can regenerate the bound subtree and shift or clamp the sink, so each proposal from ``BoundExchangeProposalCursor`` is lifted through the generator before anything is probed. A lift whose sink no longer holds the proposed value fails its branch. Each kept lift is one ``SingleCandidateSearch`` over the lifted sequence, decoded exactly. The first acceptance stops the pass, because it makes every other branch's lifted graph stale.
enum BoundExchangeEncoder: ReductionEncoder {
    static let name: EncoderName = .boundExchange
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ exchange: BoundExchangeScope, input scope: EncoderInput) -> Reduction {
        let configuration = ChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: scope.tuning.keptExchangeLiftBudget,
            totalProbeCap: 0
        )
        return .propose(
            { BoundExchangeProposalCursor(graph: scope.graph, baseSequence: scope.baseSequence, exchange: exchange) },
            configuration: configuration,
            then: { proposal in
                .lift(proposal, fallbackTree: scope.tree) { lifted in
                    guard let lifted else {
                        return .fail(.materializationFailed)
                    }
                    return Self.downstream(proposal: proposal, lifted: lifted, parent: scope, exchange: exchange)
                }
            }
        )
    }

    /// Reads the expected sink value from the joint proposal, before locating the sink's possibly shifted position in the lifted graph. A kept lift constructs exactly one nonempty search.
    private static func downstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: EncoderInput,
        exchange: BoundExchangeScope
    ) -> Reduction {
        guard let parentSinkIndex = parent.graph.nodes[exchange.sinkLeafNodeID].positionRange?.lowerBound,
              parentSinkIndex < proposal.prefix.count
        else {
            return .fail(.bindNotFound)
        }
        guard let expected = proposal.prefix[parentSinkIndex].value?.choice.bitPattern64 else {
            return .fail(.sinkValueMismatch)
        }
        let graph = ChoiceGraph.build(from: lifted.tree)
        guard let liftedSinkID = parent.graph.reconciling(exchange.sinkLeafNodeID, in: graph, changedAt: exchange.sourceLeafNodeID),
              let sinkIndex = graph.nodes[liftedSinkID].positionRange?.lowerBound,
              sinkIndex < lifted.sequence.count
        else {
            return .fail(.bindNotFound)
        }
        guard lifted.sequence[sinkIndex].value?.choice.bitPattern64 == expected else {
            return .fail(.sinkValueMismatch)
        }
        return .search(
            SingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation),
            configuration: SearchConfiguration(requiresExactDecoder: true)
        )
    }
}

// MARK: - Dispatch Requirements

extension BoundExchangeEncoder {
    static func gate(_ scope: BoundExchangeScope) -> DispatchGate {
        .stalledBindInner(leafNodeID: scope.sourceLeafNodeID)
    }

    static func convergenceInvalidatedByAcceptance(_: BoundExchangeScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: BoundExchangeScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
