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
/// ## File Layout
///
/// This file holds the class definition, lazy cache state, invalidation hooks, the convergence-record helpers, and the copy / init plumbing. Read-only graph queries (dependency, containment, bind, self-similarity, structural fingerprint) live in `ChoiceGraph+Queries.swift`. The on-demand computation that backs the lazy caches lives in `ChoiceGraph+LazyComputation.swift`. Mutation entry points (`apply`, `applyBindReshape`, dynamic rebuild) live in `ChoiceGraph+Lifecycle.swift` and its sibling files. Per-scope query families (removal, replacement, minimization, exchange, permutation) each have their own `ChoiceGraph+*Scopes.swift`.
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
    /// - Complexity: O(N + R) where N is the node count and R is the record count. Builds a position-to-index lookup table once in O(N), then resolves each record in O(1).
    /// - Parameter records: Map from flat sequence index to the convergence floor at that position.
    func recordConvergence(_ records: [Int: ConvergedOrigin]) {
        guard records.isEmpty == false else { return }

        // Build position → node-array-index lookup once in O(N).
        var positionToIndex: [Int: Int] = [:]
        positionToIndex.reserveCapacity(records.count)
        for index in nodes.indices {
            guard isTombstoned(index) == false else { continue }
            guard case .chooseBits = nodes[index].kind else { continue }
            guard let position = nodes[index].positionRange?.lowerBound else { continue }
            positionToIndex[position] = index
        }

        for (sequenceIndex, origin) in records {
            guard let nodeIndex = positionToIndex[sequenceIndex] else { continue }
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
        let graph = ChoiceGraphBuilder.build(from: tree)
        #if DEBUG
        graph.assertLeafPositionsValid(in: ChoiceSequence(tree), label: "build")
        #endif
        return graph
    }

    #if DEBUG
    /// Validates that every `chooseBits` node's position range points to a value entry in the sequence. Fires a fatal error with diagnostic context on the first mismatch.
    func assertLeafPositionsValid(in sequence: ChoiceSequence, label: String) {
        for node in nodes {
            guard case .chooseBits = node.kind else { continue }
            guard let range = node.positionRange else { continue }
            let position = range.lowerBound
            guard position < sequence.count else {
                fatalError("[\(label)] chooseBits node \(node.id) positionRange \(range) exceeds sequence length \(sequence.count)")
            }
            guard sequence[position].value != nil else {
                fatalError("[\(label)] chooseBits node \(node.id) at position \(position) points to non-value entry: \(sequence[position])")
            }
        }
    }
    #endif
}
