//
//  ScopeQueryHelpers.swift
//  Exhaust
//

// MARK: - Scope Query Helpers

/// Shared helpers used by the scope query namespaces (``MinimizationScopeQuery``, ``ExchangeScopeQuery``, ``RemovalScopeQuery``, and siblings).
///
/// These previously lived as instance methods on ``ChoiceGraph`` but are now called as pure functions from the static scope builders so that multiple builders can share a single ``buildInnerDescendantToBind(graph:)`` allocation per enumeration pass.
enum ScopeQueryHelpers {
    /// Builds an index from any ``chooseBits`` leaf inside a bind's inner subtree to the enclosing bind's node ID.
    ///
    /// Used by minimization and exchange scope construction to tag bind-inner leaves in ``LeafEntry/mayReshapeOnAcceptance`` and to compute value yield for prioritization. Covers both scalar inner (the inner child is itself a leaf) and multi-leaf inner (the inner child is a sequence, zip, or pick container — every ``chooseBits`` descendant gets mapped).
    ///
    /// When a bind is nested inside another bind's inner subtree, descendant leaves are claimed by the outermost enclosing bind. ``ChoiceGraph.nodes`` is constructed top-down, so iterating in index order visits outer binds first and the conditional write preserves outermost-wins semantics. Yield priority tracks the outer reshape cost, which is the correct signal for scheduling — mutating such a leaf triggers reshape at every enclosing bind.
    ///
    /// Callers that need both minimization and exchange scopes should build this once and pass it to both to avoid duplicate allocations.
    static func buildInnerDescendantToBind(graph: ChoiceGraph) -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            var stack = [innerChildID]
            while let current = stack.popLast() {
                let currentNode = graph.nodes[current]
                if case .chooseBits = currentNode.kind {
                    if index[current] == nil {
                        index[current] = node.id
                    }
                }
                stack.append(contentsOf: currentNode.children)
            }
        }
        return index
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

    /// Returns true when a leaf is the inner child of a bind. Any bind-inner mutation must route through ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` (not the value-only fast path) because the materializer may produce a tree with a different bound-subtree shape — different array length, different value ranges, different content — even when the bind has no *nested* binds or picks.
    ///
    /// The previous predicate filtered on ``BindMetadata/isStructurallyConstant`` and missed Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`: the bound contains only plain choices (so `isStructurallyConstant == true`), but its length and element validRanges depend on `n`, so changing `n` changes the live tree's shape. The value-only fast path then left the graph holding the old bound subtree's nodes at positions that no longer corresponded to value entries in the live sequence, producing the position drift documented in `ExhaustDocs/graph-reducer-position-drift-bug.md`.
    ///
    /// Always treating bind-inner leaves as `mayReshape: true` is correct and simple. The cost is that the rare workloads where the bound subtree is genuinely shape-and-content-stable pay extra splice work; in exchange the splice path is the only place that handles bind-inner mutations and the contract is uniform.
    static func isBindInner(
        _ leafNodeID: Int,
        innerDescendantToBind: [Int: Int]
    ) -> Bool {
        innerDescendantToBind[leafNodeID] != nil
    }

    /// Wraps a leaf node ID in a ``LeafEntry`` with the bind-inner reshape marker populated from the supplied index.
    static func makeLeafEntry(
        _ nodeID: Int,
        innerDescendantToBind: [Int: Int]
    ) -> LeafEntry {
        LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: isBindInner(
                nodeID,
                innerDescendantToBind: innerDescendantToBind
            )
        )
    }
}
