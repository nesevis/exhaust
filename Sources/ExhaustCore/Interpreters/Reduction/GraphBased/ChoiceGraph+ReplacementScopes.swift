//
//  ChoiceGraph+ReplacementScopes.swift
//  Exhaust
//

// MARK: - Replacement Scope Queries

extension ChoiceGraph {
    /// Computes replacement scopes from self-similarity groups, pick nodes, and descendant promotion candidates.
    ///
    /// - Returns: All replacement scopes across the three sub-types.
    func replacementScopes() -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        // Self-similar substitution: for each group of picks with the same
        // depthMaskedSiteID, generate one scope per ordered pair where the
        // target is larger than the donor (positive size delta), plus one
        // scope per zero-delta pair.
        for (_, group) in selfSimilarityGroups {
            guard group.count >= 2 else { continue }
            var indexA = 0
            while indexA < group.count {
                let nodeA = group[indexA]
                let sizeA = nodes[nodeA].positionRange?.count ?? 0
                var indexB = indexA + 1
                while indexB < group.count {
                    let nodeB = group[indexB]
                    let sizeB = nodes[nodeB].positionRange?.count ?? 0
                    let sizeDelta = sizeA - sizeB
                    if sizeDelta > 0 {
                        scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: sizeDelta
                        )))
                    } else if sizeDelta < 0 {
                        scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                            targetNodeID: nodeB,
                            donorNodeID: nodeA,
                            sizeDelta: -sizeDelta
                        )))
                    } else {
                        scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: 0
                        )))
                    }
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Branch pivot: one scope per (pick node, alternative branch). The source iterates over branches; the encoder is single-shot per scope. The leaf-count gate is applied here — alternatives with more `.choice` leaves than the selected branch are filtered out because they almost always fail the shortlex check and dropping them avoids paying the materialization cost.
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard metadata.branchIDs.count >= 2 else { continue }
            guard node.children.count == metadata.branchIDs.count else { continue }

            let selectedLeafCount = leafCount(in: metadata.branchElements[metadata.selectedChildIndex])

            for index in 0 ..< metadata.branchIDs.count {
                let branchID = metadata.branchIDs[index]
                guard branchID != metadata.selectedID else { continue }

                // Leaf-count gate: skip branches with more leaves than the current selection.
                let candidateLeafCount = leafCount(in: metadata.branchElements[index])
                guard candidateLeafCount <= selectedLeafCount else { continue }

                scopes.append(.branchPivot(BranchPivotScope(
                    pickNodeID: node.id,
                    siteID: metadata.siteID,
                    selectedID: metadata.selectedID,
                    targetBranchID: branchID
                )))
            }
        }

        // Descendant promotion: for each pick node, check group members
        // that are containment descendants with a smaller subtree.
        for node in nodes {
            guard case let .pick(ancestorMetadata) = node.kind else { continue }
            guard let ancestorRange = node.positionRange else { continue }
            guard let group = selfSimilarityGroups[ancestorMetadata.depthMaskedSiteID] else { continue }
            for descendantID in group {
                guard descendantID != node.id else { continue }
                guard let descendantRange = nodes[descendantID].positionRange else { continue }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else { continue }
                let reachable = isReachable(from: node.id, to: descendantID)
                    || isContainmentDescendant(descendantID, of: node.id)
                guard reachable else { continue }
                scopes.append(.descendantPromotion(DescendantPromotionScope(
                    ancestorPickNodeID: node.id,
                    descendantPickNodeID: descendantID,
                    sizeDelta: sizeDelta
                )))
            }
        }

        return scopes
    }

    /// Counts `.choice` leaves reachable from a choice tree subtree. Used by the leaf-count gate in branch pivot scope construction.
    private func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
        case .choice: return 1
        case .just, .getSize: return 0
        case let .sequence(_, elements, _): return elements.reduce(0) { $0 + leafCount(in: $1) }
        case let .branch(_, _, _, _, choice): return leafCount(in: choice)
        case let .group(children, _): return children.reduce(0) { $0 + leafCount(in: $1) }
        case let .resize(_, choices): return choices.reduce(0) { $0 + leafCount(in: $1) }
        case let .bind(inner, bound): return leafCount(in: inner) + leafCount(in: bound)
        case let .selected(inner): return leafCount(in: inner)
        }
    }

    /// Counts the total number of graph nodes in the subtree rooted at the given node.
    private func subtreeNodeCount(rootID: Int) -> Int {
        var count = 0
        var stack = [rootID]
        while let current = stack.popLast() {
            count += 1
            stack.append(contentsOf: nodes[current].children)
        }
        return count
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
