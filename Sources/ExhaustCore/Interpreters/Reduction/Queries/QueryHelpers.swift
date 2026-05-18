//
//  QueryHelpers.swift
//  Exhaust
//

// MARK: - Scope Query Helpers

/// Shared helpers used by the scope query namespaces (``RemovalQuery``, ``ExchangeQuery``, and siblings).
enum QueryHelpers {
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
