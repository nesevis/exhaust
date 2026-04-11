//
//  ChoiceGraph+Queries.swift
//  Exhaust
//

// MARK: - Dependency Queries

public extension ChoiceGraph {
    /// Dependency edges where Kleisli composition is meaningful.
    ///
    /// Each edge connects a bind-inner node (controlling position) to its scope (controlled subtree). Ordered by topological sort (roots first).
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/reductionEdges()``
    var reductionEdges: [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] {
        var edges: [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] = []
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
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

    /// Bind-inner nodes in topological order with their dependency edges restricted to other bind-inner nodes.
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/bindInnerTopology()``
    var bindInnerTopology: [(nodeID: Int, bindDepth: Int, dependsOn: [Int])] {
        var bindInnerNodeIDs = Set<Int>()
        var bindInnerInfo: [Int: Int] = [:]

        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            bindInnerNodeIDs.insert(innerChildID)
            bindInnerInfo[innerChildID] = metadata.bindDepth
        }

        var result: [(nodeID: Int, bindDepth: Int, dependsOn: [Int])] = []
        for nodeID in topologicalOrder {
            guard bindInnerNodeIDs.contains(nodeID) else { continue }
            let dependsOn = dependencyEdges
                .filter { $0.source == nodeID }
                .map(\.target)
                .filter { bindInnerNodeIDs.contains($0) }
            result.append((
                nodeID: nodeID,
                bindDepth: bindInnerInfo[nodeID] ?? 0,
                dependsOn: dependsOn
            ))
        }
        return result
    }

    /// Whether two nodes are independent (no dependency path between them in either direction).
    func areIndependent(_ nodeA: Int, _ nodeB: Int) -> Bool {
        let reachableFromA = reachability[nodeA] ?? []
        let reachableFromB = reachability[nodeB] ?? []
        return reachableFromA.contains(nodeB) == false
            && reachableFromB.contains(nodeA) == false
    }
}

// MARK: - Containment Queries

public extension ChoiceGraph {
    /// Maximum antichain over deletable structural boundary nodes via Dilworth's theorem.
    ///
    /// A node is deletable if it is a child of a sequence node (an element that can be removed when the sequence's length constraint permits). Nodes whose parent is a zip are tuple slots and cannot be deleted. The root node and individual chooseBits leaves are also excluded.
    ///
    /// Computes the optimal maximum antichain using Hopcroft-Karp bipartite matching on the reachability relation restricted to the candidate set, then extracts the antichain via Konig's theorem. For the typical deletion candidate set (5-15 nodes), this runs in microseconds.
    ///
    /// - SeeAlso: ``BipartiteMatching``
    var deletionAntichain: [Int] {
        let candidateNodes = nodes.filter { node in
            guard node.positionRange != nil else { return false }
            guard let parentID = node.parent else { return false }
            guard case .sequence = nodes[parentID].kind else { return false }
            return true
        }

        guard candidateNodes.isEmpty == false else { return [] }

        // Map candidate node IDs to dense indices for the bipartite graph.
        let candidateIDs = candidateNodes.map(\.id)
        let candidateCount = candidateIDs.count
        var idToIndex = [Int: Int]()
        for (index, nodeID) in candidateIDs.enumerated() {
            idToIndex[nodeID] = index
        }

        // Build reachability restricted to the candidate set.
        // Edge (u, v) means u < v in the partial order (u is reachable from v,
        // that is, v depends on u).
        var adjacency = [[Int]](repeating: [], count: candidateCount)
        for (sourceIndex, sourceID) in candidateIDs.enumerated() {
            let reachable = reachability[sourceID] ?? []
            for targetID in reachable {
                if let targetIndex = idToIndex[targetID] {
                    adjacency[sourceIndex].append(targetIndex)
                }
            }
        }

        let antichainIndices = BipartiteMatching.maximumAntichain(
            nodeCount: candidateCount,
            reachability: Dictionary(
                uniqueKeysWithValues: (0 ..< candidateCount).map { index in
                    (index, Set(adjacency[index]))
                }
            )
        )

        // Map back to node IDs.
        return antichainIndices.map { candidateIDs[$0] }
    }

