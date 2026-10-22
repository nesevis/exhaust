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
    /// Each of `signFlipProposals` belongs to a pair searched only by that flip: it ranks after the sampled pairs' proposals of the same priority, and its pair joins neither the rescalings nor the grid.
    init(pairs: [NumericPair], signFlipProposals: [NumericPriorityProposal] = []) {
        cursor = NumericPairSearchCursor(pairs: pairs)
        var ranked: [(priority: Int, pairIndex: Int, proposal: NumericPairSearchCursor.Proposal)] = []
        for (pairIndex, pair) in pairs.enumerated() {
            for priorityProposal in NumericPriorityProposal.build(for: [pair.source, pair.sink]) {
                ranked.append((priorityProposal.priority, pairIndex, Self.pairProposal(priorityProposal)))
            }
        }
        for (offset, signFlip) in signFlipProposals.enumerated() {
            ranked.append((signFlip.priority, pairs.count + offset, Self.pairProposal(signFlip)))
        }
        rescalingProposals = ranked.sorted { first, second in
            if first.priority != second.priority {
                return first.priority < second.priority
            }
            return first.pairIndex < second.pairIndex
        }.map(\.proposal)

        rescalingKeys = Set(rescalingProposals.map(ProposalKey.init))
    }

    /// Writes only the returned proposal; skipped grid points cannot leak edits into another pair's candidate.
    mutating func next(into candidate: inout ChoiceSequence) -> NumericPairSearchCursor.Proposal? {
        guard let proposal = next() else {
            return nil
        }
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
        guard rescalingKeys.isEmpty == false else {
            return cursor.next()
        }
        while let proposal = cursor.next() {
            guard rescalingKeys.contains(ProposalKey(proposal)) == false else {
                continue
            }
            return proposal
        }
        return nil
    }

    /// Reads a two-leaf probe as a pair proposal, whose first leaf is the source.
    private static func pairProposal(_ probe: NumericPriorityProposal) -> NumericPairSearchCursor.Proposal {
        NumericPairSearchCursor.Proposal(
            pair: NumericPair(source: probe.leaves[0], sink: probe.leaves[1]),
            sourceBitPattern: probe.patterns[0],
            sinkBitPattern: probe.patterns[1]
        )
    }
}
