//
//  GraphStructuralEncoder+Replacement.swift
//  Exhaust
//

extension GraphStructuralEncoder {
    /// Builds a replacement probe from a self-similar, branch-pivot, or descendant-promotion scope.
    mutating func buildReplacementProbe(
        into candidate: inout ChoiceSequence,
        scope: ReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ProjectedMutation? {
        switch scope {
            case let .selfSimilar(targetNodeID, donorNodeID, _):
                guard let built = buildSelfSimilarCandidate(targetNodeID: targetNodeID, donorNodeID: donorNodeID, sequence: sequence, graph: graph) else {
                    return nil
                }
                candidate = built
                return .selfSimilarReplaced(
                    targetNodeID: targetNodeID,
                    donorNodeID: donorNodeID
                )

            case let .branchPivot(pickNodeID, targetBranchID):
                return buildBranchPivotCandidate(into: &candidate, pickNodeID: pickNodeID, targetBranchID: targetBranchID, sequence: sequence, graph: graph)

            case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _):
                guard let built = buildDescendantPromotionCandidate(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID, sequence: sequence, graph: graph) else {
                    return nil
                }
                candidate = built
                return .descendantPromoted(
                    ancestorPickNodeID: ancestorPickNodeID,
                    descendantPickNodeID: descendantPickNodeID
                )
        }
    }

    /// Copies donor entries into the target's position range, expanding depth-0 leaf entries to full pick-site equivalents for depth-crossing compatibility.
    private mutating func buildSelfSimilarCandidate(
        targetNodeID: Int,
        donorNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[targetNodeID].positionRange,
              let donorRange = graph.nodes[donorNodeID].positionRange
        else {
            return nil
        }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        let expanded = Self.expandDepthZeroLeaves(
            donorEntries,
            donorNodeID: donorNodeID,
            donorRangeStart: donorRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: expanded)
        guard candidate.shortLexPrecedes(sequence) else {
            hadReplacementShortlexRejection = true
            return nil
        }
        return candidate
    }

