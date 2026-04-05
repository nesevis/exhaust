//
//  ChoiceGraph+Scopes.swift
//  Exhaust
//

// MARK: - Removal Scope Queries

extension ChoiceGraph {

    /// Computes aligned removal scopes for all zip nodes with multiple sequence children.
    ///
    /// An aligned tuple groups elements at corresponding offsets across sibling sequences. The scope provides siblings and their deletable elements in natural offset order — the encoder handles window placement (head-aligned, tail-aligned, or both) within its probe loop, analogous to head/tail alternation in per-parent removal.
    ///
    /// - Returns: One scope per zip node with at least two sequence children that have deletable elements.
    func alignedRemovalScopes() -> [AlignedRemovalScope] {
        var scopes: [AlignedRemovalScope] = []
        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let sequenceChildren = node.children.compactMap { childID
                -> SiblingDeletionScope? in
                let child = nodes[childID]
                guard case let .sequence(metadata) = child.kind else {
                    return nil
                }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else { return nil }
                return SiblingDeletionScope(
                    sequenceNodeID: childID,
                    elementNodeIDs: child.children,
                    deletableCount: deletable
                )
            }
            guard sequenceChildren.count >= 2 else { continue }

            let maxWindow = sequenceChildren.map(\.deletableCount).min() ?? 0
            guard maxWindow > 0 else { continue }

            var totalYield = 0
            for sibling in sequenceChildren {
                for elementNodeID in sibling.elementNodeIDs {
                    totalYield += nodes[elementNodeID].positionRange?.count ?? 0
                }
            }

            scopes.append(AlignedRemovalScope(
                zipNodeID: node.id,
                siblings: sequenceChildren,
                maxAlignedWindow: maxWindow,
                maxYield: totalYield
            ))
        }
        return scopes
    }

    /// Computes per-parent removal scopes for all sequence nodes with deletable elements.
    ///
    /// Groups deletable elements by their parent sequence node. Each scope contains the elements in position order, the maximum batch size, and the yield of the largest single element.
    ///
    /// - Returns: One scope per sequence node with at least one deletable element.
    func perParentRemovalScopes() -> [PerParentRemovalScope] {
        var parentGroups: [Int: [Int]] = [:]

        for node in nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            parentGroups[parentID, default: []].append(node.id)
        }

        return parentGroups.map { parentID, elementNodeIDs in
            let sortedElements = elementNodeIDs.sorted { nodeA, nodeB in
                let rangeA = nodes[nodeA].positionRange?.lowerBound ?? 0
                let rangeB = nodes[nodeB].positionRange?.lowerBound ?? 0
                return rangeA < rangeB
            }
            let maxElementYield = sortedElements.reduce(0) { maxSoFar, nodeID in
                max(maxSoFar, nodes[nodeID].positionRange?.count ?? 0)
            }
            guard case let .sequence(metadata) = nodes[parentID].kind else {
                // Should not happen — we only collected elements with sequence parents.
                return PerParentRemovalScope(
                    sequenceNodeID: parentID,
                    elementNodeIDs: sortedElements,
                    maxBatch: sortedElements.count,
                    maxElementYield: maxElementYield
                )
            }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            let deletable = metadata.elementCount - minLength
            return PerParentRemovalScope(
                sequenceNodeID: parentID,
                elementNodeIDs: sortedElements,
                maxBatch: deletable,
                maxElementYield: maxElementYield
            )
        }
    }

    /// Computes subtree removal scopes for compound structural nodes in the deletion antichain.
    ///
    /// Targets nodes with ``ChoiceGraphNode/positionRange`` count greater than one — bind subtrees, zip children, and other compound elements worth removing as a unit.
    ///
    /// - Returns: One scope per compound node in the deletion antichain.
    func subtreeRemovalScopes() -> [SubtreeRemovalScope] {
        deletionAntichain.compactMap { nodeID in
            guard let range = nodes[nodeID].positionRange else { return nil }
            guard range.count > 1 else { return nil }
            return SubtreeRemovalScope(nodeID: nodeID, yield: range.count)
        }
    }
}

// MARK: - Replacement Scope Queries

extension ChoiceGraph {

