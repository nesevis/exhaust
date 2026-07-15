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

    /// Preserved structural addresses whose node kind changed between graphs.
    package let kindChangedPaths: Set<ChoicePath>

    /// Whether every node-kind change is a transition between a value leaf and a constant leaf.
    ///
    /// A leaf-kind transition does not change removal, migration, or replacement scopes. Permutation sources must be rebuilt because their sibling-shape grouping treats value and constant leaves separately.
    package let onlyLeafKindsChanged: Bool

    /// Whether every structural candidate source can be reused — no active paths were added or removed, all preserved nodes kept their node IDs, and all preserved nodes kept their kinds.
    ///
    /// Node IDs can shift even when the set of live ChoicePaths is unchanged: a value change that selects a different pick branch with the same shape leaves the active paths identical but can add or remove inactive nodes, renumbering everything after them. Structural sources (removal, migration, replacement, and permutation scopes) store raw node IDs, so they are only safe to reuse when IDs are stable.
    package var canReuseStructuralSources: Bool {
        added.isEmpty
            && removed.isEmpty
            && kindChangedPaths.isEmpty
            && preserved.allSatisfy { $0.value.oldNodeID == $0.value.newNodeID }
    }

    /// Whether every structural source except permutation can be reused after a leaf-kind transition.
    package var canReuseStructuralSourcesExceptPermutation: Bool {
        added.isEmpty
            && removed.isEmpty
            && onlyLeafKindsChanged
            && preserved.allSatisfy { $0.value.oldNodeID == $0.value.newNodeID }
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
        var kindChanged = Set<ChoicePath>()
        var allKindChangesAreLeafTransitions = true

        for nodeID in new.liveNodeIDs {
            let path = new.nodes[nodeID].choicePath
            if path.isEmpty == false {
                if let oldNodeID = oldByPath.removeValue(forKey: path) {
                    preserved[path] = (oldNodeID: oldNodeID, newNodeID: nodeID)
                    let oldKind = kindDiscriminator(for: old.nodes[oldNodeID].kind)
                    let newKind = kindDiscriminator(for: new.nodes[nodeID].kind)
                    if oldKind != newKind {
                        kindChanged.insert(path)
                        allKindChangesAreLeafTransitions = allKindChangesAreLeafTransitions
                            && isLeafTransition(from: oldKind, to: newKind)
                    }
                } else {
                    added.insert(path)
                }
            }
        }

        let removed = Set(oldByPath.keys)

        return ChoiceGraphDiff(
            preserved: preserved,
            added: added,
            removed: removed,
            kindChangedPaths: kindChanged,
            onlyLeafKindsChanged: kindChanged.isEmpty == false
                && allKindChangesAreLeafTransitions
        )
    }

    /// Reduces node metadata to the case distinction consumed by structural source queries.
    private static func kindDiscriminator(for kind: ChoiceGraphNodeKind) -> KindDiscriminator {
        switch kind {
            case .chooseBits: .chooseBits
            case .pick: .pick
            case .bind: .bind
            case .zip: .zip
            case .sequence: .sequence
            case .just: .just
        }
    }

    /// Returns whether a kind change preserves leaf position while changing value reducibility.
    private static func isLeafTransition(
        from oldKind: KindDiscriminator,
        to newKind: KindDiscriminator
    ) -> Bool {
        switch (oldKind, newKind) {
            case (.chooseBits, .just), (.just, .chooseBits): true
            default: false
        }
    }

    /// Identifies the structural case of a graph node without comparing case-specific metadata.
    private enum KindDiscriminator {
        case chooseBits
        case pick
        case bind
        case zip
        case sequence
        case just
    }
}
