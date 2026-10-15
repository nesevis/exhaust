//
//  ScopedBoundExchangeEncoder.swift
//  Exhaust
//

// MARK: - Bound Exchange Encoder

/// Moves magnitude from a bind inner into a leaf its bind determines, preserving their sum, and keeps a proposal only when the lifted sink still holds its share.
///
/// Lowering the source can regenerate the bound subtree and shift or clamp the sink, so each proposal from ``BoundExchangeProposalCursor`` is lifted through the generator before anything is probed. A lift whose sink no longer holds the proposed value fails its branch. Each kept lift is one ``ScopedSingleCandidateSearch`` over the lifted sequence, decoded exactly. The first acceptance stops the pass, because it makes every other branch's lifted graph stale.
enum ScopedBoundExchangeEncoder: ScopedEncoder {
    static let name: EncoderName = .boundExchange
    static let isValueDependent = true
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ exchange: BoundExchangeScope, input scope: ScopedEncoderInput) -> ScopedReducer {
        guard var cursor = BoundExchangeProposalCursor(graph: scope.graph, baseSequence: scope.baseSequence, exchange: exchange) else {
            return .pure(.finished)
        }
        var buffer = scope.baseSequence
        var branches: [ScopedBranch] = []
        while let proposal = cursor.next(into: &buffer) {
            branches.append(ScopedBranch(proposal: proposal, cost: UInt(branches.count)))
        }
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: scope.tuning.keptExchangeLiftBudget,
            totalProbeCap: 0
        )
        return .propose(branches, configuration: configuration) { proposal in
            .lift(proposal.prefix, fallbackTree: scope.tree) { lifted in
                guard let lifted else {
                    return .fail(.materializationFailed)
                }
                return Self.downstream(proposal: proposal, lifted: lifted, parent: scope, exchange: exchange)
            }
        }
    }

    /// Reads the expected sink value from the joint proposal, before locating the sink's possibly shifted position in the lifted graph. A kept lift constructs exactly one nonempty search.
    private static func downstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: ScopedEncoderInput,
        exchange: BoundExchangeScope
    ) -> ScopedReducer {
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
            ScopedSingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation),
            configuration: ScopedSearchConfiguration(
                acceptance: .stop,
                requiresExactDecoder: true,
                reportedMutation: ScopedComposition.reshaping(proposal.mutation)
            )
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedBoundExchangeEncoder {
    static func gate(_ scope: BoundExchangeScope) -> ScopedDispatchGate {
        .stalledBindInner(leafNodeID: scope.sourceLeafNodeID)
    }

    static func convergenceInvalidatedByAcceptance(_: BoundExchangeScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: BoundExchangeScope, in _: ChoiceGraph) -> Bool {
        true
    }

    /// A search, whose outcome the scope does not determine.
    static func rejectionKey(_: BoundExchangeScope) -> ScopedRejectionKey? {
        nil
    }
}
