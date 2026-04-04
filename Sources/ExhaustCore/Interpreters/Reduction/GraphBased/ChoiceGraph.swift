//
//  ChoiceGraph.swift
//  Exhaust
//

// MARK: - Choice Graph

/// A layered multigraph representing the generator's value structure for reduction.
///
/// Built from a ``ChoiceTree`` and its flattened ``ChoiceSequence`` via ``ChoiceGraphBuilder``. Captures five node types (chooseBits, pick, bind, zip, sequence) and four edge layers (dependency, containment, self-similarity, type-compatibility).
///
/// ## Edge Layers
///
/// - **Dependency** (directed): bind-inner → bound content. Ordering constraint — parent before child. Topological sort and reachability operate here.
/// - **Containment** (directed, no ordering constraint): parent → child in the tree. Defines independence structure for antichain computation.
/// - **Self-similarity** (undirected): between active pick nodes with matching `depthMaskedSiteID`. Substitution candidates.
/// - **Type-compatibility** (undirected): between antichain members with compatible types. Redistribution candidates.
///
/// ## Lifecycle
///
/// The static skeleton (zip/pick topology, containment and self-similarity edges) is built once. Dynamic regions (bind subtrees, sequence elements) are rebuilt on structural acceptance. Type-compatibility edges and source/sink annotations are recomputed as needed. See ``ChoiceGraph/rebuildBoundSubtree(bindNodeID:newBoundTree:sequence:)`` and related lifecycle methods.
///
/// - SeeAlso: ``ChoiceGraphBuilder``, ``ChoiceGraphNode``, ``DependencyEdge``, ``ContainmentEdge``, ``SelfSimilarityEdge``, ``TypeCompatibilityEdge``
public struct ChoiceGraph: Sendable {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``.
    public var nodes: [ChoiceGraphNode]

    /// Containment edges forming the tree structure (parent → child).
    public var containmentEdges: [ContainmentEdge]

    /// Dependency edges from bind-inner nodes to structural nodes in their bound subtrees.
    public var dependencyEdges: [DependencyEdge]

    /// Self-similarity edges between active pick nodes with matching `depthMaskedSiteID`.
    public var selfSimilarityEdges: [SelfSimilarityEdge]

    /// Type-compatibility edges between antichain members with matching types. Recomputed on structural acceptance.
    public var typeCompatibilityEdges: [TypeCompatibilityEdge]

    /// Per-node source/sink status for redistribution. Updated on any acceptance.
    public var sourceSinkStatus: [Int: SourceSinkStatus]

    /// Node IDs in dependency order (roots first). Computed via Kahn's algorithm on dependency edges.
    public let topologicalOrder: [Int]

    /// Transitive closure of dependency edges. `reachability[i]` contains all node IDs reachable from node `i`.
    public let reachability: [Int: Set<Int>]
}

// MARK: - Construction

public extension ChoiceGraph {
    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction.
    ///
    /// - Parameter tree: The generator's compositional structure.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        ChoiceGraphBuilder.build(from: tree)
    }
}

// MARK: - Dependency Queries

public extension ChoiceGraph {
    /// Returns dependency edges where Kleisli composition is meaningful.
    ///
    /// Each edge connects a bind-inner node (controlling position) to its scope (controlled subtree). Ordered by topological sort (roots first).
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/reductionEdges()``
    func reductionEdges() -> [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] {
        var edges: [(upstreamNodeID: Int, downstreamNodeID: Int, isStructurallyConstant: Bool)] = []
        for nodeID in topologicalOrder {
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

    /// Returns bind-inner nodes in topological order with their dependency edges restricted to other bind-inner nodes.
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/bindInnerTopology()``
    func bindInnerTopology() -> [(nodeID: Int, bindDepth: Int, dependsOn: [Int])] {
        var bindInnerNodeIDs = Set<Int>()
        var bindInnerInfo: [Int: Int] = [:] // nodeID → bindDepth

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
    /// Computes a maximal antichain over structural boundary nodes (nodes with children, excluding individual chooseBits leaves).
    ///
    /// Greedy construction: sort by subtree size descending, add each node if independent of all existing members. Produces a maximal antichain (cannot be extended) but not necessarily the maximum. Phase 4 upgrades to Dilworth/Hopcroft-Karp.
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/maximalAntichain()``
    func deletionAntichain() -> [Int] {
        // Structural boundary nodes: populated nodes that have children (not individual leaves).
        let candidates = nodes.filter { node in
            node.positionRange != nil
                && node.children.isEmpty == false
        }.sorted { nodeA, nodeB in
            let sizeA = nodeA.positionRange?.count ?? 0
            let sizeB = nodeB.positionRange?.count ?? 0
            return sizeA > sizeB
        }

        var antichain: [Int] = []
        for candidate in candidates {
            let isIndependent = antichain.allSatisfy { existing in
                areIndependent(candidate.id, existing)
            }
            if isIndependent {
                antichain.append(candidate.id)
            }
        }
        return antichain
    }

    /// Returns all leaf node IDs (chooseBits nodes with non-nil position range).
    func leafNodes() -> [Int] {
        nodes.compactMap { node in
            guard case .chooseBits = node.kind else { return nil }
            guard node.positionRange != nil else { return nil }
            return node.id
        }
    }

    /// Returns the ``ChoiceSequence`` position ranges that are leaf positions (value entries not inside any structural node's range).
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/leafPositions``
    func leafPositions(sequenceCount: Int) -> [ClosedRange<Int>] {
        // Collect position ranges of structural nodes (bind-inner, pick).
        var structuralPositions = Set<Int>()
        for node in nodes {
            switch node.kind {
            case .bind, .pick:
                if let range = node.positionRange {
                    for position in range {
                        structuralPositions.insert(position)
                    }
                }
            case .chooseBits, .zip, .sequence:
                break
            }
        }

        // Leaf positions are value entries not in structural ranges.
        var leafRanges: [ClosedRange<Int>] = []
        var currentStart: Int?
        for position in 0 ..< sequenceCount {
            let isLeaf = structuralPositions.contains(position) == false
            if isLeaf {
                if currentStart == nil {
                    currentStart = position
                }
            } else {
                if let start = currentStart {
                    leafRanges.append(start ... (position - 1))
                    currentStart = nil
                }
            }
        }
        if let start = currentStart {
            leafRanges.append(start ... (sequenceCount - 1))
        }
        return leafRanges
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
               boundRange.contains(position) {
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
               boundRange.contains(position) {
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
               innerRange.contains(position) {
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
    /// Computes a structural fingerprint over the dynamic region topology.
    ///
    /// Uses an FNV-1a-style rolling hash over node kinds and their position ranges in the dynamic regions (bind subtrees, sequence elements). A change in fingerprint indicates a structural change. The binary changed/unchanged signal is sufficient for the fibre descent guard.
    func structuralFingerprint() -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV offset basis
        for node in nodes {
            guard node.positionRange != nil else { continue }
            let kindByte: UInt64 = switch node.kind {
            case .chooseBits: 0
            case .pick: 1
            case .bind: 2
            case .zip: 3
            case .sequence: 4
            }
            hash = (hash ^ UInt64(node.id)) &* 1_099_511_628_211
            hash = (hash ^ kindByte) &* 6_364_136_223_846_793_005
            if let range = node.positionRange {
                hash = (hash ^ UInt64(range.lowerBound)) &* 1_099_511_628_211
                hash = (hash ^ UInt64(range.upperBound)) &* 6_364_136_223_846_793_005
            }
        }
        return hash
    }
}
