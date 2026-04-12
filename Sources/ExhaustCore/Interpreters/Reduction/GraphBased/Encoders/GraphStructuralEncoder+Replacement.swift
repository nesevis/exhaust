//
//  GraphStructuralEncoder+Replacement.swift
//  Exhaust
//

extension GraphStructuralEncoder {
    /// Builds a replacement probe from a self-similar, branch-pivot, or descendant-promotion scope.
    func buildReplacementProbe(
        scope: ReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        switch scope {
        case let .selfSimilar(selfSimilarScope):
            guard let candidate = buildSelfSimilarCandidate(scope: selfSimilarScope, sequence: sequence, graph: graph) else {
                return nil
            }
            return EncoderProbe(
                candidate: candidate,
                mutation: .selfSimilarReplaced(
                    targetNodeID: selfSimilarScope.targetNodeID,
                    donorNodeID: selfSimilarScope.donorNodeID
                )
            )

        case let .branchPivot(pivotScope):
            return buildBranchPivotCandidate(scope: pivotScope, sequence: sequence, graph: graph)

        case let .descendantPromotion(promotionScope):
            guard let candidate = buildDescendantPromotionCandidate(scope: promotionScope, sequence: sequence, graph: graph) else {
                return nil
            }
            return EncoderProbe(
                candidate: candidate,
                mutation: .descendantPromoted(
                    ancestorPickNodeID: promotionScope.ancestorPickNodeID,
                    descendantPickNodeID: promotionScope.descendantPickNodeID
                )
            )
        }
    }

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

    /// Builds a single branch-pivot candidate for the scope's target branch. The leaf-count gate is applied at scope construction time (in ``replacementScopes()``). This method applies speculative leaf minimization and the shortlex gate.
    private func buildBranchPivotCandidate(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        guard scope.pickNodeID < graph.nodes.count else { return nil }
        guard case let .pick(pickMetadata) = graph.nodes[scope.pickNodeID].kind else {
            return nil
        }
        guard let pickRange = graph.nodes[scope.pickNodeID].positionRange else {
            return nil
        }
        let elements = pickMetadata.branchElements
        guard pickMetadata.selectedChildIndex < elements.count else { return nil }

        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
            case let .branch(_, _, candidateID, _, _):
                candidateID == scope.targetBranchID
            default:
                false
            }
        }) else { return nil }

        let minimizedTarget = Self.minimizingLeaves(in: elements[targetElementIndex])
        let targetContent = ChoiceSequence.flatten(.selected(minimizedTarget))

        var replacement: [ChoiceSequenceValue] = []
        replacement.reserveCapacity(targetContent.count + 3)
        replacement.append(.group(true))
        replacement.append(.branch(.init(id: scope.targetBranchID, validIDs: pickMetadata.branchIDs)))
        for index in 0 ..< targetContent.count {
            replacement.append(targetContent[index])
        }
        replacement.append(.group(false))

        var candidate = sequence
        candidate.replaceSubrange(pickRange.lowerBound ... pickRange.upperBound, with: replacement)
        guard candidate.shortLexPrecedes(sequence) else {
            return nil
        }
        return EncoderProbe(
            candidate: candidate,
            mutation: .branchSelected(
                pickNodeID: scope.pickNodeID,
                newSelectedID: scope.targetBranchID
            )
        )
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

    /// Returns a copy of the subtree with every `.choice` node's value replaced by its reduction target. Strips PRNG-like noise so the shortlex comparison reflects only structural difference.
    static func minimizingLeaves(in tree: ChoiceTree) -> ChoiceTree {
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
        case let .branch(fingerprint, weight, id, branchIDs, choice):
            return .branch(
                fingerprint: fingerprint,
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
