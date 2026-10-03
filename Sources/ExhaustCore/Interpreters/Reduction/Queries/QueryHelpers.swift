//
//  QueryHelpers.swift
//  Exhaust
//

// MARK: - Scope Query Helpers

/// Shared helpers used by the scope query namespaces (``RemovalQuery``, ``ExchangeQuery``, and siblings).
enum QueryHelpers {
    /// Retains leaf types before scope assembly. Node IDs are nonempty and ascending so group identity is independent of discovery order.
    struct LeafGroup {
        let typeTag: TypeTag
        let nodeIDs: [Int]

        /// Uses sequence position rather than node identity to preserve tandem search ordering.
        func position(in graph: ChoiceGraph) -> Int {
            graph.nodes[nodeIDs[0]].positionRange?.lowerBound ?? 0
        }
    }

    /// Whether the leaf sits away from its reduction target, so it has magnitude to give up.
    static func isOffTarget(_ nodeID: Int, graph: ChoiceGraph) -> Bool {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            return false
        }
        return reductionDistance(metadata) > 0
    }

    /// Measures available magnitude in encoded bit-pattern space relative to the domain's reduction target.
    static func reductionDistance(_ metadata: ChooseBitsMetadata) -> UInt64 {
        let target = metadata.value.reductionTarget(in: metadata.validRange)
        return metadata.value.bitPattern64 > target
            ? metadata.value.bitPattern64 - target
            : target - metadata.value.bitPattern64
    }

    /// Walks through transparent wrappers (groups, structurally-constant binds) beneath a node to find the first sequence node.
    ///
    /// Returns the sequence node's ID, or nil if no sequence is found beneath the transparent chain. Used by both removal scope construction (aligned deletion) and exchange scope construction (cross-zip homogeneous redistribution).
    static func findSequenceBeneath(_ nodeID: Int, graph: ChoiceGraph) -> Int? {
        let node = graph.nodes[nodeID]
        if case .sequence = node.kind {
            return nodeID
        }
        switch node.kind {
            case .zip:
                for childID in node.children {
                    if let found = findSequenceBeneath(childID, graph: graph) {
                        return found
                    }
                }
                return nil
            case let .bind(metadata):
                if metadata.isStructurallyConstant, node.children.count >= 2 {
                    let boundChildID = node.children[metadata.boundChildIndex]
                    return findSequenceBeneath(boundChildID, graph: graph)
                }
                return nil
            case .chooseBits, .pick, .just:
                return nil
            case .sequence:
                return nodeID
        }
    }
}
