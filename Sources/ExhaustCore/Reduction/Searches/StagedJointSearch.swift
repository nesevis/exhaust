//
//  StagedJointSearch.swift
//  Exhaust
//

// MARK: - Staged Joint Search

/// Searches one stage of a staged joint checkpoint, pairs or the groups of one higher arity, trying each group's sign flip before its rescalings and samples.
///
/// Stops after the first acceptance, because every group's addresses and domain samples belong to the checkpoint the acceptance replaced. Candidates are lazy, so the interpreter checks their hash against the rejection cache before writing them.
struct StagedJointSearch: ReductionSearch {
    /// Leaves each candidate moves.
    let arity: Int
    // Exactly one cursor is set. Optionals rather than an enum, so each pull advances the cursor in place.
    private var cursor: StagedPairSearchCursor?
    private var jointCursor: NumericJointSearchCursor?
    private let base: ChoiceSequence
    private let probeBudget: Int
    private var emitted = 0

    /// Searches `pairs` and `signFlipProposals`, emitting at most `probeBudget` candidates.
    init(
        pairs: [NumericPair],
        signFlipProposals: [NumericPriorityProposal] = [],
        base: ChoiceSequence,
        probeBudget: Int
    ) {
        arity = 2
        cursor = StagedPairSearchCursor(pairs: pairs, signFlipProposals: signFlipProposals)
        self.base = base
        self.probeBudget = probeBudget
    }

    /// Searches `groups`, which share one arity, emitting at most `probeBudget` candidates.
    init(groups: [NumericJointPlan], base: ChoiceSequence, probeBudget: Int) {
        arity = groups.first?.leaves.count ?? 0
        jointCursor = NumericJointSearchCursor(groups: groups)
        self.base = base
        self.probeBudget = probeBudget
    }

    mutating func next(_ feedback: SearchFeedback, into _: inout ChoiceSequence) -> ReductionCandidate? {
        guard feedback.isAccepted == false, emitted < probeBudget else {
            return nil
        }
        if jointCursor != nil {
            guard let proposal = jointCursor?.next() else {
                return nil
            }
            emitted += 1
            return candidate(
                leaves: proposal.leaves,
                patterns: proposal.patterns,
                admission: .numericJoint(proposal.leaves)
            )
        }
        guard let proposal = cursor?.next() else {
            return nil
        }
        emitted += 1
        return candidate(
            leaves: [proposal.pair.source, proposal.pair.sink],
            patterns: [proposal.sourceBitPattern, proposal.sinkBitPattern],
            admission: .numericPair(proposal.pair)
        )
    }

    /// Converts numeric planning metadata at the emission boundary; sequence patches themselves carry no graph or numeric-search state.
    private func candidate(
        leaves: [ReductionLeaf],
        patterns: [UInt64],
        admission: DecoderAdmission
    ) -> ReductionCandidate {
        precondition(leaves.count == patterns.count)
        var patch = SequencePatch(minimumCapacity: leaves.count)
        var changes: [LeafChange] = []
        changes.reserveCapacity(leaves.count)
        for (leaf, pattern) in zip(leaves, patterns) {
            let replacement = base[leaf.position].withBitPattern(pattern)
            patch.append(.init(position: leaf.position, replacement: replacement))
            guard pattern != leaf.choice.bitPattern64 else {
                continue
            }
            changes.append(LeafChange(
                leafNodeID: leaf.nodeID,
                newValue: ChoiceValue(pattern, tag: leaf.choice.tag),
                mayReshape: leaf.mayReshapeOnAcceptance
            ))
        }
        return .lazy(patch, mutation: .leafValues(changes), admission: admission)
    }

    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        SearchReport(stagedJointArity: arity)
    }
}
