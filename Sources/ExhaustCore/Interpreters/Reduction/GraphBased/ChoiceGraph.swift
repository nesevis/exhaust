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
/// The static skeleton (zip/pick topology, containment and self-similarity edges) is built once. Dynamic regions (bind subtrees, sequence elements) are rebuilt on structural acceptance. Type-compatibility edges, source/sink annotations, topological order, and reachability are computed lazily on first access and invalidated by structural mutations. Removed nodes are tracked via ``removedNodeIDs`` (tombstones) so that node IDs remain stable across partial rebuilds — every iteration site filters tombstoned IDs out.
///
/// - SeeAlso: ``ChoiceGraphBuilder``, ``ChoiceGraphNode``, ``DependencyEdge``, ``ContainmentEdge``, ``SelfSimilarityEdge``, ``TypeCompatibilityEdge``
public final class ChoiceGraph {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``. Tombstoned IDs (members of ``removedNodeIDs``) remain in the array so that surviving IDs stay stable; iteration sites must filter them via ``isTombstoned(_:)``.
    public var nodes: [ChoiceGraphNode]

    /// Containment edges forming the tree structure (parent → child).
    public var containmentEdges: [ContainmentEdge]

    /// Dependency edges from bind-inner nodes to structural nodes in their bound subtrees.
    public var dependencyEdges: [DependencyEdge]

    /// Self-similarity edges between active pick nodes with matching `depthMaskedSiteID`.
    public var selfSimilarityEdges: [SelfSimilarityEdge]

    /// Node IDs that have been removed from the graph by an in-place mutation but whose array slots are retained for ID stability. Iteration sites must skip these via ``isTombstoned(_:)``. Always empty until Layer 4 of the partial-rebuild rollout introduces in-place mutation; Layer 1 adds the field, the helper, and the filtering as a no-op precondition.
    var removedNodeIDs: Set<Int> = []

    /// Returns true when `nodeID` has been removed from the graph but its array slot is retained. Used by every iteration site on ``ChoiceGraph`` to skip removed nodes.
    func isTombstoned(_ nodeID: Int) -> Bool {
        removedNodeIDs.contains(nodeID)
    }

    // MARK: - Lazy Edge State

    /// Cached type-compatibility edges. Computed on first access via ``computeTypeCompatibilityEdges()``, invalidated by ``invalidateDerivedEdges()``.
    private var _typeCompatibilityEdges: [TypeCompatibilityEdge]?

    /// Cached source/sink annotations. Computed on first access via ``computeSourceSinkAnnotations()``, invalidated by ``invalidateDerivedEdges()``.
    private var _sourceSinkStatus: [Int: SourceSinkStatus]?

    /// Cached topological order over dependency edges. Computed on first access via ``computeTopologicalOrder()``, invalidated by ``invalidateTopologicalCaches()``. Layer 1 introduces the cache; Layer 4 wires up the invalidation when bind subtrees are rebuilt in place.
    private var _topologicalOrder: [Int]?

    /// Cached transitive closure of dependency edges. Computed on first access via ``computeReachability()``, invalidated by ``invalidateTopologicalCaches()``.
    private var _reachability: [Int: Set<Int>]?

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

    /// Node IDs in dependency order (roots first). Computed via Kahn's algorithm on dependency edges. Cached until ``invalidateTopologicalCaches()`` clears it.
    public var topologicalOrder: [Int] {
        if let cached = _topologicalOrder { return cached }
        let computed = computeTopologicalOrder()
        _topologicalOrder = computed
        return computed
    }

    /// Transitive closure of dependency edges. `reachability[i]` contains all node IDs reachable from node `i`. Cached until ``invalidateTopologicalCaches()`` clears it.
    public var reachability: [Int: Set<Int>] {
        if let cached = _reachability { return cached }
        let computed = computeReachability()
        _reachability = computed
        return computed
    }

    /// Drops cached type-compatibility edges, source/sink annotations, and convergence data on leaf nodes, forcing recomputation on next access.
    func invalidateDerivedEdges() {
        _typeCompatibilityEdges = nil
        _sourceSinkStatus = nil
        clearConvergenceData()
    }

    /// Drops cached topological order and reachability, forcing recomputation on next access. Called by in-place mutations that add or remove dependency edges (bind subtree rebuilds, branch pivots). Layer 1 introduces this hook; no Layer 1 call site invokes it because Layer 1 does not mutate the graph.
    func invalidateTopologicalCaches() {
        _topologicalOrder = nil
        _reachability = nil
    }

