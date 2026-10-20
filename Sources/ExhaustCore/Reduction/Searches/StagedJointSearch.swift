//
//  StagedJointSearch.swift
//  Exhaust
//

// MARK: - Staged Joint Search

/// Searches one stage of a staged joint checkpoint, pairs or the groups of one higher arity, trying each group's sign flip before its rescalings and samples.
///
/// Stops after the first acceptance, because every group's addresses and domain samples belong to the checkpoint the acceptance replaced. Candidates are sparse, so the interpreter checks their hash against the rejection cache before writing them.
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
        pairs: [NumericPairQuery.Pair],
        signFlipProposals: [StagedJointQuery.PriorityProposal] = [],
        base: ChoiceSequence,
        probeBudget: Int
    ) {
        arity = 2
        cursor = StagedPairSearchCursor(pairs: pairs, signFlipProposals: signFlipProposals)
        self.base = base
        self.probeBudget = probeBudget
    }

    /// Searches `groups`, which share one arity, emitting at most `probeBudget` candidates.
    init(groups: [NumericJointQuery.Group], base: ChoiceSequence, probeBudget: Int) {
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
            return .sparse(
                SparseEncoderProbe(leaves: proposal.leaves, patterns: proposal.patterns),
                baseSequence: base,
                admission: .numericJoint(proposal.leaves)
            )
        }
        guard let proposal = cursor?.next() else {
            return nil
        }
        emitted += 1
        return .sparse(
            SparseEncoderProbe(
                leaves: [proposal.pair.source, proposal.pair.sink],
                patterns: [proposal.sourceBitPattern, proposal.sinkBitPattern]
            ),
            baseSequence: base,
            admission: .numericPair(proposal.pair)
        )
    }

    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        SearchReport(stagedJointArity: arity)
    }
}
