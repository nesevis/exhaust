//
//  BindPivotEncoder.swift
//  Exhaust
//

// MARK: - Bind Pivot Encoder

/// Switches a pick inside a bind inner to another branch, then searches the bound content the new branch generates.
///
/// Each seed is the plain pivot candidate or a variant that transplants a smaller descendant of the bound subtree into it, up to ``ReductionTuning/maxPivotTransplants``. Changing the pick regenerates the bound subtree, so each seed is lifted through the generator and the bind relocated in the lifted graph before anything is probed. The lifted seed is a ``SingleCandidateSearch``, and the branch continues with a ``CoveringSearch`` over the seed's bound range once the seed is evaluated. Both run in the branch's member, so the pool schedules them as one. Seeds share the pivot choice and differ only in the bound subtree, so branches are not known to emit disjoint candidates and the level delivers uniform feedback.
enum BindPivotEncoder: ReductionEncoder {
    static let name: EncoderName = .bindPivot
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ pivotScope: BindPivotScope, input scope: EncoderInput) -> Reduction {
        let configuration = ChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            deliversUniformFeedback: true
        )
        return .propose(
            { PivotProposals(pivotScope: pivotScope, scope: scope) },
            configuration: configuration,
            then: { proposal in
                .lift(proposal.prefix, fallbackTree: scope.tree) { lifted in
                    guard let lifted else {
                        return .fail(.materializationFailed)
                    }
                    return Self.downstream(proposal: proposal, lifted: lifted, parent: scope, pivotScope: pivotScope)
                }
            }
        )
    }

    /// Rejects lengthening before graph construction, then reconciles the bind, which encloses the pivoted pick and so keeps its node ID. One search emits the lifted seed before covering its bound range.
    private static func downstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: EncoderInput,
        pivotScope: BindPivotScope
    ) -> Reduction {
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
        let configuration = SearchConfiguration(
            acceptance: .continue,
            requiresExactDecoder: false,
            reportedMutation: ReductionComposition.reshaping(proposal.mutation)
        )
        return .search(
            SingleCandidateSearch(candidate: lifted.sequence, mutation: proposal.mutation),
            configuration: configuration
        ) { _ in
            .search(
                CoveringSearch(
                    sequence: lifted.sequence,
                    positionRange: boundRange,
                    tuning: parent.tuning,
                    rowCache: parent.coveringRowCache
                ),
                configuration: configuration
            )
        }
    }

    /// Emits the plain pivot first, discovers donor IDs only when a transplant is reached, and expands only that donor's sequence. All prefixes use the original dispatched snapshot even if another branch accepts a candidate.
    private struct PivotProposals: ProposalCursor {
        let scope: EncoderInput
        let pivotCandidate: ChoiceSequence
        let mutation: ProjectedMutation
        let boundChildID: Int
        let boundRange: ClosedRange<Int>?
        let shiftedBoundRange: ClosedRange<Int>?
        var emittedPivot = false
        var donorIDs: [Int]?
        var donorIndex = 0

        init?(pivotScope: BindPivotScope, scope: EncoderInput) {
            let graph = scope.graph
            guard pivotScope.bindNodeID < graph.nodes.count,
                  case let .bind(bindMetadata) = graph.nodes[pivotScope.bindNodeID].kind,
                  graph.nodes[pivotScope.bindNodeID].children.count > bindMetadata.boundChildIndex,
                  let pickRange = graph.nodes[pivotScope.pickNodeID].positionRange,
                  let pivotCandidate = PivotCandidates.branchPivotCandidate(
                      pickNodeID: pivotScope.pickNodeID,
                      targetBranchID: pivotScope.targetBranchID,
                      sequence: scope.baseSequence,
                      graph: graph
                  )
            else {
                return nil
            }
            self.scope = scope
            self.pivotCandidate = pivotCandidate
            mutation = .branchSelected(pickNodeID: pivotScope.pickNodeID, newSelectedID: pivotScope.targetBranchID)
            boundChildID = graph.nodes[pivotScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundRange = graph.nodes[boundChildID].positionRange
            shiftedBoundRange = boundRange.flatMap { range in
                guard range.lowerBound > pickRange.upperBound else {
                    return nil
                }
                let shift = pivotCandidate.count - scope.baseSequence.count
                return (range.lowerBound + shift) ... (range.upperBound + shift)
            }
        }

        mutating func next(into buffer: inout ChoiceSequence) -> LiftProposal? {
            if emittedPivot == false {
                emittedPivot = true
                buffer = pivotCandidate
                return LiftProposal(prefix: buffer, mutation: mutation)
            }
            guard let boundRange, let shiftedBoundRange else {
                return nil
            }
            if donorIDs == nil {
                donorIDs = MinimizationQuery.transplantDonors(
                    boundChildID: boundChildID,
                    boundRange: boundRange,
                    graph: scope.graph,
                    maxTransplants: scope.tuning.maxPivotTransplants
                )
            }
            guard let donorIDs else {
                return nil
            }
            while donorIndex < donorIDs.count {
                let descendantID = donorIDs[donorIndex]
                donorIndex += 1
                guard let donorRange = scope.graph.nodes[descendantID].positionRange else {
                    continue
                }
                let expanded = PivotCandidates.expandDepthZeroLeaves(
                    Array(scope.baseSequence[donorRange.lowerBound ... donorRange.upperBound]),
                    donorNodeID: descendantID,
                    donorRangeStart: donorRange.lowerBound,
                    graph: scope.graph
                )
                buffer = pivotCandidate
                buffer.replaceSubrange(shiftedBoundRange, with: expanded)
                return LiftProposal(prefix: buffer, mutation: mutation)
            }
            return nil
        }
    }
}

// MARK: - Dispatch Requirements

extension BindPivotEncoder {
    static func gate(_ _: BindPivotScope) -> DispatchGate {
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
}
