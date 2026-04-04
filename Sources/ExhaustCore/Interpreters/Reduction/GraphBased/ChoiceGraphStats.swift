//
//  ChoiceGraphStats.swift
//  Exhaust
//

/// Statistics collected during ``ChoiceGraph`` construction and lifecycle operations.
///
/// Accumulated by the builder during construction and updated by lifecycle methods. Gate logging on `isInstrumented` using the existing ``ExhaustLog`` pattern.
public struct ChoiceGraphStats {
    /// Total node count in the graph (all kinds, active and inactive).
    public var nodeCount: Int

    /// Edge count per layer: dependency, containment, self-similarity, type-compatibility.
    public var dependencyEdgeCount: Int
    public var containmentEdgeCount: Int
    public var selfSimilarityEdgeCount: Int
    public var typeCompatibilityEdgeCount: Int

    /// Number of active (non-nil position range) nodes.
    public var activeNodeCount: Int

    /// Number of inactive (nil position range) nodes.
    public var inactiveNodeCount: Int

    /// Number of dynamic region rebuilds since graph construction.
    public var dynamicRegionRebuilds: Int

    /// Total nodes rebuilt across all dynamic region rebuilds.
    public var dynamicRegionNodesRebuilt: Int

    /// Creates empty stats.
    public init() {
        nodeCount = 0
        dependencyEdgeCount = 0
        containmentEdgeCount = 0
        selfSimilarityEdgeCount = 0
        typeCompatibilityEdgeCount = 0
        activeNodeCount = 0
        inactiveNodeCount = 0
        dynamicRegionRebuilds = 0
        dynamicRegionNodesRebuilt = 0
    }

    /// Populates construction-time stats from a ``ChoiceGraph``.
    public static func from(_ graph: ChoiceGraph) -> ChoiceGraphStats {
        var stats = ChoiceGraphStats()
        stats.nodeCount = graph.nodes.count
        stats.dependencyEdgeCount = graph.dependencyEdges.count
        stats.containmentEdgeCount = graph.containmentEdges.count
        stats.selfSimilarityEdgeCount = graph.selfSimilarityEdges.count
        stats.typeCompatibilityEdgeCount = graph.typeCompatibilityEdges.count
        stats.activeNodeCount = graph.nodes.filter { $0.positionRange != nil }.count
        stats.inactiveNodeCount = graph.nodes.filter { $0.positionRange == nil }.count
        return stats
    }
}
