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

    /// Writes convergence records from an encoder pass onto the corresponding leaf nodes by sequence position.
    ///
    /// Used by ``ChoiceGraphScheduler/transferConvergence(_:to:)`` after a full ``ChoiceGraph/build(from:)`` rebuild, where node IDs are not stable across the rebuild and positional matching is the only option. Within a single graph instance, encoders use the cheaper ``recordConvergence(byNodeID:)`` overload instead.
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

    /// Writes convergence records from an encoder pass onto leaf nodes by node ID.
    ///
    /// Preferred over ``recordConvergence(_:)`` for harvesting from encoders within a single graph instance: node IDs are stable and the lookup is O(1) per record instead of O(N) per record (the positional version walks every node looking for a position match). Encoders' internal `convergenceStore` is keyed by node ID so that records survive in-pass position shifts triggered by ``GraphEncoder/refreshScope(graph:sequence:)``.
    ///
    /// - Parameter records: Map from graph node ID to the convergence floor at that node's leaf.
    func recordConvergence(byNodeID records: [Int: ConvergedOrigin]) {
        for (nodeID, origin) in records {
            guard nodeID < nodes.count else { continue }
            guard isTombstoned(nodeID) == false else { continue }
            guard case var .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            metadata.convergedOrigin = origin
            nodes[nodeID] = ChoiceGraphNode(
                id: nodes[nodeID].id,
                kind: .chooseBits(metadata),
                positionRange: nodes[nodeID].positionRange,
                children: nodes[nodeID].children,
                parent: nodes[nodeID].parent
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

// MARK: - Lazy Edge Computation

extension ChoiceGraph {
    /// Computes type-compatibility edges grouped by parent decision context.
    ///
    /// Redistribution moves value mass between two leaves within a single decision context. Two structural cases qualify:
    ///
    /// 1. **Sequence siblings** — chooseBits children of the same sequence parent. The classic intra-array case (e.g., redistributing values across the elements of a single `array(of: Int)` instance).
    /// 2. **Zip cross-slot** — chooseBits descendants of *different* children of a common zip parent. Tuple slots are simultaneously chosen and the property frequently correlates their values; redistribution between them is the only way to shrink to a coupled extremum. Bound5's `d + e == −32769` constraint is the canonical example: the canonical counterexample `Bound5(d: [-32768], e: [-1])` is reachable from intermediate states like `Bound5(d: [-17296], e: [-15473])` only by moving magnitude between `d`'s leaf and `e`'s leaf, which are not siblings of any sequence but are cross-slot under the Bound5 tuple.
    ///
    /// Cross-parent pairs whose lowest common ancestor is a sequence (the elements of a `[[Int]]` workload) are *not* generated. Sequence elements are independently chosen and the property treats them as independent decision contexts; cross-element redistribution produces no shrinking-meaningful candidates and balloons the edge count quadratically for high-fanout sequences.
    ///
    /// ## Complexity
    ///
    /// Pass 1 (sequence parents) is Σ over sequence parents of O(C²) where C is each parent's chooseBits child count. Pass 2 (zip parents) is Σ over zip parents of (Σᵢ⁢ⱼ Lᵢ · Lⱼ) where Lᵢ is the chooseBits-leaf count under the i-th zip child.
    ///
    /// For NestedLists pathological (99 sub-arrays of ~50 leaves each, no zip in the leaf path): 99 · C(50, 2) ≈ 121K edges from pass 1, zero from pass 2. For Bound5 (5 small arrays under one zip): a handful of pass-1 edges plus the 5×5 cross-slot grid from pass 2. For Coupling (single int + bound array, no zip): a handful of pass-1 edges from the bound array, zero from pass 2.
    ///
    /// The previous flat-leaf implementation iterated all numeric leaves and paired every pair via `areIndependent` plus a type check. For workloads with no binds every pair was independent, so the result was the complete graph K(L) with one allocation per pair — 11.4 million edges per source rebuild for NestedLists pathological. This implementation avoids that by structuring the iteration around the actual decision contexts.
    private func computeTypeCompatibilityEdges() -> [TypeCompatibilityEdge] {
        var edges: [TypeCompatibilityEdge] = []

        // Pass 1: chooseBits siblings under each sequence parent.
        for parentNode in nodes {
            guard parentNode.positionRange != nil else { continue }
            guard case .sequence = parentNode.kind else { continue }

            var siblings: [(nodeID: Int, tag: TypeTag)] = []
            siblings.reserveCapacity(parentNode.children.count)
            for childID in parentNode.children {
                guard childID < nodes.count else { continue }
                let child = nodes[childID]
                guard child.positionRange != nil else { continue }
                guard case let .chooseBits(metadata) = child.kind else { continue }
                siblings.append((nodeID: childID, tag: metadata.typeTag))
            }
            guard siblings.count >= 2 else { continue }

            // Within-parent sibling pairs. Pairs may be same-tag (homogeneous
            // arrays) or mixed-tag (sequence of `.oneOf(Int, Float)`); the
            // encoder differentiates at dispatch time via the `typeTag` field.
            var indexA = 0
            while indexA < siblings.count {
                var indexB = indexA + 1
                while indexB < siblings.count {
                    let tagA = siblings[indexA].tag
                    let tagB = siblings[indexB].tag
                    let sharedTag: TypeTag? = (tagA == tagB) ? tagA : nil
                    edges.append(TypeCompatibilityEdge(
                        nodeA: siblings[indexA].nodeID,
                        nodeB: siblings[indexB].nodeID,
                        typeTag: sharedTag
                    ))
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Pass 2: chooseBits descendants across different children of each zip parent.
        // Tuple slots are simultaneously chosen, so cross-slot value pairs are
        // semantically meaningful redistribution candidates (Bound5's d + e
        // coupling). Within-slot pairs are skipped here because they were
        // (or will be) generated by pass 1 against the appropriate sequence
        // parent inside that slot.
        for zipNode in nodes {
            guard zipNode.positionRange != nil else { continue }
            guard case .zip = zipNode.kind else { continue }
            guard zipNode.children.count >= 2 else { continue }

            // Collect leaves per zip child via a containment-tree walk.
            var perChildLeaves: [[(nodeID: Int, tag: TypeTag)]] = []
            perChildLeaves.reserveCapacity(zipNode.children.count)
            for childID in zipNode.children {
                var leaves: [(nodeID: Int, tag: TypeTag)] = []
                collectChooseBitsDescendants(rootID: childID, into: &leaves)
                perChildLeaves.append(leaves)
            }

            // Pair leaves across different child groups only.
            var groupA = 0
            while groupA < perChildLeaves.count {
                var groupB = groupA + 1
                while groupB < perChildLeaves.count {
                    for leafA in perChildLeaves[groupA] {
                        for leafB in perChildLeaves[groupB] {
                            let sharedTag: TypeTag? = (leafA.tag == leafB.tag) ? leafA.tag : nil
                            edges.append(TypeCompatibilityEdge(
                                nodeA: leafA.nodeID,
                                nodeB: leafB.nodeID,
                                typeTag: sharedTag
                            ))
                        }
                    }
                    groupB += 1
                }
                groupA += 1
            }
        }

        return edges
    }

    /// Walks the containment tree under `rootID` and appends every active chooseBits descendant to `result`. Used by ``computeTypeCompatibilityEdges()`` to gather leaves per zip child for cross-slot pairing.
    private func collectChooseBitsDescendants(
        rootID: Int,
        into result: inout [(nodeID: Int, tag: TypeTag)]
    ) {
        guard rootID < nodes.count else { return }
        let node = nodes[rootID]
        guard node.positionRange != nil else { return }
        if case let .chooseBits(metadata) = node.kind {
            result.append((nodeID: rootID, tag: metadata.typeTag))
        }
        for childID in node.children {
            collectChooseBitsDescendants(rootID: childID, into: &result)
        }
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
