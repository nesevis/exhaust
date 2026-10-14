//
//  ScopedBindPivotEncoder.swift
//  Exhaust
//

// MARK: - Bind Pivot Encoder

/// Bind pivot: the encoder's reducer proposes a pivot seed, lifts it, relocates the bind, and searches the lifted seed followed by covering over its bound subtree.
///
/// The lifted seed is a ``ScopedSingleCandidateSearch``, and the branch continues with a ``ScopedCoveringSearch`` over the seed's bound range once the seed is evaluated. Both run in the branch's member, so the pool schedules them as one. Seeds share the pivot choice and differ only in the bound subtree, so branches are not known to emit disjoint candidates and the level delivers uniform feedback.
struct ScopedBindPivotEncoder: ScopedEncoder {
    static let name: EncoderName = .bindPivot
    static let isValueDependent = true
    static let requiresGenerator = true
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ pivotScope: BindPivotScope, input scope: ScopedEncoderInput) -> ScopedReducer {
        guard let pivot = Self.pivotSeeds(pivotScope: pivotScope, scope: scope, maxTransplants: tuning.maxPivotTransplants) else {
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
                return Self.downstream(proposal: proposal, lifted: lifted, parent: scope, pivotScope: pivotScope, tuning: tuning)
            }
        }
    }

    /// Rejects lengthening before graph construction, then reconciles the bind, which encloses the pivoted pick and so keeps its node ID. One search emits the lifted seed before covering its bound range.
    private static func downstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: ScopedEncoderInput,
        pivotScope: BindPivotScope,
        tuning: ScopedReductionTuning
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
            .singleCandidate(ScopedSingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation)),
            configuration: configuration
        ) { _ in
            .search(
                .covering(ScopedCoveringSearch(sequence: lifted.sequence, positionRange: boundRange, tuning: tuning)),
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
