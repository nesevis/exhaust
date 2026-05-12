//
//  ChoiceGraphDiff.swift
//  Exhaust
//

/// Describes the structural difference between two successive ``ChoiceGraph`` instances by comparing their ``ChoicePath``-identified nodes.
///
/// Produced by ``diff(old:new:)`` after a graph rebuild. Consumers use this to decide which encoder state to preserve (unchanged nodes), which to discard (removed nodes), and which regions need fresh scope enumeration (added nodes).
package struct ChoiceGraphDiff {
    /// Nodes present in both graphs with the same ``ChoicePath``. The value maps old node ID to new node ID.
    package let preserved: [ChoicePath: (oldNodeID: Int, newNodeID: Int)]

    /// ``ChoicePath``s present in the new graph but not in the old. These are structurally new nodes that need fresh encoder passes.
    package let added: Set<ChoicePath>

    /// ``ChoicePath``s present in the old graph but not in the new. Encoder state keyed to these paths can be discarded.
    package let removed: Set<ChoicePath>

    /// Whether the graph structure is identical — no added or removed paths.
    package var isStructurallyIdentical: Bool {
        added.isEmpty && removed.isEmpty
    }

    /// Computes the structural diff between two graphs by matching nodes on ``ChoicePath``.
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
