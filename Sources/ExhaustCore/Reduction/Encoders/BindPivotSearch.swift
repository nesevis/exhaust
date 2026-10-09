//
//  BindPivotSearch.swift
//  Exhaust
//

/// Pivots a pick inside a bind's inner subtree, regenerates the bound subtree, and enumerates the regenerated subtree's leaves for a failing assignment.
///
/// A plain branch pivot on such a pick decodes the bound subtree in guided mode, which keeps every previous leaf value the new ranges still admit. That is the wrong assignment whenever the failure depends on a value the previous inner had pinned: a leaf whose range was a singleton under the old inner keeps its old value under the new one, although the widened range is exactly where the failing value lies. Bound value search would find it, but its upstream is a numeric search over a `chooseBits` leaf and a pick-shaped inner is unclassifiable to it. This encoder is the structural counterpart: one lift per seed, then the same covering enumeration over the bound subtree that the bound value composition runs downstream.
///
/// ## Probe sequence
///
/// 1. ``GraphComposedEncoder/start(scope:)`` builds the pivot candidate as ``GraphStructuralEncoder`` does, with the target branch's leaves at their reduction targets. When the bound subtree is a pick, one further seed per same-fingerprint descendant of that pick puts the descendant's span in the bound subtree's place: the new inner may make the bound subtree's current shape invalid while a subtree below it is exactly what the site now wants, which a guided lift alone would replace with fallback content rather than promote.
/// 2. Each seed is lifted through the generator. The lift is a full guided materialization, so the bound subtree comes out regenerated for the new inner wherever the seed does not already fit it.
/// 3. The lifted sequence must not be longer than the base sequence. A pivot that lengthens the sequence cannot be admitted, and the covering search would only be rearranging values inside a candidate that is already lost.
/// 4. The lifted sequence itself is the seed's first probe: a bound subtree without ranged leaves has nothing to enumerate, and a transplant is a candidate in its own right. ``BoundValueCoveringEncoder`` is then started on the lifted sequence over the bound subtree's position range, with its three regimes: exhaustive for small domains, pairwise for several large ones, and the range ends for a single large one. The bound value composition uses binary search for a single leaf instead, because there the lifted state is assumed to fail already and the search minimizes; here the lifted state is assumed to pass and the search has to discover a failure, which is what the range-end regime is for. Seeds are consumed in order as each covering runs dry.
/// 5. Every probe carries the pivot as its mutation, so acceptance rebuilds the graph from the fresh tree. The regenerated bound subtree is in the candidate sequence; the mutation only has to name the pick.
///
/// The scheduler supplies the lift at dispatch time; this factory owns seed construction and lifted-bound validation.
///
/// Probes go through the guided decoder, not the exact one, although every candidate is a complete lifted sequence. Guided resolution takes each coordinate from the prefix first and consults the fallback tree only where the prefix does not fit, and a complete lifted sequence fits everywhere, so the pre-pivot tree is never read. Exact decoding was measured to reject a share of lifted candidates that guided decoding accepts as genuine failures, so forcing exact decoding would lose reductions. Acceptance rebuilds the graph and ends the session, so no state survives an accepted probe and nothing needs refreshing.
enum BindPivotSearch {
    /// Descendant transplants tried per scope beyond the plain pivot, smallest first. Each costs one lift materialization before any probe is emitted.
    static let maxTransplants = 4

    /// Keeps guided decoder selection and mutation application in the same policy the dispatch reads. A lifted seed and its covering search form one downstream stage.
    static func makeEncoder(lift: @escaping GraphComposedEncoder.Lift) -> GraphComposedEncoder {
        GraphComposedEncoder(
            name: .bindPivot,
            makeProposals: makeProposals,
            policy: CompositionPolicy(
                stageBudget: nil,
                requiresExactDecoder: false,
                acceptanceHandling: .applyMutation,
                liftSite: .bindPivotLift,
                reportsConstructedStages: false
            ),
            lift: lift
        )
    }

