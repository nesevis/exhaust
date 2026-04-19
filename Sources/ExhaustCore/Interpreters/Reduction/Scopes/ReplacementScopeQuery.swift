//
//  ReplacementScopeQuery.swift
//  Exhaust
//

// MARK: - Replacement Scope Query

/// Static scope builder for replacement operations (self-similar substitution, branch pivots, and descendant promotion).
///
/// Replaces the former `ChoiceGraph.replacementScopes()` instance method.
enum ReplacementScopeQuery {
    /// Computes replacement scopes from self-similarity groups, pick nodes, and descendant promotion candidates.
    ///
    /// - Returns: All replacement scopes across the three sub-types.
    static func build(graph: ChoiceGraph) -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        // Self-similar substitution: for each group of picks with the same
        // fingerprint, generate one scope per ordered pair where the
        // target is larger than the donor (positive size delta), plus one
        // scope per zero-delta pair.
        for (_, group) in graph.selfSimilarityGroups {
            guard group.count >= 2 else { continue }
            var indexA = 0
            while indexA < group.count {
                let nodeA = group[indexA]
                let sizeA = graph.nodes[nodeA].positionRange?.count ?? 0
                var indexB = indexA + 1
                while indexB < group.count {
                    let nodeB = group[indexB]
                    let sizeB = graph.nodes[nodeB].positionRange?.count ?? 0
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
        for node in graph.nodes {
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
                    targetBranchID: branchID
                )))
            }
        }

        // Descendant promotion: for each pick node, check group members
        // that are containment descendants with a smaller subtree.
        for node in graph.nodes {
            guard case let .pick(ancestorMetadata) = node.kind else { continue }
            guard let ancestorRange = node.positionRange else { continue }
            guard let group = graph.selfSimilarityGroups[ancestorMetadata.fingerprint] else { continue }
            for descendantID in group {
                guard descendantID != node.id else { continue }
                guard let descendantRange = graph.nodes[descendantID].positionRange else { continue }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else { continue }
                let reachable = graph.isReachable(from: node.id, to: descendantID)
                    || isContainmentDescendant(descendantID, of: node.id, graph: graph)
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

    // MARK: - Private Helpers

    /// Counts `.choice` leaves reachable from a choice tree subtree. Used by the leaf-count gate in branch pivot scope construction.
    private static func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
        case .choice: 1
        case .just, .getSize: 0
        case let .sequence(_, elements, _): elements.reduce(0) { $0 + leafCount(in: $1) }
        case let .branch(_, _, _, _, choice): leafCount(in: choice)
        case let .group(children, _): children.reduce(0) { $0 + leafCount(in: $1) }
        case let .resize(_, choices): choices.reduce(0) { $0 + leafCount(in: $1) }
        case let .bind(_, inner, bound): leafCount(in: inner) + leafCount(in: bound)
        case let .selected(inner): leafCount(in: inner)
        }
    }

    /// Checks whether `descendant` is reachable from `ancestor` via containment edges (parent-child chain).
    private static func isContainmentDescendant(
        _ descendant: Int,
        of ancestor: Int,
        graph: ChoiceGraph
    ) -> Bool {
        var current = descendant
        while let parentID = graph.nodes[current].parent {
            if parentID == ancestor { return true }
            current = parentID
        }
        return false
    }
}