    /// Computes replacement scopes from self-similarity edges, pick nodes, and descendant promotion candidates.
    ///
    /// - Returns: All replacement scopes across the three sub-types.
    func replacementScopes() -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        // Self-similar substitution: each self-similarity edge with
        // positive size delta is a candidate (nodeA is target, nodeB is donor).
        for edge in selfSimilarityEdges {
            if edge.sizeDelta > 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeA,
                    donorNodeID: edge.nodeB,
                    sizeDelta: edge.sizeDelta
                )))
            } else if edge.sizeDelta < 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeB,
                    donorNodeID: edge.nodeA,
                    sizeDelta: -edge.sizeDelta
                )))
            }
            // Zero-delta edges: both directions for cross-group promotion.
            if edge.sizeDelta == 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeA,
                    donorNodeID: edge.nodeB,
                    sizeDelta: 0
                )))
            }
        }

        // Branch pivot: pick nodes with multiple branches.
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard metadata.branchIDs.count >= 2 else { continue }
            let alternatives = metadata.branchIDs.filter { $0 != metadata.selectedID }
            guard alternatives.isEmpty == false else { continue }
            scopes.append(.branchPivot(BranchPivotScope(
                pickNodeID: node.id,
                candidateBranchIDs: alternatives
            )))
        }

        // Descendant promotion: pairs (ancestor pick, descendant pick) with
        // matching depthMaskedSiteID where the descendant's subtree is smaller.
        for node in nodes {
            guard case let .pick(ancestorMetadata) = node.kind else { continue }
            guard let ancestorRange = node.positionRange else { continue }
            for edge in selfSimilarityEdges {
                let otherID = edge.nodeA == node.id ? edge.nodeB : (edge.nodeB == node.id ? edge.nodeA : nil)
                guard let descendantID = otherID else { continue }
                guard let descendantRange = nodes[descendantID].positionRange else { continue }
                // The descendant must be reachable from the ancestor via containment.
                let reachable = reachability[node.id]?.contains(descendantID) ?? false
                    || isContainmentDescendant(descendantID, of: node.id)
                guard reachable else { continue }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else { continue }
                // Avoid duplicate with self-similar scope.
                guard case let .pick(descendantMetadata) = nodes[descendantID].kind,
                      descendantMetadata.depthMaskedSiteID == ancestorMetadata.depthMaskedSiteID else {
                    continue
                }
                scopes.append(.descendantPromotion(DescendantPromotionScope(
                    ancestorPickNodeID: node.id,
                    descendantPickNodeID: descendantID,
                    sizeDelta: sizeDelta
                )))
            }
        }

        return scopes
    }

    /// Checks whether `descendant` is reachable from `ancestor` via containment edges (parent-child chain).
    private func isContainmentDescendant(_ descendant: Int, of ancestor: Int) -> Bool {
        var current = descendant
        while let parentID = nodes[current].parent {
            if parentID == ancestor { return true }
            current = parentID
        }
        return false
    }
}

// MARK: - Minimisation Scope Queries

extension ChoiceGraph {

    /// Computes minimisation scopes: one integer scope, one float scope, and one Kleisli fibre scope per non-constant reduction edge.
    ///
    /// - Returns: All minimisation scopes, each ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    func minimisationScopes() -> [MinimisationScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [MinimisationScope] = []

