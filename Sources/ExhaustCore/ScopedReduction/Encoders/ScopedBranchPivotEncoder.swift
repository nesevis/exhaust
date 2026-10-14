//
//  ScopedBranchPivotEncoder.swift
//  Exhaust
//

// MARK: - Branch Pivot Encoder

/// Switches a pick to another branch, with every leaf of the new branch at its reduction target.
///
/// The scope fully determines the probe. A candidate that does not precede the base sequence is not probed and is reported as an unresolved replacement, which a relax round can try without the ordering.
struct ScopedBranchPivotEncoder: ScopedEncoder {
    struct Scope {
        let pickNodeID: Int
        let targetBranchID: UInt64
    }

    static let name: EncoderName = .branchPivot
    static let isValueDependent = false
    static let requiresGenerator = false
    static let isPathChanging = true
    let tuning: ScopedReductionTuning

    func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer {
        let built = ScopedPivotCandidates.branchPivotCandidate(
            pickNodeID: scope.pickNodeID,
            targetBranchID: scope.targetBranchID,
            sequence: input.baseSequence,
            graph: input.graph
        )
        let mutation = EncoderProbe.branchSelected(pickNodeID: scope.pickNodeID, newSelectedID: scope.targetBranchID)
        return .search(
            .singleCandidate(ScopedSingleCandidateSearch.replacement(built, mutation: mutation, base: input.baseSequence)),
            configuration: ScopedSearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
        )
    }
}
