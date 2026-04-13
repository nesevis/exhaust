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

    /// Copies donor entries into the target's position range, expanding depth-0 leaf entries to full pick-site equivalents for depth-crossing compatibility.
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
        let expanded = Self.expandDepthZeroLeaves(
            donorEntries,
            donorNodeID: scope.donorNodeID,
            donorRangeStart: donorRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: expanded)
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
        let expanded = Self.expandDepthZeroLeaves(
            descendantEntries,
            donorNodeID: scope.descendantPickNodeID,
            donorRangeStart: descendantRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: expanded)
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

    // MARK: - Depth-Crossing Expansion

    /// Expands depth-0 leaf entries to full pick-site equivalents for depth-crossing promotions.
    ///
    /// When a donor subtree from a shallower recursion depth is copied to a deeper target position, depth-0 leaves (`.just` constants or `.chooseBits` values from the base case) land at positions where the target's materializer expects full `oneOf` pick sites. This method identifies those leaves via the graph, wraps each in the pick-site markers for the matching branch, and returns the expanded entries so the candidate is self-consistent at the target depth.
    static func expandDepthZeroLeaves(
        _ entries: [ChoiceSequenceValue],
        donorNodeID: Int,
        donorRangeStart: Int,
        graph: ChoiceGraph
    ) -> [ChoiceSequenceValue] {
        guard case let .pick(donorMeta) = graph.nodes[donorNodeID].kind else { return entries }

        let leafPositions = depthZeroLeafPositions(
            donorNodeID: donorNodeID,
            fingerprint: donorMeta.fingerprint,
            graph: graph
        )
        guard leafPositions.isEmpty == false else { return entries }

        guard let leafBranchID = findLeafBranchID(in: donorMeta) else { return entries }

        var result: [ChoiceSequenceValue] = []
        result.reserveCapacity(entries.count + leafPositions.count * 3)

        for (index, entry) in entries.enumerated() {
            let absolutePosition = donorRangeStart + index
            if leafPositions.contains(absolutePosition) {
                result.append(.group(true))
                result.append(.branch(.init(
                    id: leafBranchID,
                    validIDs: donorMeta.branchIDs,
                    fingerprint: donorMeta.fingerprint
                )))
                result.append(entry)
                result.append(.group(false))
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Collects absolute start positions of depth-0 base case subtrees in the donor's subtree.
    ///
    /// Two-phase approach: first builds a per-branch recursive-slot mask from non-innermost picks (where the mask is directly observable as pick vs non-pick children), then applies those masks at innermost picks to identify base case positions.
    private static func depthZeroLeafPositions(
        donorNodeID: Int,
        fingerprint: UInt64,
        graph: ChoiceGraph
    ) -> Set<Int> {
        // Phase 1: build per-branch masks from non-innermost picks across the entire self-similarity group (not just the donor's subtree). This ensures innermost donors can still derive masks from deeper picks elsewhere in the tree.
        var branchMasks: [UInt64: Set<Int>] = [:]
        let allGroupPicks = graph.selfSimilarityGroups[fingerprint] ?? []
        for pickID in allGroupPicks {
            guard case let .pick(pickMeta) = graph.nodes[pickID].kind else { continue }
            guard let zipMask = zipMaskForPick(pickID: pickID, fingerprint: fingerprint, graph: graph) else { continue }
            guard zipMask.isEmpty == false else { continue }
            branchMasks[pickMeta.selectedID] = zipMask
        }

        var allPicks: [Int] = []
        collectSelfSimilarPicks(rootID: donorNodeID, fingerprint: fingerprint, graph: graph, into: &allPicks)

        // Phase 2: walk innermost picks in the donor's subtree and record base case positions using the masks.
        var positions = Set<Int>()
        for pickID in allPicks {
            guard case let .pick(pickMeta) = graph.nodes[pickID].kind else { continue }
            guard let zipMask = zipMaskForPick(pickID: pickID, fingerprint: fingerprint, graph: graph) else { continue }
            // Non-innermost: skip (its recursive slots are picks, not base cases).
            guard zipMask.isEmpty else { continue }
            // Innermost: use the precomputed mask for this branch. If no mask is available (the donor has no non-innermost picks to derive one from), expand all children — we cannot distinguish recursive from fixed slots without a deeper reference.
            let mask = branchMasks[pickMeta.selectedID]
            collectBaseCasesFromInnermostPick(
                pickID: pickID,
                fingerprint: fingerprint,
                mask: mask,
                graph: graph,
                positions: &positions
            )
        }
        return positions
    }

    /// Collects all active same-fingerprint pick node IDs in the subtree rooted at ``rootID``.
    private static func collectSelfSimilarPicks(
        rootID: Int,
        fingerprint: UInt64,
        graph: ChoiceGraph,
        into result: inout [Int]
    ) {
        var stack = [rootID]
        while stack.isEmpty == false {
            let nodeID = stack.removeLast()
            let node = graph.nodes[nodeID]
            if case let .pick(metadata) = node.kind,
               metadata.fingerprint == fingerprint,
               node.positionRange != nil
            {
                result.append(nodeID)
            }
            for childID in node.children {
                stack.append(childID)
            }
        }
    }

    /// Returns the set of zip child indices occupied by same-fingerprint picks for a given pick, or nil if no zip is found. An empty set means the pick is innermost (no recursive children).
    private static func zipMaskForPick(
        pickID: Int,
        fingerprint: UInt64,
        graph: ChoiceGraph
    ) -> Set<Int>? {
        // Walk: pick → bind (bound child) → zip.
        var current = pickID
        // Follow the selected branch child, then through binds to the zip.
        var stack = Array(graph.nodes[current].children)
        while stack.isEmpty == false {
            let nodeID = stack.removeLast()
            let node = graph.nodes[nodeID]
            if case let .pick(metadata) = node.kind, metadata.fingerprint == fingerprint {
                continue
            } else if case let .bind(bindMeta) = node.kind {
                if bindMeta.boundChildIndex < node.children.count {
                    stack.append(node.children[bindMeta.boundChildIndex])
                }
            } else if case .zip = node.kind {
                var indices = Set<Int>()
                for (index, childID) in node.children.enumerated() {
                    if case let .pick(childMeta) = graph.nodes[childID].kind, childMeta.fingerprint == fingerprint {
                        indices.insert(index)
                    }
                }
                return indices
            }
        }
        return nil
    }

    /// Records base case positions from an innermost pick using a precomputed mask. When ``mask`` is nil (no non-innermost picks available to derive the mask), all zip children are expanded.
    private static func collectBaseCasesFromInnermostPick(
        pickID: Int,
        fingerprint: UInt64,
        mask: Set<Int>?,
        graph: ChoiceGraph,
        positions: inout Set<Int>
    ) {
        var stack = Array(graph.nodes[pickID].children)
        while stack.isEmpty == false {
            let nodeID = stack.removeLast()
            let node = graph.nodes[nodeID]
            if case let .pick(metadata) = node.kind, metadata.fingerprint == fingerprint {
                continue
            } else if case let .bind(bindMeta) = node.kind {
                if bindMeta.boundChildIndex < node.children.count {
                    stack.append(node.children[bindMeta.boundChildIndex])
                }
            } else if case .zip = node.kind {
                for (index, childID) in node.children.enumerated() {
                    if let mask, mask.contains(index) == false { continue }
                    let child = graph.nodes[childID]
                    let parentIsPick: Bool = if let parentID = child.parent,
                        case let .pick(parentMeta) = graph.nodes[parentID].kind,
                        parentMeta.fingerprint == fingerprint
                    { true } else { false }
                    if parentIsPick == false, let range = child.positionRange {
                        positions.insert(range.lowerBound)
                    }
                }
            }
        }
    }

    /// Finds the branch ID of the first leaf (`.just` or `.choice`) branch in a pick site's elements.
    private static func findLeafBranchID(in metadata: PickMetadata) -> UInt64? {
        for (index, element) in metadata.branchElements.enumerated() {
            guard index < metadata.branchIDs.count else { break }
            let inner = element.isSelected ? element.unwrapped : element
            if case let .branch(_, _, _, _, content) = inner {
                switch content {
                case .just, .choice:
                    return metadata.branchIDs[index]
                default:
                    continue
                }
            }
        }
        return nil
    }
}
