/// Places source and sink changes in the same prefix. Midpoints always receive rejection feedback; only validated lifts construct stages and consume the engine's stage budget.
struct BoundExchangeProposalCursor {
    private var source: LeafProposalCursor
    private let sourceIndex: Int
    private let sinkIndex: Int
    private let currentSource: UInt64
    private let currentSink: UInt64

    init?(scope: EncoderInput, exchange: BoundExchangeScope) {
        let graph = scope.graph
        guard exchange.sourceLeafNodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[exchange.sourceLeafNodeID].kind,
              let sourceRange = graph.nodes[exchange.sourceLeafNodeID].positionRange,
              sourceRange.lowerBound < scope.baseSequence.count,
              let currentSource = scope.baseSequence[sourceRange.lowerBound].value?.choice.bitPattern64,
              let sinkRange = graph.nodes[exchange.sinkLeafNodeID].positionRange,
              sinkRange.lowerBound < scope.baseSequence.count,
              let currentSink = scope.baseSequence[sinkRange.lowerBound].value?.choice.bitPattern64
        else {
            return nil
        }
        let current = metadata.value.bitPattern64
        let target = metadata.value.reductionTarget(in: metadata.validRange)
        guard current != target else {
            return nil
        }
        guard let source = LeafProposalCursor(
            scope: scope,
            leafNodeID: exchange.sourceLeafNodeID,
            candidates: LeafCandidates.rejectedBinarySearch(current: current, target: target),
            mayReshape: true
        ) else {
            return nil
        }
        self.source = source
        sourceIndex = sourceRange.lowerBound
        sinkIndex = sinkRange.lowerBound
        self.currentSource = currentSource
        self.currentSink = currentSink
    }

    mutating func next(into candidate: inout ChoiceSequence) -> LiftProposal? {
        while let proposal = source.next(into: &candidate) {
            guard let proposedSource = candidate[sourceIndex].value?.choice.bitPattern64,
                  proposedSource != currentSource,
                  let raised = raisedSink(for: proposedSource)
            else {
                continue
            }
            candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(raised)
            return LiftProposal(prefix: candidate, mutation: proposal.mutation)
        }
        return nil
    }

    /// Transfers the same bit-pattern delta in the opposite direction, rejecting overflow before spending a lift.
    private func raisedSink(for proposedSource: UInt64) -> UInt64? {
        if proposedSource < currentSource {
            let (raised, overflow) = currentSink.addingReportingOverflow(currentSource - proposedSource)
            guard overflow == false else {
                return nil
            }
            return raised
        }
        let delta = proposedSource - currentSource
        guard currentSink >= delta else {
            return nil
        }
        return currentSink - delta
    }
}
