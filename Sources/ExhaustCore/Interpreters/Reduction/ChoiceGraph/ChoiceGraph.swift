//
//  ChoiceGraph.swift
//  Exhaust
//

// MARK: - Choice Graph

/// A layered multigraph representing the generator's value structure for reduction.
///
/// Built from a ``ChoiceTree`` and its flattened ``ChoiceSequence`` via ``ChoiceGraphBuilder``. Captures six node types (chooseBits, pick, bind, zip, sequence, just) and four edge layers (dependency, containment, self-similarity, type-compatibility).
///
/// ## Edge Layers
///
/// - **Dependency** (directed): bind-inner → bound content. Ordering constraint — parent before child. Topological sort and reachability operate here.
/// - **Containment** (directed, no ordering constraint): parent → child in the tree. Defines independence structure for antichain computation.
/// - **Self-similarity** (undirected): between active pick nodes with matching fingerprint. Substitution candidates.
/// - **Type-compatibility** (undirected): between antichain members with compatible types. Redistribution candidates. Computed on demand as a non-caching computed property.
///
/// ## Lifecycle
///
/// Rebuilt from the tree on every structural acceptance. All derived data (live node IDs, leaf nodes, topological order, dependency adjacency) is computed eagerly during ``ChoiceGraphBuilder/assembleGraph()`` and stored as immutable fields. Infrequently-accessed derived data (type-compatibility edges, source/sink status, bind-inner descendant index) is recomputed on each access without caching.
///
/// Value-only leaf changes (no reshape) are applied in place via ``apply(_:freshTree:)`` without rebuilding. Structural mutations return ``ChangeApplication/requiresFullRebuild`` true, delegating the rebuild to the scheduler.
///
/// ## File Layout
///
/// This file holds the struct definition, eagerly-computed fields, the convergence-record helpers, and the init/build plumbing. Read-only graph queries live in `ChoiceGraph+Queries.swift`. Computation functions for non-eagerly-derived data live in `ChoiceGraph+LazyComputation.swift`. The mutation entry point (`apply`) lives in `ChoiceGraph+Lifecycle.swift`. Per-scope query families each have their own `ChoiceGraph+*Scopes.swift`.
///
/// - SeeAlso: ``ChoiceGraphBuilder``, ``ChoiceGraphNode``, ``DependencyEdge``, ``ContainmentEdge``, ``SelfSimilarityEdge``, ``TypeCompatibilityEdge``
package struct ChoiceGraph {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``.
    public var nodes: [ChoiceGraphNode]

    /// Containment edges forming the tree structure (parent → child).
    public let containmentEdges: [ContainmentEdge]

    /// Dependency edges from bind-inner nodes to structural nodes in their bound subtrees.
    public let dependencyEdges: [DependencyEdge]

    /// Active pick nodes grouped by fingerprint. Picks in the same group are structurally exchangeable — any pair is a candidate for self-similar replacement. Stored as a group index (O(P) space) instead of a materialized all-pairs edge array (O(P^2) space). Consumers derive edges on demand from the group members' position ranges.
    public let selfSimilarityGroups: [UInt64: [Int]]

    /// IDs of active nodes (those with non-nil position ranges). Computed eagerly during graph assembly.
    public let liveNodeIDs: [Int]

    /// All leaf node IDs (chooseBits nodes with non-nil position range). Computed eagerly during graph assembly.
    public let leafNodes: [Int]

    /// Node IDs in dependency order (roots first). Computed eagerly via Kahn's algorithm during graph assembly.
    public let topologicalOrder: [Int]

    /// Dependency adjacency list for on-demand reachability queries. Computed eagerly during graph assembly.
    let dependencyAdjacency: [[Int]]

    var graphStats = ChoiceGraphStats()

    /// Cached classification verdicts keyed by `BindMetadata.fingerprint`. Survives full graph rebuilds via ``build(from:inheriting:observations:)`` because the fingerprint is derived from the originating `.bind` source location, which is stable for the program's lifetime — the same source location always produces the same closure shape, so the verdict is invariant under graph rebuilds. Read by the scheduler before dispatching expensive dependent-node encoders so a previously-classified bind site does not re-pay the two materializations that ``classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)`` would otherwise run.
    var bindClassifications: [UInt64: BindClassification] = [:]

    /// Last-observed upstream bit pattern and downstream topology fingerprint per bind site. Keyed by `BindMetadata.fingerprint`. Survives rebuilds so the scheduler can passively classify binds by comparing topology across natural upstream variation without materialisation probes.
    var bindTopologyObservations: [UInt64: BindTopologyObservation] = [:]

    // MARK: - Non-Caching Computed Properties

    /// Type-compatibility edges between antichain members with matching types. Recomputed on each access.
    public var typeCompatibilityEdges: [TypeCompatibilityEdge] {
        computeTypeCompatibilityEdges()
    }

    /// Bind-inner descendant index. Maps each chooseBits leaf inside a bind's inner subtree to the outermost enclosing bind's node ID. Recomputed on each access.
    public var innerDescendantToBind: [Int: Int] {
        QueryHelpers.buildInnerDescendantToBind(graph: self)
    }

    /// Per-node source/sink status for redistribution. Recomputed on each access.
    public var sourceSinkStatus: [Int: SourceSinkStatus] {
        computeSourceSinkAnnotations()
    }

    /// Writes convergence records from an encoder pass onto the corresponding leaf nodes by sequence position.
    ///
    /// Used by ``ChoiceGraphScheduler/transferConvergence(_:to:)`` after a full ``ChoiceGraph/build(from:)`` rebuild, where node IDs are not stable across the rebuild and positional matching is the only option. Within a single graph instance, encoders use the cheaper ``recordConvergence(byNodeID:)`` overload instead.
    ///
    /// - Complexity: O(N + R) where N is the node count and R is the record count. Builds a position-to-index lookup table once in O(N), then resolves each record in O(1).
    /// - Parameter records: Map from flat sequence index to the convergence floor at that position.
    mutating func recordConvergence(_ records: [Int: ConvergedOrigin]) {
        guard records.isEmpty == false else { return }

        var positionToIndex: [Int: Int] = [:]
        positionToIndex.reserveCapacity(records.count)
        for nodeID in liveNodeIDs {
            guard case .chooseBits = nodes[nodeID].kind else { continue }
            guard let position = nodes[nodeID].positionRange?.lowerBound else { continue }
            positionToIndex[position] = nodeID
        }

        for (sequenceIndex, origin) in records {
            guard let nodeIndex = positionToIndex[sequenceIndex] else { continue }
            guard case var .chooseBits(metadata) = nodes[nodeIndex].kind else { continue }
            metadata.convergedOrigin = origin
            nodes[nodeIndex] = nodes[nodeIndex].with(kind: .chooseBits(metadata))
        }
    }

    /// Writes convergence records from an encoder pass onto leaf nodes by node ID.
    ///
    /// Preferred over ``recordConvergence(_:)`` for harvesting from encoders within a single graph instance: node IDs are stable and the lookup is O(1) per record instead of O(N) per record (the positional version walks every node looking for a position match). Encoders' internal `convergenceStore` is keyed by node ID so that records survive in-pass position shifts triggered by ``GraphEncoder/refreshState(graph:sequence:)``.
    ///
    /// - Parameter records: Map from graph node ID to the convergence floor at that node's leaf.
    mutating func recordConvergence(byNodeID records: [Int: ConvergedOrigin]) {
        for (nodeID, origin) in records {
            guard nodeID < nodes.count else { continue }
            guard case var .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            metadata.convergedOrigin = origin
            nodes[nodeID] = nodes[nodeID].with(kind: .chooseBits(metadata))
        }
    }
}