    /// Builds a single branch-pivot candidate for the scope's target branch. The leaf-count gate is applied at scope construction time (in ``replacementScopes()``). This method applies speculative leaf minimization and the shortlex gate.
    private mutating func buildBranchPivotCandidate(
        into candidate: inout ChoiceSequence,
        pickNodeID: Int,
        targetBranchID: UInt64,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ProjectedMutation? {
        guard let pivoted = Self.branchPivotCandidate(
            pickNodeID: pickNodeID,
            targetBranchID: targetBranchID,
            sequence: sequence,
            graph: graph
        ) else {
            return nil
        }
        candidate = pivoted
        guard candidate.shortLexPrecedes(sequence) else {
            hadReplacementShortlexRejection = true
            return nil
        }
        return .branchSelected(
            pickNodeID: pickNodeID,
            newSelectedID: targetBranchID
        )
    }

    /// The sequence with the pick's span replaced by the target branch's content, every leaf of that content at its reduction target. Nil when the pick, its range, or the target branch cannot be resolved. No ordering gate: callers decide whether the candidate has to precede `sequence` on its own or after a lift.
    static func branchPivotCandidate(
        pickNodeID: Int,
        targetBranchID: UInt64,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard pickNodeID < graph.nodes.count else { return nil }
        guard case let .pick(pickMetadata) = graph.nodes[pickNodeID].kind else {
            return nil
        }
        guard let pickRange = graph.nodes[pickNodeID].positionRange else {
            return nil
        }
        let elements = pickMetadata.branchElements
        guard pickMetadata.selectedChildIndex < elements.count else { return nil }

        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
                case let .branch(b):
                    b.id == targetBranchID
                default:
                    false
            }
        }) else { return nil }

        let minimizedTarget = elements[targetElementIndex].minimizingLeaves
        let targetContent = ChoiceSequence.flatten(minimizedTarget.selecting())

        var replacement: [ChoiceSequenceValue] = []
        replacement.reserveCapacity(targetContent.count + 3)
        replacement.append(.group(true))
        replacement.append(.branch(.init(
            id: targetBranchID,
            branchCount: pickMetadata.branchCount,
            fingerprint: pickMetadata.fingerprint
        )))
        for index in 0 ..< targetContent.count {
            replacement.append(targetContent[index])
        }
        replacement.append(.group(false))

        var candidate = sequence
        candidate.replaceSubrange(pickRange.lowerBound ... pickRange.upperBound, with: replacement)
        return candidate
    }

    /// Replaces the ancestor's range with the descendant's content.
    private mutating func buildDescendantPromotionCandidate(
        ancestorPickNodeID: Int,
        descendantPickNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[descendantPickNodeID].positionRange
        else {
            return nil
        }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        let expanded = Self.expandDepthZeroLeaves(
            descendantEntries,
            donorNodeID: descendantPickNodeID,
            donorRangeStart: descendantRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: expanded)
        guard candidate.shortLexPrecedes(sequence) else {
            hadReplacementShortlexRejection = true
            return nil
        }
        return candidate
    }

    // MARK: - Depth-Crossing Expansion

    /// Wrapping kind for a depth-0 base case entry during cross-depth expansion.
    private enum LeafWrapping {
        /// Direct recursion (like BinaryHeap): wrap in pick-site markers.
        case pick(branchID: UInt64, branchCount: UInt64, fingerprint: UInt64)
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
            fingerprint: donorMeta.fingerprint,
            graph: graph
        )

        guard leafExpansions.isEmpty == false else { return entries }

        var result: [ChoiceSequenceValue] = []
        result.reserveCapacity(entries.count + leafExpansions.count * 3)

        for (index, entry) in entries.enumerated() {
            let absolutePosition = donorRangeStart + index
            if let wrapping = leafExpansions[absolutePosition] {
                switch wrapping {
                    case let .pick(branchID, branchCount, fingerprint):
                        result.append(.group(true))
                        result.append(.branch(.init(id: branchID, branchCount: branchCount, fingerprint: fingerprint)))
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
    /// Two-phase approach: first reads, per arm, which pick family occupies each zip slot, then applies those layouts at innermost picks of the donor's family. A slot that holds a pick at the observed depth but a bare leaf at the innermost depth is a base case, and it is wrapped with the leaf branch of the family the slot expects. That family need not be the donor's own: a recursive generator whose arms zip children of two mutually recursive families bottoms out in each slot with that slot's family's leaf.
    ///
    /// A layout is read from every branch alternative of every pick in the family, keyed by branch identifier, because the graph carries the inactive alternatives and an arm's layout is the same wherever it appears. Keying by arm is what matters: two arms of one pick can zip the same families in a different order, and a layout read from the wrong arm wraps the wrong slot. The innermost pick's own zip is read from its active branch only.
    private static func depthZeroLeafExpansions(
        donorNodeID: Int,
        fingerprint: UInt64,
        graph: ChoiceGraph
    ) -> [Int: LeafWrapping] {
        var branchSlotFamilies: [UInt64: [Int: UInt64]] = [:]
        let allGroupPicks = graph.selfSimilarityGroups[fingerprint] ?? []
        for pickID in allGroupPicks {
            guard case let .pick(pickMeta) = graph.nodes[pickID].kind else { continue }
            let node = graph.nodes[pickID]
            for (childIndex, childID) in node.children.enumerated() {
                guard childIndex < pickMeta.branchElements.count,
                      case let .branch(branch) = pickMeta.branchElements[childIndex],
                      branchSlotFamilies[branch.id] == nil,
                      let zipID = zip(below: childID, fingerprint: fingerprint, graph: graph, activeOnly: false)
                else {
                    continue
                }
                let slotFamilies = slotFamilies(ofZip: zipID, graph: graph)
                guard slotFamilies.values.contains(fingerprint) else {
                    continue
                }
                branchSlotFamilies[branch.id] = slotFamilies
            }
        }

        var allPicks: [Int] = []
        collectSelfSimilarPicks(rootID: donorNodeID, fingerprint: fingerprint, graph: graph, into: &allPicks)

        var familyWrappings: [UInt64: LeafWrapping?] = [:]
        var expansions: [Int: LeafWrapping] = [:]
        for pickID in allPicks {
            guard case let .pick(pickMeta) = graph.nodes[pickID].kind else { continue }
            guard let slotFamilies = zipSlotFamilies(pickID: pickID, fingerprint: fingerprint, graph: graph) else {
                continue
            }
            guard slotFamilies.values.contains(fingerprint) == false else {
                continue
            }
            let mask = branchSlotFamilies[pickMeta.selectedID]

            // The donor family's wrapping is decided at the innermost pick itself: its parent tells whether the family recurses through `._bound`, in which case the depth selector already handles depth-crossing and no expansion is needed.
            familyWrappings[fingerprint] = wrappingForInnermostPick(pickID: pickID, fingerprint: fingerprint, pickMetadata: pickMeta, graph: graph)

            collectBaseCasesFromInnermostPick(
                pickID: pickID,
                donorFingerprint: fingerprint,
                mask: mask,
                graph: graph,
                familyWrappings: &familyWrappings,
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

    /// Returns the zip reached from a node through any binds, or nil when there is none. Same-family picks are not entered, so the zip found is the one directly below the starting node's arm.
    private static func zip(below startID: Int, fingerprint: UInt64, graph: ChoiceGraph, activeOnly: Bool) -> Int? {
        var stack = [startID]
        while stack.isEmpty == false {
            let nodeID = stack.removeLast()
            let node = graph.nodes[nodeID]
            if activeOnly, node.positionRange == nil { continue }
            if case let .pick(metadata) = node.kind, metadata.fingerprint == fingerprint {
                continue
            } else if case let .bind(bindMeta) = node.kind {
                if bindMeta.boundChildIndex < node.children.count {
                    stack.append(node.children[bindMeta.boundChildIndex])
                }
            } else if case .zip = node.kind {
                return nodeID
            }
        }
        return nil
    }

    /// Returns the active zip reached from a pick through its selected branch and any binds, or nil when there is none.
    private static func activeZip(below pickID: Int, fingerprint: UInt64, graph: ChoiceGraph) -> Int? {
        for childID in graph.nodes[pickID].children {
            if let zipID = zip(below: childID, fingerprint: fingerprint, graph: graph, activeOnly: true) {
                return zipID
            }
        }
        return nil
    }

    /// The fingerprint of the pick family occupying each slot of a zip. A slot holding anything other than a pick is absent, so an empty result means the zip is innermost (no recursive children).
    private static func slotFamilies(ofZip zipID: Int, graph: ChoiceGraph) -> [Int: UInt64] {
        var families: [Int: UInt64] = [:]
        for (index, childID) in graph.nodes[zipID].children.enumerated() {
            if case let .pick(childMeta) = graph.nodes[childID].kind {
                families[index] = childMeta.fingerprint
            }
        }
        return families
    }

    /// Returns, for the active zip below a pick, the fingerprint of the pick family occupying each zip slot, or nil if no zip is found.
    private static func zipSlotFamilies(
        pickID: Int,
        fingerprint: UInt64,
        graph: ChoiceGraph
    ) -> [Int: UInt64]? {
        guard let zipID = activeZip(below: pickID, fingerprint: fingerprint, graph: graph) else {
            return nil
        }
        return slotFamilies(ofZip: zipID, graph: graph)
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
            return .pick(branchID: leafBranchID, branchCount: pickMetadata.branchCount, fingerprint: pickMetadata.fingerprint)
        }
        return .pick(branchID: 0, branchCount: pickMetadata.branchCount, fingerprint: pickMetadata.fingerprint)
    }

    /// The wrapping for a pick family other than the donor's, decided from any active member of the family, memoized in `familyWrappings`.
    private static func familyWrapping(
        for fingerprint: UInt64,
        graph: ChoiceGraph,
        familyWrappings: inout [UInt64: LeafWrapping?]
    ) -> LeafWrapping? {
        if let cached = familyWrappings[fingerprint] {
            return cached
        }
        var wrapping: LeafWrapping?
        if let representativeID = graph.selfSimilarityGroups[fingerprint]?.first,
           case let .pick(metadata) = graph.nodes[representativeID].kind
        {
            wrapping = wrappingForInnermostPick(pickID: representativeID, fingerprint: fingerprint, pickMetadata: metadata, graph: graph)
        }
        familyWrappings[fingerprint] = wrapping
        return wrapping
    }

    /// Records base case positions and wrapping kinds from an innermost pick using a precomputed slot layout. A slot the layout assigns to a family is wrapped with that family's leaf branch when the innermost pick holds a bare leaf there; a slot already holding a pick needs nothing. When ``mask`` is nil (no non-innermost picks available to derive the layout), every non-pick zip child is wrapped with the donor family's leaf branch.
    private static func collectBaseCasesFromInnermostPick(
        pickID: Int,
        donorFingerprint: UInt64,
        mask: [Int: UInt64]?,
        graph: ChoiceGraph,
        familyWrappings: inout [UInt64: LeafWrapping?],
        expansions: inout [Int: LeafWrapping]
    ) {
        guard let zipID = activeZip(below: pickID, fingerprint: donorFingerprint, graph: graph) else {
            return
        }
        for (index, childID) in graph.nodes[zipID].children.enumerated() {
            let child = graph.nodes[childID]
            if case .pick = child.kind {
                continue
            }
            let family: UInt64
            if let mask {
                guard let expected = mask[index] else {
                    continue
                }
                family = expected
            } else {
                family = donorFingerprint
            }
            guard let wrapping = familyWrapping(for: family, graph: graph, familyWrappings: &familyWrappings),
                  let range = child.positionRange
            else {
                continue
            }
            expansions[range.lowerBound] = wrapping
        }
    }

    /// Finds the branch ID of the first leaf (`.just` or `.choice`) branch in a pick site's elements.
    private static func findLeafBranchID(in metadata: PickMetadata) -> UInt64? {
        for (index, element) in metadata.branchElements.enumerated() {
            guard index < Int(metadata.branchCount) else { break }
            if case let .branch(b) = element {
                switch b.choice {
                    case .just, .choice:
                        return UInt64(index)
                    default:
                        continue
                }
            }
        }
        return nil
    }
}
