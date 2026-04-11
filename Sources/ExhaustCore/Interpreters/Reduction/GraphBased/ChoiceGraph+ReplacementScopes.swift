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

        // Branch pivot: one scope per active pick node, carrying all
        // non-selected alternatives sorted simplest-first by subtree size.
        // The encoder iterates `targetBranchIDs` across probes within a
        // single scope dispatch — bundling at the pick-site level keeps
        // alternatives off the scheduler's priority queue, where lower-yield
        // pivots would otherwise be starved by higher-yield ones from other
        // pick sites.
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard metadata.branchIDs.count >= 2 else { continue }
            guard node.children.count == metadata.branchIDs.count else { continue }

            // Build (branchID, subtreeSize) pairs for non-selected branches.
            var alternatives: [(branchID: UInt64, subtreeSize: Int)] = []
            for index in 0 ..< metadata.branchIDs.count {
                let branchID = metadata.branchIDs[index]
                guard branchID != metadata.selectedID else { continue }
                let childNodeID = node.children[index]
                alternatives.append((
                    branchID: branchID,
                    subtreeSize: subtreeNodeCount(rootID: childNodeID)
                ))
            }
            alternatives.sort { $0.subtreeSize < $1.subtreeSize }

            guard alternatives.isEmpty == false else { continue }

            scopes.append(.branchPivot(BranchPivotScope(
                pickNodeID: node.id,
                siteID: metadata.siteID,
                selectedID: metadata.selectedID,
                targetBranchIDs: alternatives.map(\.branchID)
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
