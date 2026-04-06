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

        guard case let .replace(replacementScope) = scope.transformation.operation else {
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

    /// Locates the pick site in the tree by siteID, moves `.selected` to the target branch, and flattens.
    private func buildBranchPivotCandidate(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tree: ChoiceTree
    ) -> ChoiceSequence? {
        // Walk the tree to find the pick site group matching scope.siteID.
        guard let fingerprint = findPickSiteFingerprint(
            in: tree,
            siteID: scope.siteID,
            selectedID: scope.selectedID
        ) else {
            return nil
        }

        guard case let .group(elements, isOpaque) = tree[fingerprint] else {
            return nil
        }
        guard let selectedIndex = elements.firstIndex(where: \.isSelected) else {
            return nil
        }

        // Find the alternative branch matching the target ID.
        guard let targetIndex = elements.firstIndex(where: { element in
            switch element {
            case let .branch(_, _, branchID, _, _):
                branchID == scope.targetBranchID
            default:
                false
            }
        }) else {
            return nil
        }

        // Move .selected: unwrap from current, wrap target.
        var candidateElements = elements
        candidateElements[selectedIndex] = elements[selectedIndex].unwrapped
        candidateElements[targetIndex] = .selected(elements[targetIndex])

        var candidateTree = tree
        candidateTree[fingerprint] = .group(candidateElements, isOpaque: isOpaque)
        let candidateSequence = ChoiceSequence(candidateTree)

        // Accept candidates that are shortlex-equal or better. With
        // branch-transparent shortlex, pivoting between same-arity
        // branches may produce equal sequences — the property check
        // determines whether the alternative is useful.
        guard sequence.shortLexPrecedes(candidateSequence) == false else {
            return nil
        }
        return candidateSequence
    }

    /// Walks the tree depth-first to find the `.group(...)` whose selected branch matches the given siteID and selectedID.
    private func findPickSiteFingerprint(
        in tree: ChoiceTree,
        siteID: UInt64,
        selectedID: UInt64
    ) -> Fingerprint? {
        for element in tree.walk() {
            guard case let .group(array, _) = element.node else { continue }
            for child in array {
                if case let .selected(.branch(childSiteID, _, childID, _, _)) = child,
                   childSiteID == siteID,
                   childID == selectedID
                {
                    return element.fingerprint
                }
            }
        }
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
