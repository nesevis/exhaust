//
//  GraphReplacementEncoder.swift
//  Exhaust
//

// MARK: - Graph Replacement Encoder

/// Applies a structural replacement to the base sequence. All three modes (self-similar substitution, branch pivot, descendant promotion) are single-shot: the encoder builds one candidate at ``start(scope:)`` and emits it from the next ``nextProbe(lastAccepted:)`` call. Branch pivot scopes carry a single target branch — the source iterates over alternative branches, not the encoder.
struct GraphReplacementEncoder: GraphEncoder {
    let name: EncoderName = .graphSubstitution

    private var probe: EncoderProbe?

    mutating func start(scope: TransformationScope) {
        probe = nil

        guard case let .replace(replacementScope) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch replacementScope {
        case let .selfSimilar(selfSimilarScope):
            let candidate = buildSelfSimilarCandidate(
                scope: selfSimilarScope,
                sequence: sequence,
                graph: graph
            )
            probe = candidate.map {
                EncoderProbe(
                    candidate: $0,
                    mutation: .selfSimilarReplaced(
                        targetNodeID: selfSimilarScope.targetNodeID,
                        donorNodeID: selfSimilarScope.donorNodeID
                    )
                )
            }

        case let .branchPivot(pivotScope):
            probe = buildBranchPivotCandidate(
                scope: pivotScope,
                sequence: sequence,
                tree: scope.tree,
                graph: scope.graph
            )

        case let .descendantPromotion(promotionScope):
            let candidate = buildDescendantPromotionCandidate(
                scope: promotionScope,
                sequence: sequence,
                graph: graph
            )
            probe = candidate.map {
                EncoderProbe(
                    candidate: $0,
                    mutation: .descendantPromoted(
                        ancestorPickNodeID: promotionScope.ancestorPickNodeID,
                        descendantPickNodeID: promotionScope.descendantPickNodeID
                    )
                )
            }
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        defer { probe = nil }
        return probe
    }

    // MARK: - Candidate Construction

    /// Copies donor entries into the target's position range.
    private func buildSelfSimilarCandidate(
        scope: SelfSimilarReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[scope.targetNodeID].positionRange,
              let donorRange = graph.nodes[scope.donorNodeID].positionRange
        else {
            return nil
        }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: donorEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Builds a single branch-pivot candidate for the scope's target branch. The leaf-count gate is applied at scope construction time (in ``replacementScopes()``), so this method only applies speculative leaf minimization and the shortlex gate.
    ///
    /// Returns `nil` when the pick node cannot be found, the metadata is malformed, the pick site cannot be located in the tree, the target branch is not in `branchElements`, or the candidate does not strictly shortlex-precede the current sequence.
    private func buildBranchPivotCandidate(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        guard scope.pickNodeID < graph.nodes.count else { return nil }
        guard case let .pick(pickMetadata) = graph.nodes[scope.pickNodeID].kind else {
            return nil
        }
        let elements = pickMetadata.branchElements
        let selectedIndex = pickMetadata.selectedChildIndex
        guard selectedIndex < elements.count else { return nil }

        // Find the target branch in branchElements.
        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
            case let .branch(_, _, candidateID, _, _):
                candidateID == scope.targetBranchID
            default:
                false
            }
        }) else { return nil }

        // Locate the splice point in the live tree.
        guard let fingerprint = findPickSiteFingerprint(
            in: tree,
            siteID: scope.siteID,
            selectedID: scope.selectedID
        ) else {
            return nil
        }
        guard case let .group(_, isOpaque) = tree[fingerprint] else {
            return nil
        }

        // Speculative leaf minimization: rewrite every `.choice` to its reduction target so the shortlex comparison reflects only structural difference.
        let minimizedTarget = Self.minimizingLeaves(in: elements[targetElementIndex])

        // Splice: unwrap the current selection, wrap the minimized target.
        var candidateElements = elements
        candidateElements[selectedIndex] = elements[selectedIndex].unwrapped
        candidateElements[targetElementIndex] = .selected(minimizedTarget)

        var candidateTree = tree
        candidateTree[fingerprint] = .group(candidateElements, isOpaque: isOpaque)
        let candidateSequence = ChoiceSequence(candidateTree)

        // Strictly-better shortlex gate. Equal-shortlex would cause infinite rebuild cycles.
        guard candidateSequence.shortLexPrecedes(sequence) else {
            return nil
        }
        return EncoderProbe(
            candidate: candidateSequence,
            mutation: .branchSelected(
                pickNodeID: scope.pickNodeID,
                newSelectedID: scope.targetBranchID
            )
        )
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
              let descendantRange = graph.nodes[scope.descendantPickNodeID].positionRange
        else {
            return nil
        }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: descendantEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    // MARK: - Branch Pivot Helpers

    /// Returns a copy of the subtree with every `.choice` node's value replaced by its ``ChoiceValue/reductionTarget(in:)``. Strips PRNG-like noise from a candidate branch's pre-materialized subtree before flattening, so the shortlex comparison reflects only the structural difference between the current branch and the candidate.
    private static func minimizingLeaves(in tree: ChoiceTree) -> ChoiceTree {
        switch tree {
        case let .choice(value, metadata):
            let targetBP = value.reductionTarget(in: metadata.validRange)
            let targetValue = ChoiceValue(
                value.tag.makeConvertible(bitPattern64: targetBP),
                tag: value.tag
            )
            return .choice(targetValue, metadata)
        case .just:
            return tree
        case .getSize:
            return tree
        case let .sequence(length, elements, metadata):
            return .sequence(
                length: length,
                elements: elements.map { minimizingLeaves(in: $0) },
                metadata
            )
        case let .branch(siteID, weight, id, branchIDs, choice):
            return .branch(
                siteID: siteID,
                weight: weight,
                id: id,
                branchIDs: branchIDs,
                choice: minimizingLeaves(in: choice)
            )
        case let .group(children, isOpaque):
            return .group(
                children.map { minimizingLeaves(in: $0) },
                isOpaque: isOpaque
            )
        case let .resize(newSize, choices):
            return .resize(
                newSize: newSize,
                choices: choices.map { minimizingLeaves(in: $0) }
            )
        case let .bind(inner, bound):
            return .bind(
                inner: minimizingLeaves(in: inner),
                bound: minimizingLeaves(in: bound)
            )
        case let .selected(inner):
            return .selected(minimizingLeaves(in: inner))
        }
    }
}
