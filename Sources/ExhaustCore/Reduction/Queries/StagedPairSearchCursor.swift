/// Tries ratio-preserving tactics in priority order across pairs before the ordinary pair grid, keeping the legacy cursor's ordering available independently for A/B comparisons.
struct StagedPairSearchCursor {
    /// Includes both addresses so equal values in different scopes do not suppress each other's proposals.
    private struct ProposalKey: Hashable {
        let sourcePosition: Int
        let sinkPosition: Int
        let sourcePattern: UInt64
        let sinkPattern: UInt64

        init(_ proposal: NumericPairSearchCursor.Proposal) {
            sourcePosition = proposal.pair.source.position
            sinkPosition = proposal.pair.sink.position
            sourcePattern = proposal.sourceBitPattern
            sinkPattern = proposal.sinkBitPattern
        }
    }

    private var cursor: NumericPairSearchCursor
    private let rescalingProposals: [NumericPairSearchCursor.Proposal]
    private let rescalingKeys: Set<ProposalKey>
    private var rescalingIndex = 0

    /// Interleaves each tactic across scopes so one pair cannot spend the rescaling prefix before another pair reaches its primitive tuple.
    init(pairs: [NumericPairQuery.Pair]) {
        cursor = NumericPairSearchCursor(pairs: pairs)
        var ranked: [(priority: Int, pairIndex: Int, proposal: NumericPairSearchCursor.Proposal)] = []
        for (pairIndex, pair) in pairs.enumerated() {
            for rescaling in NumericCommonDivisorProposal.rescalings(for: [pair.source, pair.sink]) {
                ranked.append((rescaling.priority, pairIndex, .init(pair: pair, sourceBitPattern: rescaling.patterns[0], sinkBitPattern: rescaling.patterns[1])))
            }
        }
        rescalingProposals = ranked.sorted { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.pairIndex < second.pairIndex
        }.map(\.proposal)
        rescalingKeys = Set(rescalingProposals.map(ProposalKey.init))
    }

    /// Skips grid points already emitted by ratio-preserving tactics. Restores the caller's checkpoint between skipped points so mutations from one pair cannot leak into the next pair's probe. Coprime groups use the original cursor directly.
    mutating func next(into candidate: inout ChoiceSequence) -> NumericPairSearchCursor.Proposal? {
        if rescalingIndex < rescalingProposals.count {
            let proposal = rescalingProposals[rescalingIndex]
            rescalingIndex += 1
            candidate[proposal.pair.source.position] = candidate[proposal.pair.source.position].withBitPattern(proposal.sourceBitPattern)
            candidate[proposal.pair.sink.position] = candidate[proposal.pair.sink.position].withBitPattern(proposal.sinkBitPattern)
            return proposal
        }
        guard rescalingKeys.isEmpty == false else { return cursor.next(into: &candidate) }
        let checkpoint = candidate
        while let proposal = cursor.next(into: &candidate) {
            guard rescalingKeys.contains(ProposalKey(proposal)) == false else {
                candidate = checkpoint
                continue
            }
            return proposal
        }
        return nil
    }
}
