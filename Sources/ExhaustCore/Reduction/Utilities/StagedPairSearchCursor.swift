/// Tries each pair's sign flip and ratio-preserving tactics in priority order across pairs before the ordinary pair grid.
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
    ///
    /// Each of `signFlipPairs` contributes only its sign flip, ranked after the sampled pairs' flips and before any rescaling, and joins neither the rescalings nor the grid.
    init(pairs: [NumericPairQuery.Pair], signFlipPairs: [NumericPairQuery.Pair] = []) {
        cursor = NumericPairSearchCursor(pairs: pairs)
        var ranked: [(priority: Int, pairIndex: Int, proposal: NumericPairSearchCursor.Proposal)] = []
        for (pairIndex, pair) in pairs.enumerated() {
            for rescaling in StagedJointQuery.priorityRescalings(for: [pair.source, pair.sink]) {
                ranked.append((rescaling.priority, pairIndex, .init(pair: pair, sourceBitPattern: rescaling.patterns[0], sinkBitPattern: rescaling.patterns[1])))
            }
        }
        for (offset, pair) in signFlipPairs.enumerated() {
            guard let signFlip = SignFlipQuery.build(leaves: [pair.source, pair.sink]) else {
                continue
            }
            ranked.append((
                SignFlipQuery.priority,
                pairs.count + offset,
                .init(pair: pair, sourceBitPattern: signFlip.patterns[0], sinkBitPattern: signFlip.patterns[1])
            ))
        }
        rescalingProposals = ranked.sorted { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.pairIndex < second.pairIndex
        }.map(\.proposal)

        rescalingKeys = Set(rescalingProposals.map(ProposalKey.init))
    }

    /// Writes only the returned proposal; skipped grid points cannot leak edits into another pair's candidate.
    mutating func next(into candidate: inout ChoiceSequence) -> NumericPairSearchCursor.Proposal? {
        guard let proposal = next() else { return nil }
        proposal.write(into: &candidate)
        return proposal
    }

    /// Skips grid points already emitted by ratio-preserving tactics without touching a candidate buffer.
    mutating func next() -> NumericPairSearchCursor.Proposal? {
        if rescalingIndex < rescalingProposals.count {
            let proposal = rescalingProposals[rescalingIndex]
            rescalingIndex += 1
            return proposal
        }
        guard rescalingKeys.isEmpty == false else { return cursor.next() }
        while let proposal = cursor.next() {
            guard rescalingKeys.contains(ProposalKey(proposal)) == false else { continue }
            return proposal
        }
        return nil
    }
}
