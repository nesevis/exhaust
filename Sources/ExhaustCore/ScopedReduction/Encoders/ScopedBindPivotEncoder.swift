//
//  ScopedBindPivotEncoder.swift
//  Exhaust
//

// MARK: - Bind Pivot Encoder

/// Bind pivot: the encoder's reducer proposes a pivot seed, lifts it, relocates the bind, and searches the lifted seed followed by covering over its bound subtree.
///
/// The lifted seed is a ``ScopedSingleCandidateSearch``, and the branch continues with a ``ScopedCoveringSearch`` over the seed's bound range once the seed is evaluated. Both run in the branch's member, so the pool schedules them as one. Seeds share the pivot choice and differ only in the bound subtree, so branches are not known to emit disjoint candidates and the level delivers uniform feedback.
enum ScopedBindPivotEncoder: ScopedEncoder {
    static let name: EncoderName = .bindPivot
    static let isValueDependent = true
    static let requiresGenerator = true
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ pivotScope: BindPivotScope, input scope: ScopedEncoderInput) -> ScopedReducer {
        guard let pivot = pivotSeeds(pivotScope: pivotScope, scope: scope, maxTransplants: scope.tuning.maxPivotTransplants) else {
            return .pure(.finished)
        }
        let branches = pivot.seeds.enumerated().map { index, seed in
            ScopedBranch(proposal: LiftProposal(prefix: seed, mutation: pivot.mutation), cost: index)
        }
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            deliversUniformFeedback: true
        )
        return .propose(branches, configuration: configuration) { proposal in
            .lift(proposal.prefix, fallbackTree: scope.tree) { lifted in
                guard let lifted else {
                    return .fail(.materializationFailed)
                }
                return Self.downstream(proposal: proposal, lifted: lifted, parent: scope, pivotScope: pivotScope)
            }
        }
    }

    /// Rejects lengthening before graph construction, then reconciles the bind, which encloses the pivoted pick and so keeps its node ID. One search emits the lifted seed before covering its bound range.
    private static func downstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: ScopedEncoderInput,
        pivotScope: BindPivotScope
    ) -> ScopedReducer {
        guard lifted.sequence.count <= parent.baseSequence.count else {
            return .fail(.liftedTooLong)
        }
        let graph = ChoiceGraph.build(from: lifted.tree)
        guard let bindNodeID = parent.graph.reconciling(pivotScope.bindNodeID, in: graph, changedAt: pivotScope.pickNodeID),
              case let .bind(metadata) = graph.nodes[bindNodeID].kind,
              graph.nodes[bindNodeID].children.count > metadata.boundChildIndex,
              let boundRange = graph.nodes[graph.nodes[bindNodeID].children[metadata.boundChildIndex]].positionRange
        else {
            return .fail(.bindNotFound)
        }
        let configuration = ScopedSearchConfiguration(
            acceptance: .continue,
            requiresExactDecoder: false,
            reportedMutation: ScopedComposition.reshaping(proposal.mutation)
        )
        return .search(
            ScopedSingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation),
            configuration: configuration
        ) { _ in
            .search(
                ScopedCoveringSearch(sequence: lifted.sequence, positionRange: boundRange, tuning: parent.tuning),
                configuration: configuration
            )
        }
    }

    /// The plain pivot candidate followed by its same-family transplants, with the mutation every seed reports. Nil when the pivot candidate cannot be built.
    private static func pivotSeeds(
        pivotScope: BindPivotScope,
        scope: ScopedEncoderInput,
        maxTransplants: Int
    ) -> (seeds: [ChoiceSequence], mutation: ProjectedMutation)? {
        let graph = scope.graph
        guard pivotScope.bindNodeID < graph.nodes.count,
              case let .bind(bindMetadata) = graph.nodes[pivotScope.bindNodeID].kind,
              graph.nodes[pivotScope.bindNodeID].children.count > bindMetadata.boundChildIndex,
              let pickRange = graph.nodes[pivotScope.pickNodeID].positionRange,
              let pivotCandidate = ScopedPivotCandidates.branchPivotCandidate(
                  pickNodeID: pivotScope.pickNodeID,
                  targetBranchID: pivotScope.targetBranchID,
                  sequence: scope.baseSequence,
                  graph: graph
              )
        else {
            return nil
        }

        let mutation = ProjectedMutation.branchSelected(
            pickNodeID: pivotScope.pickNodeID,
            newSelectedID: pivotScope.targetBranchID
        )
        var seeds = [pivotCandidate]

        let boundChildID = graph.nodes[pivotScope.bindNodeID].children[bindMetadata.boundChildIndex]
        if let boundRange = graph.nodes[boundChildID].positionRange, boundRange.lowerBound > pickRange.upperBound {
            let shift = pivotCandidate.count - scope.baseSequence.count
            let shiftedBoundRange = (boundRange.lowerBound + shift) ... (boundRange.upperBound + shift)
            for descendantID in MinimizationQuery.transplantDonors(boundChildID: boundChildID, boundRange: boundRange, graph: graph, maxTransplants: maxTransplants) {
                guard let donorRange = graph.nodes[descendantID].positionRange else {
                    continue
                }
                let expanded = ScopedPivotCandidates.expandDepthZeroLeaves(
                    Array(scope.baseSequence[donorRange.lowerBound ... donorRange.upperBound]),
                    donorNodeID: descendantID,
                    donorRangeStart: donorRange.lowerBound,
                    graph: graph
                )
                var seed = pivotCandidate
                seed.replaceSubrange(shiftedBoundRange, with: expanded)
                seeds.append(seed)
            }
        }
        return (seeds: seeds, mutation: mutation)
    }
}

// MARK: - Dispatch Requirements

extension ScopedBindPivotEncoder {
    static func gate(_ _: BindPivotScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: BindPivotScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_ scope: BindPivotScope, in graph: ChoiceGraph) -> Bool {
        scope.bindNodeID < graph.nodes.count
            && graph.nodes[scope.bindNodeID].positionRange != nil
            && scope.pickNodeID < graph.nodes.count
            && graph.nodes[scope.pickNodeID].positionRange != nil
    }

    /// The candidate is a function of the bind's current entries, and the bind's range covers the pick, so the bind alone is the affected set; reporting the pick as well would cancel its positions out of the hash. The pick's node ID joins the target branch in the discriminator, because one bind inner can hold several picks with the same branch identifiers.
    static func rejectionKey(_ scope: BindPivotScope) -> ScopedRejectionKey? {
        ScopedRejectionKey(
            discriminator: 0x4B1D_9140_7A5E_0002 ^ (scope.targetBranchID ^ (UInt64(scope.pickNodeID) &* 0x9E37_79B9_7F4A_7C15)),
            isCoarse: false,
            affectedNodeIDs: [scope.bindNodeID]
        )
    }
}
