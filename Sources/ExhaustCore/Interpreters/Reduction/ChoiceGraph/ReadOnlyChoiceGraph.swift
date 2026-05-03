//
//  ReadOnlyChoiceGraph.swift
//  Exhaust
//

// MARK: - Read-Only Choice Graph

/// Read-only view of a ``ChoiceGraph`` for consumers that inspect but never mutate graph state.
///
/// Encoders, scope queries, scope sources, and the transformation enumerator all receive the graph through this protocol. The scheduler retains the concrete ``ChoiceGraph`` for mutation (``ChoiceGraph/apply(_:freshTree:)``, ``ChoiceGraph/classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)``, convergence recording, and full rebuilds). This separation enforces at compile time what was previously a documented convention: encoders read from the graph but never mutate it.
protocol ReadOnlyChoiceGraph {
    /// All nodes in the graph, indexed by ``ChoiceGraphNode/id``.
    var nodes: [ChoiceGraphNode] { get }

    /// Active pick nodes grouped by fingerprint for self-similar replacement.
    var selfSimilarityGroups: [UInt64: [Int]] { get }

    /// Type-compatibility edges between antichain members with matching types.
    var typeCompatibilityEdges: [TypeCompatibilityEdge] { get }

    /// Maximum antichain over deletable structural boundary nodes.
    var deletionAntichain: [Int] { get }

    /// Whether two nodes are independent (no dependency path between them in either direction).
    func areIndependent(_ nodeA: Int, _ nodeB: Int) -> Bool

    /// Whether `target` is reachable from `source` via one or more dependency edges.
    func isReachable(from source: Int, to target: Int) -> Bool
}

extension ChoiceGraph: ReadOnlyChoiceGraph {}
