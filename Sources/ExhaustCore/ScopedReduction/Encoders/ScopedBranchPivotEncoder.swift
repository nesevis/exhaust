//
//  ScopedBranchPivotEncoder.swift
//  Exhaust
//

// MARK: - Branch Pivot Encoder

/// Switches a pick to another branch, with every leaf of the new branch at its reduction target.
///
/// The scope fully determines the probe. A candidate that does not precede the base sequence is not probed and is reported as an unresolved replacement, which a relax round can try without the ordering.
enum ScopedBranchPivotEncoder: ScopedEncoder {
    struct Scope {
        let pickNodeID: Int
        let targetBranchID: UInt64
    }

    static let name: EncoderName = .branchPivot
    static let isValueDependent = false
    static let isPathChanging = true
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer {
        let built = ScopedPivotCandidates.branchPivotCandidate(
            pickNodeID: scope.pickNodeID,
            targetBranchID: scope.targetBranchID,
            sequence: input.baseSequence,
            graph: input.graph
        )
        let mutation = EncoderProbe.branchSelected(pickNodeID: scope.pickNodeID, newSelectedID: scope.targetBranchID)
        return .search(
            ScopedSingleCandidateSearch.replacement(built, mutation: mutation, base: input.baseSequence),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedBranchPivotEncoder {
    static func gate(_ _: Scope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: Scope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: Scope, in graph: ChoiceGraph) -> Bool {
        scope.pickNodeID < graph.nodes.count
            && graph.nodes[scope.pickNodeID].positionRange != nil
    }

    /// Shares substitution's discriminator, and adds the target branch so that rejecting one branch at a pick does not block another.
    static func rejectionKey(_ scope: Scope) -> ScopedRejectionKey? {
        ScopedRejectionKey(
            discriminator: 0x1827_3645_5463_7281 ^ scope.targetBranchID,
            isCoarse: true,
            affectedNodeIDs: [scope.pickNodeID]
        )
    }
}
