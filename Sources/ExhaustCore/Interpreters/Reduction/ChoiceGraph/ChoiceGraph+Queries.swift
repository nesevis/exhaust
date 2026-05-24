//
//  ChoiceGraph+Queries.swift
//  Exhaust
//

// MARK: - Dependency Queries

package extension ChoiceGraph {
    /// Dependency edges where bound value composition is meaningful.
    ///
    /// Each edge connects a bind-inner node (controlling position) to its scope (controlled subtree). Ordered by topological sort (roots first).
    var reductionEdges: [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] {
        var edges: [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] = []
        for nodeID in liveNodeIDs {
            let node = nodes[nodeID]
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            edges.append((
                upstreamNodeID: innerChildID,
                downstreamNodeID: boundChildID,
                isStructurallyConstant: metadata.isStructurallyConstant
            ))
        }
        return edges
    }

    /// Whether two nodes are independent (no dependency path between them in either direction).
    func areIndependent(_ nodeA: Int, _ nodeB: Int) -> Bool {
        isReachable(from: nodeA, to: nodeB) == false
            && isReachable(from: nodeB, to: nodeA) == false
    }
}

// MARK: - Containment Queries

package extension ChoiceGraph {
    /// Maximum antichain over deletable structural boundary nodes via Dilworth's theorem.
    ///
    /// A node is deletable if it is a child of a sequence node (an element that can be removed when the sequence's length constraint permits). Nodes whose parent is a zip are tuple slots and cannot be deleted. The root node and individual chooseBits leaves are also excluded.
    ///
    /// Computes the optimal maximum antichain using Hopcroft-Karp bipartite matching on the reachability relation restricted to the candidate set, then extracts the antichain via Konig's theorem. For the typical deletion candidate set (5-15 nodes), this runs in microseconds.
    ///
    /// - SeeAlso: ``BipartiteMatching``
    var deletionAntichain: [Int] {
        let candidateIDs = liveNodeIDs.filter { nodeID in
            let node = nodes[nodeID]
            guard let parentID = node.parent else { return false }
            guard case .sequence = nodes[parentID].kind else { return false }
            return true
        }

        guard candidateIDs.isEmpty == false else { return [] }

        // Map candidate node IDs to dense indices for the bipartite graph.
        let candidateCount = candidateIDs.count
        var idToIndex = [Int: Int]()
        for (index, nodeID) in candidateIDs.enumerated() {
            idToIndex[nodeID] = index
        }

        // Build reachability restricted to the candidate set via on-demand DFS from each candidate. O(K · (V + E)) where K is the candidate count — much cheaper than the former O(V · E) eager transitive closure when K << V.
        let candidateIDSet = Set(candidateIDs)
        var reachability = [Int: Set<Int>]()
        reachability.reserveCapacity(candidateCount)
        for (sourceIndex, sourceID) in candidateIDs.enumerated() {
            let reached = reachableNodes(from: sourceID, within: candidateIDSet)
            var targetIndices = Set<Int>()
            for targetID in reached {
                if let targetIndex = idToIndex[targetID] {
                    targetIndices.insert(targetIndex)
                }
            }
            if targetIndices.isEmpty == false {
                reachability[sourceIndex] = targetIndices
            }
        }

        let antichainIndices = BipartiteMatching.maximumAntichain(
            nodeCount: candidateCount,
            reachability: reachability
        )

        // Map back to node IDs.
        return antichainIndices.map { candidateIDs[$0] }
    }
}

// MARK: - Structural Fingerprint

package extension ChoiceGraph {
    /// Computes a structural fingerprint over the active region topology.
    ///
    /// Hashes the multiset of `(kind, positionRange.lowerBound, positionRange.upperBound)` tuples for every active node. Per-node hashes are collected, sorted, then chained through an FNV-1a-style aggregator so the final value is independent of `nodes` array order. Does **not** include `node.id` — node identity is unstable across rebuilds (``ChoiceGraphBuilder`` assigns IDs sequentially during the tree walk, so the same logical node gets a different ID after any structural change).
    var structuralFingerprint: UInt64 {
        var nodeHashes: [UInt64] = []
        nodeHashes.reserveCapacity(liveNodeIDs.count)
        for nodeID in liveNodeIDs {
            let node = nodes[nodeID]
            let kindByte: UInt64 = switch node.kind {
                case .chooseBits: 0
                case .pick: 1
                case .bind: 2
                case .zip: 3
                case .sequence: 4
                case .just: 5
            }
            var nodeHash: UInt64 = 14_695_981_039_346_656_037 // FNV offset basis
            nodeHash = (nodeHash ^ kindByte) &* 1_099_511_628_211
            if let range = node.positionRange {
                nodeHash = (nodeHash ^ UInt64(range.lowerBound)) &* 1_099_511_628_211
                nodeHash = (nodeHash ^ UInt64(range.upperBound)) &* 6_364_136_223_846_793_005
            }
            nodeHashes.append(nodeHash)
        }
        nodeHashes.sort()
        var combined: UInt64 = 14_695_981_039_346_656_037
        for nodeHash in nodeHashes {
            combined = (combined ^ nodeHash) &* 1_099_511_628_211
        }
        return combined
    }
}
