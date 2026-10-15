//
//  ScopedBoundExchangeEncoder.swift
//  Exhaust
//

// MARK: - Bound Exchange Encoder

/// Bound exchange: the encoder's reducer proposes a sum-preserving proposal, lifts it, validates the lifted sink, and searches the compound candidate.
///
/// Proposals come from ``BoundExchangeProposalCursor``. Each kept lift is one ``ScopedSingleCandidateSearch`` over the lifted sequence, decoded exactly.
struct ScopedBoundExchangeEncoder: ScopedEncoder {
    static let name: EncoderName = .boundExchange
    static let isValueDependent = true
    static let requiresGenerator = true
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false
    let tuning: ScopedReductionTuning

    func reducer(_ exchange: BoundExchangeScope, input scope: ScopedEncoderInput) -> ScopedReducer {
        guard var cursor = BoundExchangeProposalCursor(graph: scope.graph, baseSequence: scope.baseSequence, exchange: exchange) else {
            return .pure(.finished)
        }
        var buffer = scope.baseSequence
        var branches: [ScopedBranch] = []
        while let proposal = cursor.next(into: &buffer) {
            branches.append(ScopedBranch(proposal: proposal, cost: branches.count))
        }
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: tuning.keptExchangeLiftBudget,
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

    /// Reads the expected sink from the joint proposal, before locating its possibly shifted position in the lifted graph. A kept lift constructs exactly one nonempty search.
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
            .singleCandidate(ScopedSingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation)),
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
