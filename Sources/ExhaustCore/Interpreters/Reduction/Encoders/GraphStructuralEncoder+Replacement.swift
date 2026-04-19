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
            let targetBitPattern = value.reductionTarget(in: metadata.validRange)
            let targetValue = ChoiceValue(
                value.tag.makeConvertible(bitPattern64: targetBitPattern),
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
        case let .bind(fingerprint, inner, bound):
            return .bind(
                fingerprint: fingerprint,
                inner: minimizingLeaves(in: inner),
                bound: minimizingLeaves(in: bound)
            )
        case let .selected(inner):
            return .selected(minimizingLeaves(in: inner))
        }
    }

    // MARK: - Depth-Crossing Expansion

    /// Wrapping kind for a depth-0 base case entry during cross-depth expansion.
    private enum LeafWrapping {
        /// Direct recursion (like BinaryHeap): wrap in pick-site markers.
        case pick(branchID: UInt64, validIDs: [UInt64], fingerprint: UInt64)
        /// `Gen.recursive` recursion: wrap in `._bound` bind markers with depth selector = 0.
        case bind(depthSelectorEntry: ChoiceSequenceValue)
    }

    /// Expands depth-0 leaf entries for depth-crossing promotions.
    ///
    /// Two wrapping modes depending on the recursion pattern:
    /// - **Pick wrapping** (direct recursion like BinaryHeap): the base case is inside a `oneOf`. Wrap in `group(true), branch(leafID), entry, group(false)`.
    /// - **Bind wrapping** (`Gen.recursive`): the base case is inside a `._bound`. Wrap in `bind(true), value(0), entry, bind(false)`, selecting `layers[0]` = the base generator.
    static func expandDepthZeroLeaves(
        _ entries: [ChoiceSequenceValue],
        donorNodeID: Int,
        donorRangeStart: Int,
        graph: ChoiceGraph
    ) -> [ChoiceSequenceValue] {
        guard case let .pick(donorMeta) = graph.nodes[donorNodeID].kind else { return entries }

        let leafExpansions = depthZeroLeafExpansions(
            donorNodeID: donorNodeID,
            donorRangeStart: donorRangeStart,
            fingerprint: donorMeta.fingerprint,
            pickMetadata: donorMeta,
            graph: graph
        )

        guard leafExpansions.isEmpty == false else { return entries }

        var result: [ChoiceSequenceValue] = []
        result.reserveCapacity(entries.count + leafExpansions.count * 3)

        for (index, entry) in entries.enumerated() {
            let absolutePosition = donorRangeStart + index
            if let wrapping = leafExpansions[absolutePosition] {
                switch wrapping {
                case let .pick(branchID, validIDs, fingerprint):
                    result.append(.group(true))
                    result.append(.branch(.init(id: branchID, validIDs: validIDs, fingerprint: fingerprint)))
                    result.append(entry)
                    result.append(.group(false))
                case let .bind(depthSelectorEntry):
                    result.append(.bind(true))
                    result.append(depthSelectorEntry)
                    result.append(entry)
                    result.append(.bind(false))
                }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Collects depth-0 base case positions and their wrapping kinds for the donor's subtree.
    ///
    /// Two-phase approach: first builds a per-branch recursive-slot mask from non-innermost picks (where the mask is directly observable as pick vs non-pick children), then applies those masks at innermost picks to identify base case positions and determine whether each needs pick wrapping (direct recursion) or bind wrapping (`Gen.recursive`).
    private static func depthZeroLeafExpansions(
        donorNodeID: Int,
        donorRangeStart: Int,
        fingerprint: UInt64,
        pickMetadata: PickMetadata,
        graph: ChoiceGraph
    ) -> [Int: LeafWrapping] {
        // Phase 1: build per-branch masks from non-innermost picks across the entire self-similarity group.
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

        // Phase 2: walk innermost picks and determine wrapping kind for each base case.
        var expansions: [Int: LeafWrapping] = [:]
        for pickID in allPicks {
            guard case let .pick(pickMeta) = graph.nodes[pickID].kind else { continue }
            guard let zipMask = zipMaskForPick(pickID: pickID, fingerprint: fingerprint, graph: graph) else { continue }
            guard zipMask.isEmpty else { continue }
            let mask = branchMasks[pickMeta.selectedID]

            // Determine wrapping: if the innermost pick's parent is a ._bound bind,
            // skip expansion — the ._bound already handles depth-crossing via its
            // depth selector. Adding expansion markers would double-wrap.
            let wrapping = wrappingForInnermostPick(pickID: pickID, fingerprint: fingerprint, pickMetadata: pickMetadata, graph: graph)
            guard let wrapping else { continue }

            collectBaseCasesFromInnermostPick(
                pickID: pickID,
                fingerprint: fingerprint,
                mask: mask,
                wrapping: wrapping,
                graph: graph,
                expansions: &expansions
            )
        }
        return expansions
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
        let current = pickID
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

    /// Determines the wrapping kind for an innermost pick's base cases, or nil if no expansion is needed.
    ///
    /// Returns nil when the pick is wrapped in a `._bound` bind (`Gen.recursive` pattern) — the `._bound`'s depth selector already handles depth-crossing, and adding expansion markers would double-wrap. Returns pick wrapping for direct recursion (like BinaryHeap) where the base case needs explicit pick-site markers.
    private static func wrappingForInnermostPick(
        pickID: Int,
        fingerprint: UInt64,
        pickMetadata: PickMetadata,
        graph: ChoiceGraph
    ) -> LeafWrapping? {
        // Check if the pick's parent is a ._bound bind (bind → pick with same fingerprint).
        if let parentID = graph.nodes[pickID].parent,
           case let .bind(bindMeta) = graph.nodes[parentID].kind,
           bindMeta.boundChildIndex < graph.nodes[parentID].children.count
        {
            let boundChildID = graph.nodes[parentID].children[bindMeta.boundChildIndex]
            if case let .pick(boundMeta) = graph.nodes[boundChildID].kind,
               boundMeta.fingerprint == fingerprint
            {
                // ._bound pattern: no expansion needed.
                return nil
            }
        }

        // Direct recursion: use pick wrapping.
        if let leafBranchID = findLeafBranchID(in: pickMetadata) {
            return .pick(branchID: leafBranchID, validIDs: pickMetadata.branchIDs, fingerprint: pickMetadata.fingerprint)
        }
        return .pick(branchID: pickMetadata.branchIDs[0], validIDs: pickMetadata.branchIDs, fingerprint: pickMetadata.fingerprint)
    }

    /// Records base case positions and wrapping kinds from an innermost pick using a precomputed mask. When ``mask`` is nil (no non-innermost picks available to derive the mask), all zip children are expanded.
    private static func collectBaseCasesFromInnermostPick(
        pickID: Int,
        fingerprint: UInt64,
        mask: Set<Int>?,
        wrapping: LeafWrapping?,
        graph: ChoiceGraph,
        expansions: inout [Int: LeafWrapping]
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
                        expansions[range.lowerBound] = wrapping
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