// MARK: - Construction

package extension ChoiceGraph {
    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. Type-compatibility edges and source/sink annotations are deferred until first access.
    ///
    /// - Parameter tree: The generator's compositional structure.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        ChoiceGraphBuilder.build(from: tree)
    }

    /// Builds a ``ChoiceGraph`` from a tree, inheriting classification and observation caches.
    ///
    /// Used after a structural rebuild when the scheduler wants to preserve previously-computed bind classifications and topology observations across the rebuild. Cache keys are ``BindMetadata/fingerprint`` values (per-source-location hashes), so they remain valid for the rebuilt graph as long as the underlying generator has not changed — the same `.bind` source location always produces a bind node with the same fingerprint, regardless of where in the rebuilt graph it appears.
    ///
    /// - Parameters:
    ///   - tree: The generator's compositional structure.
    ///   - cachedClassifications: Map from `BindMetadata.fingerprint` to a previously-computed ``BindClassification``. Typically the previous graph's ``bindClassifications`` field.
    ///   - cachedObservations: Map from `BindMetadata.fingerprint` to the last-seen topology observation. Typically the previous graph's ``bindTopologyObservations`` field.
    static func build(
        from tree: ChoiceTree,
        inheriting cachedClassifications: [UInt64: BindClassification],
        observations cachedObservations: [UInt64: BindTopologyObservation]
    ) -> ChoiceGraph {
        var graph = ChoiceGraphBuilder.build(from: tree)
        graph.bindClassifications = cachedClassifications
        graph.bindTopologyObservations = cachedObservations
        return graph
    }
}
