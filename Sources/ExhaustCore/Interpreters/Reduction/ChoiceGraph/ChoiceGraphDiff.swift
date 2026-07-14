//
//  ChoiceGraphDiff.swift
//  Exhaust
//

/// Describes the structural difference between two successive ``ChoiceGraph`` instances by comparing their structural addresses.
///
/// Produced by ``diff(old:new:)`` after a graph rebuild. A matching path establishes that both graphs contain the same position, not that the position has the same logical occupant. Consumers that preserve state must apply any additional value or context guards that state requires.
package struct ChoiceGraphDiff {
    /// Paths present in both graphs. Each value maps the node at that position in the old graph to the node at that position in the new graph.
    package let preserved: [ChoicePath: (oldNodeID: Int, newNodeID: Int)]

    /// Structural addresses present in the new graph but not in the old. These positions need fresh encoder passes.
    package let added: Set<ChoicePath>

    /// Structural addresses present in the old graph but not in the new. Encoder state keyed to these positions can be discarded.
    package let removed: Set<ChoicePath>

    /// Whether structural candidate sources can be reused — no active paths were added or removed, and all preserved nodes kept their node IDs.
    ///
    /// Node IDs can shift even when the set of live ChoicePaths is unchanged: a value change that selects a different pick branch with the same shape leaves the active paths identical but can add or remove inactive nodes, renumbering everything after them. Structural sources (permutation, removal, migration scopes) store raw node IDs, so they are only safe to reuse when IDs are stable.
    package var canReuseStructuralSources: Bool {
        added.isEmpty && removed.isEmpty && preserved.allSatisfy { $0.value.oldNodeID == $0.value.newNodeID }
    }

    /// Computes the structural diff between two graphs by matching structural addresses.
    ///
    /// Only active nodes (non-nil ``ChoiceGraphNode/positionRange``) are compared — inactive branches are excluded because they don't participate in reduction.
    package static func diff(old: ChoiceGraph, new: ChoiceGraph) -> ChoiceGraphDiff {
        var oldByPath: [ChoicePath: Int] = [:]
        for nodeID in old.liveNodeIDs {
            let path = old.nodes[nodeID].choicePath
            if path.isEmpty == false {
                oldByPath[path] = nodeID
            }
        }

        var preserved: [ChoicePath: (oldNodeID: Int, newNodeID: Int)] = [:]
        var added = Set<ChoicePath>()

        for nodeID in new.liveNodeIDs {
            let path = new.nodes[nodeID].choicePath
            if path.isEmpty == false {
                if let oldNodeID = oldByPath.removeValue(forKey: path) {
                    preserved[path] = (oldNodeID: oldNodeID, newNodeID: nodeID)
                } else {
                    added.insert(path)
                }
            }
        }

        let removed = Set(oldByPath.keys)

        return ChoiceGraphDiff(
            preserved: preserved,
            added: added,
            removed: removed
        )
    }
}