    /// All leaf node IDs (chooseBits nodes with non-nil position range).
    var leafNodes: [Int] {
        nodes.compactMap { node in
            guard case .chooseBits = node.kind else { return nil }
            guard node.positionRange != nil else { return nil }
            return node.id
        }
    }

    /// Returns the sequence positions of all active `chooseBits` leaf nodes.
    ///
    /// This is the graph's natural definition of leaf positions — every value-producing node with a non-nil position range. This differs from the CDG's `leafPositions`, which partitions the flat sequence around structural node ranges. The graph's model is richer: every leaf has an explicit node with type metadata.
    var leafPositions: [ClosedRange<Int>] {
        nodes.compactMap { node in
            guard case .chooseBits = node.kind else { return nil }
            return node.positionRange
        }
    }
}

// MARK: - Bind Queries

public extension ChoiceGraph {
    /// Returns the bind nesting depth at a given sequence position.
    ///
    /// Counts the number of bind nodes whose bound child's position range contains the given position.
    ///
    /// - SeeAlso: ``BindSpanIndex/bindDepth(at:)``
    func bindDepth(at position: Int) -> Int {
        var depth = 0
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let boundChildID = node.children[metadata.boundChildIndex]
            if let boundRange = nodes[boundChildID].positionRange,
               boundRange.contains(position)
            {
                depth += 1
            }
        }
        return depth
    }

    /// Whether a sequence position falls inside any bind node's bound child range.
    ///
    /// - SeeAlso: ``BindSpanIndex/isInBoundSubtree(_:)``
    func isInBoundSubtree(_ position: Int) -> Bool {
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let boundChildID = node.children[metadata.boundChildIndex]
            if let boundRange = nodes[boundChildID].positionRange,
               boundRange.contains(position)
            {
                return true
            }
        }
        return false
    }

    /// Returns the bind node whose inner child's position range contains the given position, or nil.
    ///
    /// - SeeAlso: ``BindSpanIndex/bindRegionForInnerIndex(_:)``
    func bindNodeForInnerPosition(_ position: Int) -> ChoiceGraphNode? {
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            if let innerRange = nodes[innerChildID].positionRange,
               innerRange.contains(position)
            {
                return node
            }
        }
        return nil
    }
}

// MARK: - Self-Similarity Queries

public extension ChoiceGraph {
    /// Returns self-similarity edges incident to a pick node, annotated with size delta relative to the queried node.
    ///
    /// A positive delta means the neighbour is smaller (the queried node is the substitution target). Sorted by size delta descending (largest reduction first).
    func selfSimilarityEdges(from nodeID: Int) -> [SelfSimilarityEdge] {
        selfSimilarityEdges
            .filter { $0.nodeA == nodeID || $0.nodeB == nodeID }
            .sorted { edgeA, edgeB in
                let deltaA = edgeA.nodeA == nodeID ? edgeA.sizeDelta : -edgeA.sizeDelta
                let deltaB = edgeB.nodeA == nodeID ? edgeB.sizeDelta : -edgeB.sizeDelta
                return deltaA > deltaB
            }
    }
}

// MARK: - Structural Fingerprint

public extension ChoiceGraph {
    /// Computes a structural fingerprint over the active region topology.
    ///
    /// The fingerprint hashes the multiset of `(kind, positionRange.lowerBound, positionRange.upperBound)` tuples for every active node (skipping tombstones and inactive branches). Per-node hashes are collected, sorted, then chained through an FNV-1a-style aggregator so the final value is independent of `nodes` array order. Crucially, the fingerprint does **not** include `node.id` — node identity is unstable across in-place mutations (the splice path keeps existing IDs and appends new ones, while a fresh ``ChoiceGraph/build(from:)`` walks the tree and assigns IDs in walk order), so including identity would make a structurally-correct splice compare unequal to its fresh-rebuild equivalent.
    ///
    /// Used by the partial-rebuild scheduler (``ChoiceGraphScheduler/runProbeLoop(...)``) under instrumentation to validate that ``ChoiceGraph/apply(_:freshTree:)`` produces a graph structurally equivalent to ``ChoiceGraph/build(from:)`` on the same tree.
    var structuralFingerprint: UInt64 {
        var nodeHashes: [UInt64] = []
        nodeHashes.reserveCapacity(nodes.count)
        for node in nodes {
            guard node.positionRange != nil else { continue }
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
