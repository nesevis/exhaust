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
        DependencyReachability.isReachable(from: nodeA, to: nodeB, adjacency: dependencyAdjacency) == false
            && DependencyReachability.isReachable(from: nodeB, to: nodeA, adjacency: dependencyAdjacency) == false
    }
}

// MARK: - Structural Fingerprint

package extension ChoiceGraph {
    /// Computes a structural fingerprint over the active region topology.
    ///
    /// Hashes the multiset of `(kind, positionRange.lowerBound, positionRange.upperBound)` tuples for every active node. Per-node hashes are collected, sorted, then chained through an FNV-1a-style aggregator so the final value is independent of `nodes` array order. Does **not** include `node.id`—``ChoiceGraphBuilder`` assigns IDs sequentially during the tree walk, so a corresponding structural position can receive a different ID after a rebuild.
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
