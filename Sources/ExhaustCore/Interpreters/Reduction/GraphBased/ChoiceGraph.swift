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
/// - **Type-compatibility** (undirected): between antichain members with compatible types. Redistribution candidates. Computed lazily on first access.
///
/// ## Lifecycle
///
/// The static skeleton (zip/pick topology, containment and self-similarity edges) is built once. Dynamic regions (bind subtrees, sequence elements) are rebuilt on structural acceptance. Type-compatibility edges and source/sink annotations are computed lazily on first access and invalidated by structural mutations.
///
/// - SeeAlso: ``ChoiceGraphBuilder``, ``ChoiceGraphNode``, ``DependencyEdge``, ``ContainmentEdge``, ``SelfSimilarityEdge``, ``TypeCompatibilityEdge``
public final class ChoiceGraph {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``.
    public var nodes: [ChoiceGraphNode]

    /// Containment edges forming the tree structure (parent → child).
    public var containmentEdges: [ContainmentEdge]

    /// Dependency edges from bind-inner nodes to structural nodes in their bound subtrees.
    public var dependencyEdges: [DependencyEdge]

    /// Self-similarity edges between active pick nodes with matching `depthMaskedSiteID`.
    public var selfSimilarityEdges: [SelfSimilarityEdge]

    /// Node IDs in dependency order (roots first). Computed via Kahn's algorithm on dependency edges.
    public let topologicalOrder: [Int]

    /// Transitive closure of dependency edges. `reachability[i]` contains all node IDs reachable from node `i`.
    public let reachability: [Int: Set<Int>]

    // MARK: - Lazy Edge State

    /// Cached type-compatibility edges. Computed on first access via ``computeTypeCompatibilityEdges()``, invalidated by ``invalidateDerivedEdges()``.
    private var _typeCompatibilityEdges: [TypeCompatibilityEdge]?

    /// Cached source/sink annotations. Computed on first access via ``computeSourceSinkAnnotations()``, invalidated by ``invalidateDerivedEdges()``.
    private var _sourceSinkStatus: [Int: SourceSinkStatus]?

    /// Type-compatibility edges between antichain members with matching types. Computed lazily on first access and cached until invalidated by a structural mutation.
    public var typeCompatibilityEdges: [TypeCompatibilityEdge] {
        if let cached = _typeCompatibilityEdges { return cached }
        let computed = computeTypeCompatibilityEdges()
        _typeCompatibilityEdges = computed
        return computed
    }

    /// Per-node source/sink status for redistribution. Computed lazily on first access and cached until invalidated.
    public var sourceSinkStatus: [Int: SourceSinkStatus] {
        if let cached = _sourceSinkStatus { return cached }
        let computed = computeSourceSinkAnnotations()
        _sourceSinkStatus = computed
        return computed
    }

    /// Drops cached type-compatibility edges, source/sink annotations, and convergence data on leaf nodes, forcing recomputation on next access.
    func invalidateDerivedEdges() {
        _typeCompatibilityEdges = nil
        _sourceSinkStatus = nil
        clearConvergenceData()
    }

    /// Writes convergence records from an encoder pass onto the corresponding leaf nodes.
    ///
    /// - Parameter records: Map from flat sequence index to the convergence floor at that position.
    func recordConvergence(_ records: [Int: ConvergedOrigin]) {
        for (sequenceIndex, origin) in records {
            guard let nodeIndex = nodes.firstIndex(where: { node in
                guard case .chooseBits = node.kind else { return false }
                return node.positionRange?.lowerBound == sequenceIndex
            }) else { continue }
            guard case var .chooseBits(metadata) = nodes[nodeIndex].kind else { continue }
            metadata.convergedOrigin = origin
            nodes[nodeIndex] = ChoiceGraphNode(
                id: nodes[nodeIndex].id,
                kind: .chooseBits(metadata),
                positionRange: nodes[nodeIndex].positionRange,
                children: nodes[nodeIndex].children,
                parent: nodes[nodeIndex].parent
            )
        }
    }

