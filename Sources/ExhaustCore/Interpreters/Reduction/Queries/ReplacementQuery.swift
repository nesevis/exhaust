//
//  ReplacementQuery.swift
//  Exhaust
//

// MARK: - Replacement Scope Query

/// Static scope builder for replacement operations (self-similar substitution, branch pivots, and descendant promotion).
enum ReplacementQuery {
    /// Computes replacement scopes from self-similarity groups, pick nodes, and descendant promotion candidates.
    ///
    /// When `previousGraph` is provided (mid-cycle incremental rebuild), groups whose membership and subtree sizes are unchanged are skipped — their candidates were already available in the previous source build and will be re-enumerated at the next cycle start.
    ///
    /// - Parameters:
    ///   - graph: The current choice graph.
    ///   - previousGraph: The graph from before the most recent rebuild. When non-nil, unchanged self-similarity groups are skipped.
    /// - Returns: Replacement scopes for changed (or all, if `previousGraph` is nil) groups.
    static func build(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        let unchangedFingerprints: Set<UInt64> = computeUnchangedFingerprints(
            graph: graph,
            previousGraph: previousGraph
        )

        // Self-similar substitution: for each group of picks with the same fingerprint, generate one scope per ordered pair where the target is larger than the donor (positive size delta), plus one scope per zero-delta pair.
        for (fingerprint, group) in graph.selfSimilarityGroups {
            guard group.count >= 2 else { continue }
            if unchangedFingerprints.contains(fingerprint) { continue }

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
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: sizeDelta
                        ))
                    } else if sizeDelta < 0 {
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeB,
                            donorNodeID: nodeA,
                            sizeDelta: -sizeDelta
                        ))
                    } else {
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: 0
                        ))
                    }
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Branch pivot: one scope per (pick node, alternative branch). The source iterates over branches; the encoder is single-shot per scope. The leaf-count gate is applied here — alternatives with more `.choice` leaves than the selected branch are filtered out because they almost always fail the shortlex check and dropping them avoids paying the materialization cost.
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .pick(metadata) = node.kind else { continue }
            guard metadata.branchCount >= 2 else { continue }
            guard node.children.count == Int(metadata.branchCount) else { continue }

            let selectedLeafCount = leafCount(in: metadata.branchElements[metadata.selectedChildIndex])

            for index in 0 ..< Int(metadata.branchCount) {
                let branchID = UInt64(index)
                guard branchID != metadata.selectedID else { continue }

                let candidateLeafCount = leafCount(in: metadata.branchElements[index])
                guard candidateLeafCount <= selectedLeafCount else { continue }

                scopes.append(.branchPivot(
                    pickNodeID: nodeID,
                    targetBranchID: branchID
                ))
            }
        }

        // Descendant promotion: for each pick node, check group members that are containment descendants with a smaller subtree.
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .pick(ancestorMetadata) = node.kind else { continue }
            guard let ancestorRange = node.positionRange else { continue }
            if unchangedFingerprints.contains(ancestorMetadata.fingerprint) { continue }
            guard let group = graph.selfSimilarityGroups[ancestorMetadata.fingerprint] else { continue }
            for descendantID in group {
                guard descendantID != nodeID else { continue }
                guard let descendantRange = graph.nodes[descendantID].positionRange else { continue }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else { continue }
                let reachable = graph.isReachable(from: nodeID, to: descendantID)
                    || isContainmentDescendant(descendantID, of: nodeID, graph: graph)
                guard reachable else { continue }
                scopes.append(.descendantPromotion(
                    ancestorPickNodeID: nodeID,
                    descendantPickNodeID: descendantID,
                    sizeDelta: sizeDelta
                ))
            }
        }

        return scopes
    }

    // MARK: - Incremental Comparison

    /// Returns the set of fingerprints whose self-similarity groups are unchanged between `previousGraph` and `graph`.
    ///
    /// A group is unchanged when it has the same member count and the same sorted multiset of subtree sizes (position range counts). Unchanged groups produce identical replacement scopes, so mid-cycle rebuilds can skip them.
    private static func computeUnchangedFingerprints(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph?
    ) -> Set<UInt64> {
        guard let previousGraph else { return [] }
        var unchanged = Set<UInt64>()
        for (fingerprint, newGroup) in graph.selfSimilarityGroups {
            guard let oldGroup = previousGraph.selfSimilarityGroups[fingerprint] else { continue }
            guard oldGroup.count == newGroup.count else { continue }
            let oldSizes = oldGroup.map { previousGraph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            let newSizes = newGroup.map { graph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            if oldSizes == newSizes {
                unchanged.insert(fingerprint)
            }
        }
        return unchanged
    }

    // MARK: - Private Helpers

    /// Counts `.choice` leaves reachable from a choice tree subtree. Used by the leaf-count gate in branch pivot scope construction.
    private static func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
            case .choice: 1
            case .just, .getSize: 0
            case let .sequence(_, elements, _): elements.reduce(0) { $0 + leafCount(in: $1) }
            case let .branch(b): leafCount(in: b.choice)
            case let .group(children, _): children.reduce(0) { $0 + leafCount(in: $1) }
            case let .resize(_, choices): choices.reduce(0) { $0 + leafCount(in: $1) }
            case let .bind(_, inner, bound): leafCount(in: inner) + leafCount(in: bound)
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