        // Integer leaves.
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]

        // Float leaves.
        var floatLeafNodeIDs: [Int] = []

        for nodeID in leafNodes {
            let node = nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }
            guard metadata.convergedOrigin == nil else { continue }

            if metadata.typeTag.isFloatingPoint {
                floatLeafNodeIDs.append(nodeID)
            } else {
                let valueYield = computeValueYield(
                    leafNodeID: nodeID,
                    innerChildToBind: innerChildToBind
                )
                integerLeafNodeIDs.append(nodeID)
                integerValueYields[nodeID] = valueYield
            }
        }

        // Sort integer leaves by value yield descending.
        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        if integerLeafNodeIDs.isEmpty == false {
            scopes.append(.integerLeaves(IntegerMinimisationScope(
                leafNodeIDs: integerLeafNodeIDs,
                batchZeroEligible: integerLeafNodeIDs.count > 1
            )))
        }

        if floatLeafNodeIDs.isEmpty == false {
            scopes.append(.floatLeaves(FloatMinimisationScope(
                leafNodeIDs: floatLeafNodeIDs
            )))
        }

        // Kleisli fibre: one scope per non-constant reduction edge.
        for edge in reductionEdges {
            guard edge.isStructurallyConstant == false else { continue }
            guard nodes[edge.upstreamNodeID].positionRange != nil else { continue }
            let downstreamNodeIDs = collectDescendantLeaves(from: edge.downstreamNodeID)
            let boundSubtreeSize = nodes[edge.downstreamNodeID].positionRange?.count ?? 0
            scopes.append(.kleisliFibre(KleisliFibreScope(
                bindNodeID: findParentBind(of: edge.upstreamNodeID) ?? edge.upstreamNodeID,
                upstreamLeafNodeID: edge.upstreamNodeID,
                downstreamNodeIDs: downstreamNodeIDs,
                boundSubtreeSize: boundSubtreeSize
            )))
        }

        return scopes
    }

    // MARK: - Minimisation Helpers

    /// Builds an index from inner-child node ID to its controlling bind node ID.
    private func buildInnerChildToBind() -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            index[innerChildID] = node.id
        }
        return index
    }

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner for a non-structurally-constant bind, otherwise zero.
    private func computeValueYield(
        leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = nodes[bindNodeID].children[metadata.boundChildIndex]
        return nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Collects all leaf node IDs (chooseBits with non-nil position range) within the subtree rooted at the given node.
    private func collectDescendantLeaves(from rootNodeID: Int) -> [Int] {
        var result: [Int] = []
        var stack = [rootNodeID]
        while let current = stack.popLast() {
            let node = nodes[current]
            if case .chooseBits = node.kind, node.positionRange != nil {
                result.append(current)
            }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// Finds the parent bind node of a given node, or nil.
    private func findParentBind(of nodeID: Int) -> Int? {
        var current = nodeID
        while let parentID = nodes[current].parent {
            if case .bind = nodes[parentID].kind {
                return parentID
            }
            current = parentID
        }
        return nil
    }
}

// MARK: - Exchange Scope Queries

extension ChoiceGraph {

    /// Computes exchange scopes from type-compatibility edges and leaf groupings.
    ///
    /// - Returns: Redistribution scope (if source-sink pairs exist) and tandem scope (if same-typed leaf groups with at least two members exist).
    func exchangeScopes() -> [ExchangeScope] {
        var scopes: [ExchangeScope] = []
        let status = sourceSinkStatus

        // Redistribution: source-sink pairs from type-compatibility edges.
        var pairs: [RedistributionPair] = []
        for edge in typeCompatibilityEdges {
            let statusA = status[edge.nodeA]
            let statusB = status[edge.nodeB]

            if statusA == .source, statusB == .sink {
                pairs.append(RedistributionPair(
                    sourceNodeID: edge.nodeA,
                    sinkNodeID: edge.nodeB,
                    typeTag: edge.typeTag ?? .bits
                ))
            } else if statusA == .sink, statusB == .source {
                pairs.append(RedistributionPair(
                    sourceNodeID: edge.nodeB,
                    sinkNodeID: edge.nodeA,
                    typeTag: edge.typeTag ?? .bits
                ))
            }
        }
        if pairs.isEmpty == false {
            scopes.append(.redistribution(RedistributionScope(pairs: pairs)))
        }

        // Tandem: group active leaves by TypeTag.
        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in leafNodes {
            guard case let .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            return TandemGroup(leafNodeIDs: leafIDs, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        return scopes
    }
}

// MARK: - Permutation Scope Queries

extension ChoiceGraph {

    /// Computes permutation scopes for zip nodes with same-shaped siblings.
    ///
    /// Groups children by structural shape derived from graph node metadata. Children with the same shape can be swapped for shortlex improvement.
    ///
    /// - Returns: One scope per zip node with at least one group of two or more same-shaped children.
    func permutationScopes() -> [PermutationScope] {
        var scopes: [PermutationScope] = []

        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard node.children.count >= 2 else { continue }

            var shapeGroups: [NodeShapeKey: [Int]] = [:]
            for childID in node.children {
                guard nodes[childID].positionRange != nil else { continue }
                let key = nodeShapeKey(nodes[childID])
                shapeGroups[key, default: []].append(childID)
            }

            let swappableGroups = shapeGroups.values
                .filter { $0.count >= 2 }
                .sorted { groupA, groupB in
                    let positionA = nodes[groupA[0]].positionRange?.lowerBound ?? 0
                    let positionB = nodes[groupB[0]].positionRange?.lowerBound ?? 0
                    return positionA < positionB
                }

            guard swappableGroups.isEmpty == false else { continue }

            scopes.append(.siblingPermutation(SiblingPermutationScope(
                zipNodeID: node.id,
                swappableGroups: swappableGroups
            )))
        }

        return scopes
    }

    // MARK: - Shape Key

    /// Lightweight shape discriminant for grouping siblings by structural kind.
    ///
    /// Derived from graph node metadata rather than the ``ChoiceTree``. Matches the grouping logic in ``GraphSiblingSwapEncoder``.
    private enum NodeShapeKey: Hashable {
        case value
        case sequence(elementCount: Int)
        case emptySequence
        case zip(childCount: Int)
        case bind
        case pick(branchCount: Int)
    }

    /// Computes the shape key for a graph node.
    private func nodeShapeKey(_ node: ChoiceGraphNode) -> NodeShapeKey {
        switch node.kind {
        case .chooseBits:
            return .value
        case let .sequence(metadata):
            if metadata.elementCount == 0 { return .emptySequence }
            return .sequence(elementCount: metadata.elementCount)
        case .zip:
            return .zip(childCount: node.children.count)
        case .bind:
            return .bind
        case let .pick(metadata):
            return .pick(branchCount: metadata.branchIDs.count)
        }
    }
}
