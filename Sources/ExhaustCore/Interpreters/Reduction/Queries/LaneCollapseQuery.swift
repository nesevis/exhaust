/// Builds a minimization scope containing only ``TypeTag/laneControl`` chooseBits leaves.
///
/// Lane-control leaves encode which concurrent lane a command is assigned to in a spec test. Value 0 means sequential prefix (the command runs before any concurrent execution); non-zero values assign to concurrent lanes. The goal is to establish the maximal sequential prefix by moving as many commands as possible from concurrent lanes into the prefix.
///
/// ## Strategy
///
/// Lane collapse is a binary decision per command: either it moves to the prefix (value becomes 0) or it stays on its lane. Intermediate lane values are never attempted — reducing lane 3 to lane 2 does not help because it keeps the command in the concurrent interleaving space regardless. The encoder should probe zero for each leaf and accept or reject. No binary search, no interpolation.
///
/// Leaves are ordered by sequence position (front of the array first) so the prefix grows from the beginning of the command sequence. This produces the canonical `[0, 0, 0, X, Y, X]` ordering where all prefix commands are contiguous at the front.
///
/// ## Relationship to Other Queries
///
/// ``MinimizationQuery``, ``ExchangeQuery``, ``PermutationQuery``, and ``ReorderingQuery`` all exclude lane-control leaves via the ``ScopeAnnotation/isLaneControl`` flag. This query is the complement: it operates *only* on lane-control leaves. The ``EncoderName/laneCollapse`` name allows the ``ReducerConfiguration/enabledEncoders`` filter to run lane collapse as an isolated pass before structural or value reduction.
enum LaneCollapseQuery {
    static func build(graph: ChoiceGraph) -> MinimizationScope? {
        var entries: [(position: Int, entry: LeafEntry)] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.scopeAnnotation.isLaneControl else { continue }
            guard metadata.value.bitPattern64 != 0 else { continue }
            guard let positionRange = node.positionRange else { continue }

            entries.append((
                position: positionRange.lowerBound,
                entry: LeafEntry(nodeID: nodeID)
            ))
        }

        guard entries.isEmpty == false else { return nil }

        entries.sort { $0.position < $1.position }

        return .laneCollapse(ValueMinimizationScope(
            leaves: entries.map(\.entry),
            batchZeroEligible: entries.count > 1
        ))
    }
}