    /// Writes convergence records from an encoder pass onto the corresponding leaf nodes.
    ///
    /// - Parameter records: Map from flat sequence index to the convergence floor at that position.
    func recordConvergence(_ records: [Int: ConvergedOrigin]) {
        for (sequenceIndex, origin) in records {
            guard let nodeIndex = nodes.firstIndex(where: { node in
                guard isTombstoned(node.id) == false else { return false }
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
            guard isTombstoned(index) == false else { continue }
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
        selfSimilarityEdges: [SelfSimilarityEdge]
    ) {
        self.nodes = nodes
        self.containmentEdges = containmentEdges
        self.dependencyEdges = dependencyEdges
        self.selfSimilarityEdges = selfSimilarityEdges
    }

    // MARK: - Copy

    /// Returns a structurally independent clone with all field state shared via Swift's COW semantics.
    ///
    /// All stored properties are value types (arrays, sets, dictionaries, optionals of those), so the copy is `O(1)` until any subsequent mutation triggers COW on the touched buffer. Used by composed encoders that need to preview a speculative mutation against a throwaway graph — for example, the kleisli composition lift closure that applies a bind reshape on a copy via ``apply(_:freshTree:)`` instead of paying the cost of a full ``ChoiceGraph/build(from:)`` rebuild.
    ///
    /// The cached lazy fields (``_typeCompatibilityEdges``, ``_sourceSinkStatus``, ``_topologicalOrder``, ``_reachability``) are also carried over. Any subsequent mutation that calls ``invalidateDerivedEdges()`` or ``invalidateTopologicalCaches()`` on the copy drops them on the copy alone, leaving the parent's caches intact via COW.
    func copy() -> ChoiceGraph {
        let result = ChoiceGraph(
            nodes: nodes,
            containmentEdges: containmentEdges,
            dependencyEdges: dependencyEdges,
            selfSimilarityEdges: selfSimilarityEdges
        )
        result.removedNodeIDs = removedNodeIDs
        result._typeCompatibilityEdges = _typeCompatibilityEdges
        result._sourceSinkStatus = _sourceSinkStatus
        result._topologicalOrder = _topologicalOrder
        result._reachability = _reachability
        return result
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

// MARK: - Lazy Edge Computation

extension ChoiceGraph {
    /// Computes type-compatibility edges from the current node state.
    ///
    /// Creates an edge between any two antichain-independent active `chooseBits` leaves whose values are numeric (integer or floating-point). Same-tag pairs carry their shared ``TypeTag``; cross-type numeric pairs (for example float ↔ int) carry nil. The encoder differentiates same-tag from cross-type using the leaf metadata at dispatch time.
    private func computeTypeCompatibilityEdges() -> [TypeCompatibilityEdge] {
        var numericLeafIDs: [Int] = []
        var leafTags: [Int: TypeTag] = [:]
        for node in nodes {
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            // All chooseBits leaves are numeric in this framework (integer or float).
            numericLeafIDs.append(node.id)
            leafTags[node.id] = metadata.typeTag
        }
        guard numericLeafIDs.count >= 2 else { return [] }

        var edges: [TypeCompatibilityEdge] = []
        var indexA = 0
        while indexA < numericLeafIDs.count {
            var indexB = indexA + 1
            while indexB < numericLeafIDs.count {
                let nodeA = numericLeafIDs[indexA]
                let nodeB = numericLeafIDs[indexB]
                if areIndependent(nodeA, nodeB) {
                    let tagA = leafTags[nodeA]
                    let tagB = leafTags[nodeB]
                    let sharedTag: TypeTag? = (tagA == tagB) ? tagA : nil
                    edges.append(TypeCompatibilityEdge(
                        nodeA: nodeA,
                        nodeB: nodeB,
                        typeTag: sharedTag
                    ))
                }
                indexB += 1
            }
            indexA += 1
        }
        return edges
    }

    /// Computes source/sink annotations from current leaf values.
    private func computeSourceSinkAnnotations() -> [Int: SourceSinkStatus] {
        var status: [Int: SourceSinkStatus] = [:]
        for node in nodes {
            guard isTombstoned(node.id) == false else { continue }
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            let isZero = metadata.value.bitPattern64 == 0
            status[node.id] = isZero ? .sink : .source
        }
        return status
    }

    /// Computes topological order over dependency edges via Kahn's algorithm.
    ///
    /// Returns node IDs in dependency order (roots first). Only nodes that appear in dependency edges are included. Mirrors the prior implementation in ``ChoiceGraphBuilder`` so that the lazy computed property produces the same result the eager constructor used to.
    ///
    /// - Complexity: O(*V* + *E*) where *V* is the node count and *E* is the dependency edge count.
    private func computeTopologicalOrder() -> [Int] {
        let nodeCount = nodes.count
        var inDegree = [Int](repeating: 0, count: nodeCount)
        var adjacency = [[Int]](repeating: [], count: nodeCount)
        for edge in dependencyEdges {
            adjacency[edge.source].append(edge.target)
            inDegree[edge.target] += 1
        }

        // Only include nodes that participate in dependency relationships.
        var participatingNodes = Set<Int>()
        for edge in dependencyEdges {
            participatingNodes.insert(edge.source)
            participatingNodes.insert(edge.target)
        }

        var queue: [Int] = []
        for nodeID in participatingNodes where inDegree[nodeID] == 0 {
            queue.append(nodeID)
        }

        var order: [Int] = []
        order.reserveCapacity(participatingNodes.count)
        var front = 0

        while front < queue.count {
            let current = queue[front]
            front += 1
            order.append(current)
            for dependent in adjacency[current] {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }
        return order
    }

    /// Computes the transitive closure of dependency edges via reverse topological propagation.
    ///
    /// `result[i]` contains all node IDs reachable from node `i` via one or more dependency edges. Mirrors the prior implementation in ``ChoiceGraphBuilder``.
    ///
    /// - Complexity: O(*V* · *E*) time, O(*V*²) space in the worst case.
    fileprivate func computeReachability() -> [Int: Set<Int>] {
        let nodeCount = nodes.count
        var adjacency = [[Int]](repeating: [], count: nodeCount)
        for edge in dependencyEdges {
            adjacency[edge.source].append(edge.target)
        }

        var result = [Int: Set<Int>]()
        for nodeID in topologicalOrder.reversed() {
            var reachable = Set<Int>()
            for dependent in adjacency[nodeID] {
                reachable.insert(dependent)
                if let transitive = result[dependent] {
                    reachable.formUnion(transitive)
                }
            }
            if reachable.isEmpty == false {
                result[nodeID] = reachable
            }
        }
        return result
    }
}