    /// Builds the plain pivot before its same-family transplants. Only the seed list is finite; no counted limit is introduced.
    private static func makeProposals(scope: EncoderInput) -> GraphComposedEncoder.PreparedSearch? {
        guard case let .minimize(.bindPivot(pivotScope)) = scope.transformation.operation else {
            return nil
        }
        let graph = scope.graph
        guard pivotScope.bindNodeID < graph.nodes.count,
              case let .bind(bindMetadata) = graph.nodes[pivotScope.bindNodeID].kind,
              graph.nodes[pivotScope.bindNodeID].children.count > bindMetadata.boundChildIndex,
              let pickRange = graph.nodes[pivotScope.pickNodeID].positionRange,
              let pivotCandidate = GraphStructuralEncoder.branchPivotCandidate(
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
            for descendantID in Self.transplantDonors(boundChildID: boundChildID, boundRange: boundRange, graph: graph) {
                guard let donorRange = graph.nodes[descendantID].positionRange else {
                    continue
                }
                let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
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
        return (
            source: .seeds(SeedProposalCursor(seeds: seeds, mutation: mutation)),
            downstreamFactory: { proposal, lifted, parent in
                buildDownstream(
                    proposal: proposal,
                    lifted: lifted,
                    parent: parent,
                    bindNodeID: pivotScope.bindNodeID
                )
            }
        )
    }

    /// Rejects lengthening before graph construction, then locates the bind by its stable pre-pivot node ID. One stage emits the lifted seed before covering its bound range.
    private static func buildDownstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: EncoderInput,
        bindNodeID: Int
    ) -> DownstreamBuild {
        guard lifted.sequence.count <= parent.baseSequence.count else {
            return .failed(.liftedTooLong)
        }
        // The pivot is inside the bind, so nothing preceding the bind can change its build-order node ID.
        let graph = ChoiceGraph.build(from: lifted.tree)
        guard bindNodeID < graph.nodes.count,
              case let .bind(metadata) = graph.nodes[bindNodeID].kind,
              graph.nodes[bindNodeID].children.count > metadata.boundChildIndex,
              let boundRange = graph.nodes[graph.nodes[bindNodeID].children[metadata.boundChildIndex]].positionRange
        else {
            return .failed(.bindNotFound)
        }
        return .stage(
            encoder: .init(GraphLiftedStageEncoder(
                name: .bindPivot,
                mutation: proposal.mutation,
                boundRange: boundRange
            )),
            scope: EncoderInput(
                transformation: parent.transformation,
                baseSequence: lifted.sequence,
                tree: lifted.tree,
                graph: graph,
                warmStartRecords: [:]
            )
        )
    }

    /// Active picks below `boundChildID` sharing its fingerprint, smallest span first, at most ``maxTransplants``. Empty when the bound subtree is not a pick: only a pick's span can stand in for another pick of the same family. ``MinimizationQuery`` calls this too, to size a scope's probe estimate by the seeds the encoder will lift.
    static func transplantDonors(
        boundChildID: Int,
        boundRange: ClosedRange<Int>,
        graph: ChoiceGraph
    ) -> [Int] {
        guard case let .pick(metadata) = graph.nodes[boundChildID].kind,
              let group = graph.selfSimilarityGroups[metadata.fingerprint]
        else {
            return []
        }
        let donors = group.filter { candidateID in
            guard candidateID != boundChildID,
                  let range = graph.nodes[candidateID].positionRange
            else {
                return false
            }
            return range.lowerBound > boundRange.lowerBound && range.upperBound <= boundRange.upperBound
        }
        let sorted = donors.sorted { lhs, rhs in
            (graph.nodes[lhs].positionRange?.count ?? 0) < (graph.nodes[rhs].positionRange?.count ?? 0)
        }
        return Array(sorted.prefix(maxTransplants))
    }
}
