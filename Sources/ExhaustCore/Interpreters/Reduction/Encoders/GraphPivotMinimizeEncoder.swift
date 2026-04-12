//
//  GraphPivotMinimizeEncoder.swift
//  Exhaust
//

// MARK: - Pivot-Then-Minimize Encoder

/// Composes a branch pivot with a downstream value search to find failures
/// through a passing intermediate.
///
/// Standard branch pivot (``GraphStructuralEncoder``) speculatively minimizes
/// the target branch's leaves and checks whether the result fails the property.
/// When the minimized pivot *passes* but a non-minimal value assignment under
/// the new structure *fails*, the single-step pivot rejects a viable structural
/// simplification. This encoder addresses that gap:
///
/// 1. For each candidate branch at a pick node, build a pivoted candidate with
///    all leaves set to their reduction target (semantic simplest).
/// 2. Materialize the pivoted candidate through the generator to obtain a valid tree.
/// 3. Run a downstream value search on the materialized tree's leaves to find
///    any value assignment that fails the property.
///
/// This is a hill-climbing move through a passing intermediate — the pivot
/// alone passes, but the downstream value search discovers a failure under
/// the new structure.
struct GraphPivotMinimizeEncoder: GraphEncoder {
    let name: EncoderName = .pivotMinimize

    private var pickNodeID: Int = -1
    private var branches: [UInt64] = []
    private var branchIndex: Int = 0
    private var originalScope: TransformationScope?
    var gen: ReflectiveGenerator<Any>?
    private var downstreamEncoder = GraphFibreCoveringEncoder()
    private var downstreamActive = false
    private var currentPivotCandidate: ChoiceSequence?
    private var currentPivotBranchID: UInt64 = 0
    private var barrenPivots = 0

    /// Maximum consecutive pivots with zero downstream accepts before bailing.
    private static let barrenPivotLimit = 2

    init() {}

    mutating func start(scope: TransformationScope) {
        pickNodeID = -1
        branches = []
        branchIndex = 0
        originalScope = scope
        downstreamActive = false
        currentPivotCandidate = nil
        barrenPivots = 0

        guard case let .minimize(.pivotThenMinimize(pivotScope)) = scope.transformation.operation
        else { return }

        let graph = scope.graph
        guard pivotScope.pickNodeID < graph.nodes.count,
              case let .pick(pickMetadata) = graph.nodes[pivotScope.pickNodeID].kind
        else { return }

        pickNodeID = pivotScope.pickNodeID

        // Collect branches that are not the currently selected one.
        branches = pickMetadata.branchIDs.filter { $0 != pickMetadata.selectedID }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        // Drain active downstream first.
        if downstreamActive {
            if let probe = downstreamEncoder.nextProbe(lastAccepted: lastAccepted) {
                return wrapDownstream(probe)
            }
            downstreamActive = false
            if lastAccepted {
                barrenPivots = 0
            } else {
                barrenPivots += 1
            }
        }

        guard barrenPivots < Self.barrenPivotLimit else { return nil }
        guard let scope = originalScope else { return nil }
        let graph = scope.graph

        // Try next branch.
        while branchIndex < branches.count {
            let targetBranchID = branches[branchIndex]
            branchIndex += 1

            // Build pivoted candidate using the existing structural encoder logic.
            guard let pivotedCandidate = buildPivotedCandidate(
                pickNodeID: pickNodeID,
                targetBranchID: targetBranchID,
                sequence: scope.baseSequence,
                graph: graph
            ) else { continue }

            // Materialize through the generator to get a valid tree.
            guard let gen = self.gen else { continue }
            guard case let .success(_, freshTree, _) = Materializer.materializeAny(
                gen,
                prefix: pivotedCandidate,
                mode: .guided(seed: 0, fallbackTree: scope.tree),
                fallbackTree: scope.tree,
                materializePicks: true
            ) else { continue }

            // Build a downstream value search scope on the materialized tree.
            let liftedGraph = ChoiceGraph.build(from: freshTree)
            let liftedSequence = ChoiceSequence(freshTree)

            let downstreamLeaves = liftedGraph.leafNodes.compactMap { nodeID -> LeafEntry? in
                guard case let .chooseBits(metadata) = liftedGraph.nodes[nodeID].kind,
                      liftedGraph.nodes[nodeID].positionRange != nil
                else { return nil }
                let currentBP = metadata.value.bitPattern64
                let targetBP = metadata.value.reductionTarget(in: metadata.validRange)
                guard currentBP != targetBP else { return nil }
                return LeafEntry(nodeID: nodeID, mayReshapeOnAcceptance: false)
            }
            guard downstreamLeaves.isEmpty == false else {
                // All leaves already at target — try this candidate directly.
                // This IS the minimized pivot that the structural encoder already tried.
                // Skip to next branch.
                continue
            }

            let downstreamScope = TransformationScope(
                transformation: GraphTransformation(
                    operation: .minimize(.valueLeaves(ValueMinimizationScope(
                        leaves: downstreamLeaves,
                        batchZeroEligible: downstreamLeaves.count > 1
                    ))),
                    yield: scope.transformation.yield,
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ),
                baseSequence: liftedSequence,
                tree: freshTree,
                graph: liftedGraph,
                warmStartRecords: [:]
            )

            downstreamEncoder.start(scope: downstreamScope)
            downstreamActive = true
            currentPivotCandidate = pivotedCandidate
            currentPivotBranchID = targetBranchID

            if let firstProbe = downstreamEncoder.nextProbe(lastAccepted: false) {
                return wrapDownstream(firstProbe)
            }
            downstreamActive = false
            barrenPivots += 1
            if barrenPivots >= Self.barrenPivotLimit { return nil }
        }

        return nil
    }

    /// The downstream encoder operates on the lifted tree. The candidate
    /// sequence is what the scheduler materializes; the mutation reports a
    /// structural branch selection so the graph rebuilds on acceptance.
    private func wrapDownstream(_ probe: EncoderProbe) -> EncoderProbe {
        EncoderProbe(
            candidate: probe.candidate,
            mutation: .branchSelected(
                pickNodeID: pickNodeID,
                newSelectedID: currentPivotBranchID
            )
        )
    }

    // MARK: - Pivot Candidate Construction

    /// Builds a pivoted choice sequence with all target branch leaves set to
    /// their reduction target (semantic simplest).
    private func buildPivotedCandidate(
        pickNodeID: Int,
        targetBranchID: UInt64,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard case let .pick(pickMetadata) = graph.nodes[pickNodeID].kind else { return nil }
        guard let pickRange = graph.nodes[pickNodeID].positionRange else { return nil }
        let elements = pickMetadata.branchElements
        guard pickMetadata.selectedChildIndex < elements.count else { return nil }

        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
            case let .branch(_, _, candidateID, _, _):
                candidateID == targetBranchID
            default:
                false
            }
        }) else { return nil }

        // Do NOT minimize leaves — keep them as-is from the stored branch
        // elements so the downstream value search has room to explore.
        let targetContent = ChoiceSequence.flatten(.selected(elements[targetElementIndex]))

        var replacement: [ChoiceSequenceValue] = []
        replacement.reserveCapacity(targetContent.count + 3)
        replacement.append(.group(true))
        replacement.append(.branch(.init(id: targetBranchID, validIDs: pickMetadata.branchIDs)))
        for index in 0 ..< targetContent.count {
            replacement.append(targetContent[index])
        }
        replacement.append(.group(false))

        var candidate = sequence
        candidate.replaceSubrange(pickRange.lowerBound ... pickRange.upperBound, with: replacement)
        return candidate
    }
}
