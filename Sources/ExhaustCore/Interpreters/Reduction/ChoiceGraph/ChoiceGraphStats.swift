//
//  ChoiceGraphStats.swift
//  Exhaust
//

/// Statistics collected during ``ChoiceGraph`` construction and lifecycle operations.
///
/// Accumulated by the builder during construction and updated by lifecycle methods. Gate logging on `isInstrumented` using the existing ``ExhaustLog`` pattern.
public struct ChoiceGraphStats: Sendable {
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

    /// Number of sequence-element nodes in the deletion antichain at initial graph construction.
    public var deletionAntichainSize: Int

    /// Number of full ``ChoiceGraph/build(from:)`` rebuilds triggered by structural acceptances during reduction.
    public var fullGraphRebuilds: Int

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
        deletionAntichainSize = 0
        fullGraphRebuilds = 0
    }

    /// Populates construction-time stats from a ``ChoiceGraph``.
    public static func from(_ graph: ChoiceGraph) -> ChoiceGraphStats {
        var stats = ChoiceGraphStats()
        stats.nodeCount = graph.nodes.count
        stats.dependencyEdgeCount = graph.dependencyEdges.count
        stats.containmentEdgeCount = graph.containmentEdges.count
        stats.selfSimilarityEdgeCount = graph.selfSimilarityGroups.values.reduce(0) { total, group in
            total + group.count * (group.count - 1) / 2
        }
        stats.typeCompatibilityEdgeCount = graph.typeCompatibilityEdges.count
        stats.activeNodeCount = graph.nodes.count(where: { $0.positionRange != nil })
        stats.inactiveNodeCount = graph.nodes.count(where: { $0.positionRange == nil })
        stats.deletionAntichainSize = graph.deletionAntichain.count
        return stats
    }
}
