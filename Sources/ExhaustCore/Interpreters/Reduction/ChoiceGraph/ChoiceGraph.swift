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
/// Rebuilt from the tree on every structural acceptance. All derived data (live node IDs, leaf nodes, topological order, dependency adjacency) is computed eagerly during ``ChoiceGraphBuilder/assembleGraph()`` and stored as immutable fields. Infrequently-accessed derived data (type-compatibility edges) is recomputed on each access without caching.
///
/// Value-only leaf changes (no reshape) are applied in place via ``apply(_:freshTree:)`` without rebuilding. Structural mutations return ``ChangeApplication/requiresFullRebuild`` true, delegating the rebuild to the scheduler.
///
/// ## File Layout
///
/// This file holds the struct definition, eagerly-computed fields, the convergence-record helpers, and the init/build plumbing. Read-only graph queries live in `ChoiceGraph+Queries.swift`. Computation functions for non-eagerly-derived data live in `ChoiceGraph+LazyComputation.swift`. The mutation entry point (`apply`) lives in `ChoiceGraph+Lifecycle.swift`. Per-scope query families each have their own `ChoiceGraph+*Scopes.swift`.
///
/// - SeeAlso: ``ChoiceGraphBuilder``, ``ChoiceGraphNode``, ``DependencyEdge``, ``ContainmentEdge``, ``TypeCompatibilityEdge``
package struct ChoiceGraph {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``.
    package var nodes: [ChoiceGraphNode]

    /// Containment edges forming the tree structure (parent → child).
    package let containmentEdges: [ContainmentEdge]

    /// Dependency edges from bind-inner nodes to structural nodes in their bound subtrees.
    package let dependencyEdges: [DependencyEdge]

    /// Active pick nodes grouped by fingerprint. Picks in the same group are structurally exchangeable — any pair is a candidate for self-similar replacement. Stored as a group index (O(P) space) instead of a materialized all-pairs edge array (O(P^2) space). Consumers derive edges on demand from the group members' position ranges.
    package let selfSimilarityGroups: [UInt64: [Int]]

    /// IDs of active nodes (those with non-nil position ranges). Computed eagerly during graph assembly.
    package let liveNodeIDs: [Int]

    /// All leaf node IDs (chooseBits nodes with non-nil position range). Computed eagerly during graph assembly.
    package let leafNodes: [Int]

    /// Node IDs in dependency order (roots first). Computed eagerly via Kahn's algorithm during graph assembly.
    package let topologicalOrder: [Int]

    /// Dependency adjacency list for on-demand reachability queries. Computed eagerly during graph assembly.
    let dependencyAdjacency: [[Int]]

    var graphStats = ChoiceGraphStats()

    /// Cached classification verdicts keyed by `BindMetadata.fingerprint`. Survives full graph rebuilds via ``build(from:inheriting:observations:)`` because the fingerprint is derived from the originating `.bind` source location, which is stable for the program's lifetime — the same source location always produces the same closure shape, so the verdict is invariant under graph rebuilds. Read by the scheduler before dispatching expensive dependent-node encoders so a previously-classified bind site does not re-pay the two materializations that ``classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)`` would otherwise run.
    var bindClassifications: [UInt64: BindClassification] = [:]

    /// Last-observed upstream bit pattern and downstream topology fingerprint per bind site. Keyed by `BindMetadata.fingerprint`. Survives rebuilds so the scheduler can passively classify binds by comparing topology across natural upstream variation without materialisation probes.
    var bindTopologyObservations: [UInt64: BindTopologyObservation] = [:]

    /// Convergence records from prior encoder passes, keyed by graph node ID. Each entry records the bound at which a value search converged for a leaf, its signal, and the cycle number. Stored at graph level rather than per-node because convergence is reduction-session state, not structural metadata — it must survive value-only graph updates without per-node copy overhead.
    ///
    /// Written by ``recordConvergence(byNodeID:)`` after encoder passes and transferred across full rebuilds by ``ChoiceGraphScheduler/transferConvergence(_:to:)``. Read by ``MinimizationQuery`` (skip converged leaves), ``ChoiceGraphScheduler/allValuesConverged(in:graph:)`` (termination check), and ``ChoiceGraphScheduler/extractWarmStarts(from:)`` (encoder warm-start input). Cleared per-leaf by ``clearConvergence(_:)`` when staleness probing detects an invalid floor, and in bulk by ``clearConvergence(inPositionRange:)`` for bound subtree regions after reshape.
    package var convergenceStore: [Int: ConvergedOrigin] = [:]

    // MARK: - Non-Caching Computed Properties

    /// Type-compatibility edges between antichain members with matching types. Recomputed on each access.
    package var typeCompatibilityEdges: [TypeCompatibilityEdge] {
        computeTypeCompatibilityEdges()
    }

    /// Writes convergence records from an encoder pass into the store by node ID.
    ///
    /// - Parameter records: Map from graph node ID to the convergence floor at that node's leaf.
    mutating func recordConvergence(byNodeID records: [Int: ConvergedOrigin]) {
        for (nodeID, origin) in records {
            guard nodeID < nodes.count else { continue }
            guard case .chooseBits = nodes[nodeID].kind else { continue }
            convergenceStore[nodeID] = origin
        }
    }

    /// Clears the convergence record for a single leaf node.
    mutating func clearConvergence(_ nodeID: Int) {
        convergenceStore.removeValue(forKey: nodeID)
    }

    /// Clears convergence records for all leaf nodes whose position falls within the given range.
    mutating func clearConvergence(inPositionRange range: ClosedRange<Int>) {
        for nodeID in leafNodes {
            guard let nodeRange = nodes[nodeID].positionRange else { continue }
            guard range.contains(nodeRange.lowerBound) else { continue }
            convergenceStore.removeValue(forKey: nodeID)
        }
    }
}

// MARK: - Construction

package extension ChoiceGraph {
    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. Type-compatibility edges are deferred until first access.
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
