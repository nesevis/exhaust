//
//  GraphReplacementEncoder.swift
//  Exhaust
//

// MARK: - Graph Replacement Encoder

/// Replaces one subtree with another along structural edges.
///
/// Operates in three modes based on the ``ReplacementScope``:
/// - **Self-similar**: splices donor content along a self-similarity edge via sequence surgery (when the donor is active) or tree edit + flatten (when inactive).
/// - **Branch pivot**: changes the selected branch at a pick node. Always requires tree edit + flatten because the alternative branch is inactive.
/// - **Descendant promotion**: collapses one recursion level by promoting a descendant pick node.
///
/// This is the only path-changing operation type — it may bring inactive content (nil position range) into the active sequence.
struct GraphReplacementEncoder: GraphEncoder {
    let name: EncoderName = .graphSubstitution

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        candidateIndex = 0
        candidates = []

        guard case let .replacement(replacementScope) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch replacementScope {
        case let .selfSimilar(selfSimilarScope):
            buildSelfSimilarCandidates(
                scope: selfSimilarScope,
                sequence: sequence,
                graph: graph
            )

        case let .branchPivot(pivotScope):
            buildBranchPivotCandidates(
                scope: pivotScope,
                sequence: sequence,
                graph: graph,
                tree: scope.tree
            )

        case let .descendantPromotion(promotionScope):
            buildDescendantPromotionCandidates(
                scope: promotionScope,
                sequence: sequence,
                graph: graph,
                tree: scope.tree
            )
        }
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Self-Similar Substitution

    private mutating func buildSelfSimilarCandidates(
        scope: SelfSimilarReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        guard let targetRange = graph.nodes[scope.targetNodeID].positionRange,
              let donorRange = graph.nodes[scope.donorNodeID].positionRange else {
            return
        }

        // Sequence surgery: copy donor entries and replace target range.
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: donorEntries)
        if candidate.shortLexPrecedes(sequence) {
            candidates.append(candidate)
        }
    }

    // MARK: - Branch Pivot

    private mutating func buildBranchPivotCandidates(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tree: ChoiceTree
    ) {
        // Branch pivot requires tree editing — the alternative branches are inactive
        // (nil position range). Walk the tree, find the pick site, swap .selected
        // marker, and flatten.
        for branchID in scope.candidateBranchIDs {
            var editedTree = tree
            if editedTree.pivotBranch(at: scope.pickNodeID, to: branchID, graph: graph) {
                let candidateSequence = ChoiceSequence.flatten(editedTree)
                if candidateSequence.shortLexPrecedes(sequence) {
                    candidates.append(candidateSequence)
                }
            }
        }
    }

    // MARK: - Descendant Promotion

    private mutating func buildDescendantPromotionCandidates(
        scope: DescendantPromotionScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tree: ChoiceTree
    ) {
        guard let ancestorRange = graph.nodes[scope.ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[scope.descendantPickNodeID].positionRange else {
            return
        }

        // Sequence surgery: replace ancestor's range with descendant's content.
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: descendantEntries)
        if candidate.shortLexPrecedes(sequence) {
            candidates.append(candidate)
        }
    }
}

// MARK: - Tree Pivot Extension

extension ChoiceTree {
    /// Pivots a branch at a pick node identified by graph node ID.
    ///
    /// - Note: Stub — requires tree walk to find the pick site by matching the graph node's site ID and depth, then swapping the `.selected` marker. Returns false if the pick site cannot be found.
    mutating func pivotBranch(at pickNodeID: Int, to branchID: UInt64, graph: ChoiceGraph) -> Bool {
        // TODO: Implement tree-level branch pivot by matching pick site metadata.
        // For now, return false (no candidates generated from pivots).
        _ = pickNodeID
        _ = branchID
        _ = graph
        return false
    }
}