    /// Clears convergence data from all leaf nodes.
    private func clearConvergenceData() {
        for index in nodes.indices {
            guard case var .chooseBits(metadata) = nodes[index].kind else { continue }
            guard metadata.convergedOrigin != nil else { continue }
            metadata.convergedOrigin = nil
            nodes[index] = ChoiceGraphNode(
                id: nodes[index].id,
                kind: .chooseBits(metadata),
                positionRange: nodes[index].positionRange,
                children: nodes[index].children,
                parent: nodes[index].parent
            )
        }
    }

    // MARK: - Init

    init(
        nodes: [ChoiceGraphNode],
        containmentEdges: [ContainmentEdge],
        dependencyEdges: [DependencyEdge],
        selfSimilarityEdges: [SelfSimilarityEdge],
        topologicalOrder: [Int],
        reachability: [Int: Set<Int>]
    ) {
        self.nodes = nodes
        self.containmentEdges = containmentEdges
        self.dependencyEdges = dependencyEdges
        self.selfSimilarityEdges = selfSimilarityEdges
        self.topologicalOrder = topologicalOrder
        self.reachability = reachability
    }
}

// MARK: - Construction

public extension ChoiceGraph {
    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. Type-compatibility edges and source/sink annotations are deferred until first access.
    ///
    /// - Parameter tree: The generator's compositional structure.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        ChoiceGraphBuilder.build(from: tree)
    }
}

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
    /// Maximal antichain over deletable structural boundary nodes.
    ///
    /// A node is deletable if it is a child of a sequence node (an element that can be removed when the sequence's length constraint permits). Nodes whose parent is a zip are tuple slots and cannot be deleted. The root node and individual chooseBits leaves are also excluded.
    ///
    /// Greedy construction: sort by subtree size descending, add each node if independent of all existing members. Produces a maximal antichain (cannot be extended) but not necessarily the maximum. Phase 4 upgrades to Dilworth/Hopcroft-Karp.
    ///
    /// - SeeAlso: ``ChoiceDependencyGraph/maximalAntichain()``
    var deletionAntichain: [Int] {
        let candidates = nodes.filter { node in
            guard node.positionRange != nil else { return false }
            guard let parentID = node.parent else { return false }
            // Only children of sequence nodes are deletable — they are elements
            // that can be removed. Children of zip nodes are tuple slots.
            guard case .sequence = nodes[parentID].kind else { return false }
            return true
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
    var structuralFingerprint: UInt64 {
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

// MARK: - Lazy Edge Computation

extension ChoiceGraph {
    /// Computes type-compatibility edges from the current node state.
    ///
    /// Groups active `chooseBits` leaves by ``TypeTag`` and creates edges between all antichain-independent pairs within each group.
    private func computeTypeCompatibilityEdges() -> [TypeCompatibilityEdge] {
        let activeLeaves = nodes.filter { node in
            if case .chooseBits = node.kind, node.positionRange != nil {
                return true
            }
            return false
        }

        var leafNodesByTag: [TypeTag: [Int]] = [:]
        for leaf in activeLeaves {
            if case let .chooseBits(metadata) = leaf.kind {
                leafNodesByTag[metadata.typeTag, default: []].append(leaf.id)
            }
        }

        var edges: [TypeCompatibilityEdge] = []
        for (tag, leafIDs) in leafNodesByTag where leafIDs.count >= 2 {
            var indexA = 0
            while indexA < leafIDs.count {
                var indexB = indexA + 1
                while indexB < leafIDs.count {
                    if areIndependent(leafIDs[indexA], leafIDs[indexB]) {
                        edges.append(TypeCompatibilityEdge(
                            nodeA: leafIDs[indexA],
                            nodeB: leafIDs[indexB],
                            typeTag: tag
                        ))
                    }
                    indexB += 1
                }
                indexA += 1
            }
        }
        return edges
    }

    /// Computes source/sink annotations from current leaf values.
    private func computeSourceSinkAnnotations() -> [Int: SourceSinkStatus] {
        var status: [Int: SourceSinkStatus] = [:]
        for node in nodes {
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            let isZero = metadata.value.bitPattern64 == 0
            status[node.id] = isZero ? .sink : .source
        }
        return status
    }
}
