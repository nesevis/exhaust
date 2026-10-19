//
//  StagedJointSearch.swift
//  Exhaust
//

// MARK: - Staged Joint Search

/// Flips the signs of each selected group first, then samples one stage of a staged joint checkpoint: pairs, or groups of one higher arity.
///
/// Stops after the first acceptance, because every group's addresses and domain samples belong to the checkpoint the acceptance replaced. Candidates are sparse, so the interpreter checks their hash against the rejection cache before writing them.
struct StagedJointSearch: ReductionSearch {
    /// Leaves each candidate moves.
    let arity: Int
    // Exactly one cursor is set. Optionals rather than an enum, so each pull advances the cursor in place.
    private var cursor: StagedPairSearchCursor?
    private var jointCursor: NumericJointSearchCursor?
    private let signFlips: [SparseEncoderProbe]
    private let signFlippedPatterns: [[Int]: [UInt64]]
    private var signFlipIndex = 0
    private let base: ChoiceSequence
    private let probeBudget: Int
    private var emitted = 0

    /// Searches `pairs`, emitting at most `probeBudget` candidates.
    init(pairs: [NumericPairQuery.Pair], base: ChoiceSequence, probeBudget: Int) {
        self.init(arity: 2, leafGroups: pairs.map { [$0.source, $0.sink] }, base: base, probeBudget: probeBudget)
        cursor = StagedPairSearchCursor(pairs: pairs)
    }

    /// Searches `groups`, which share one arity, emitting at most `probeBudget` candidates.
    init(groups: [NumericJointQuery.Group], base: ChoiceSequence, probeBudget: Int) {
        self.init(arity: groups.first?.leaves.count ?? 0, leafGroups: groups.map(\.leaves), base: base, probeBudget: probeBudget)
        jointCursor = NumericJointSearchCursor(groups: groups)
    }

    private init(arity: Int, leafGroups: [[ReductionLeaf]], base: ChoiceSequence, probeBudget: Int) {
        self.arity = arity
        signFlips = leafGroups.compactMap { SignFlipQuery.build(leaves: $0) }
        signFlippedPatterns = Dictionary(signFlips.map { ($0.leaves.map(\.position), $0.patterns) }, uniquingKeysWith: { first, _ in first })
        self.base = base
        self.probeBudget = probeBudget
    }

    mutating func next(_ feedback: SearchFeedback, into _: inout ChoiceSequence) -> ReductionCandidate? {
        guard feedback.isAccepted == false, emitted < probeBudget else {
            return nil
        }
        if signFlipIndex < signFlips.count {
            let signFlip = signFlips[signFlipIndex]
            signFlipIndex += 1
            emitted += 1
            return .sparse(signFlip, baseSequence: base, admission: .numericJoint(signFlip.leaves))
        }
        if jointCursor != nil {
            while let proposal = jointCursor?.next() {
                guard signFlippedPatterns[proposal.leaves.map(\.position)] != proposal.patterns else {
                    continue
                }
                emitted += 1
                return .sparse(
                    SparseEncoderProbe(leaves: proposal.leaves, patterns: proposal.patterns),
                    baseSequence: base,
                    admission: .numericJoint(proposal.leaves)
                )
            }
            return nil
        }
        while let proposal = cursor?.next() {
            let leaves = [proposal.pair.source, proposal.pair.sink]
            let patterns = [proposal.sourceBitPattern, proposal.sinkBitPattern]
            guard signFlippedPatterns[leaves.map(\.position)] != patterns else {
                continue
            }
            emitted += 1
            return .sparse(
                SparseEncoderProbe(leaves: leaves, patterns: patterns),
                baseSequence: base,
                admission: .numericPair(proposal.pair)
            )
        }
        return nil
    }

    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        SearchReport(stagedJointArity: arity)
    }
}
