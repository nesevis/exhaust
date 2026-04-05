//
//  GraphReplacementEncoder.swift
//  Exhaust
//

// MARK: - Graph Replacement Encoder

/// Applies a fully specified replacement to the base sequence.
///
/// Pure structural encoder: the scope specifies the exact donor and target. For active donors (non-nil position range), the encoder copies entries via sequence surgery. For inactive donors (nil position range), the encoder edits the tree and flattens. One scope = one probe.
struct GraphReplacementEncoder: GraphEncoder {
    let name: EncoderName = .graphSubstitution

    private var candidate: ChoiceSequence?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil

        guard case let .replacement(replacementScope) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch replacementScope {
        case let .selfSimilar(selfSimilarScope):
            candidate = buildSelfSimilarCandidate(
                scope: selfSimilarScope,
                sequence: sequence,
                graph: graph
            )

        case let .branchPivot(pivotScope):
            candidate = buildBranchPivotCandidate(
                scope: pivotScope,
                sequence: sequence,
                graph: graph,
                tree: scope.tree
            )

        case let .descendantPromotion(promotionScope):
            candidate = buildDescendantPromotionCandidate(
                scope: promotionScope,
                sequence: sequence,
                graph: graph
            )
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard emitted == false else { return nil }
        emitted = true
        return candidate
    }

    // MARK: - Candidate Construction

    /// Copies donor entries into the target's position range.
    private func buildSelfSimilarCandidate(
        scope: SelfSimilarReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[scope.targetNodeID].positionRange,
              let donorRange = graph.nodes[scope.donorNodeID].positionRange else {
            return nil
        }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: donorEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Edits the tree to pivot to an alternative branch and flattens.
    private func buildBranchPivotCandidate(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tree: ChoiceTree
    ) -> ChoiceSequence? {
        // Branch pivot requires tree editing — the alternative branches are inactive (nil position range). Stub: returns nil until tree-level pivot manipulation is implemented.
        _ = scope
        _ = graph
        _ = tree
        return nil
    }

    /// Replaces the ancestor's range with the descendant's content.
    private func buildDescendantPromotionCandidate(
        scope: DescendantPromotionScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[scope.ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[scope.descendantPickNodeID].positionRange else {
            return nil
        }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: descendantEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
