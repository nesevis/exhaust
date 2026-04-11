//
//  ChoiceGraph+ReplacementScopes.swift
//  Exhaust
//

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
                      descendantMetadata.depthMaskedSiteID == ancestorMetadata.depthMaskedSiteID
                else {
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
