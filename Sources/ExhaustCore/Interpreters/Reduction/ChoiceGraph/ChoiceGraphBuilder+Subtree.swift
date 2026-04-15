//
//  ChoiceGraphBuilder+Subtree.swift
//  Exhaust
//

// MARK: - Subtree Construction

extension ChoiceGraphBuilder {
    /// Result of building a subtree for dynamic region replacement.
    struct SubtreeResult {
        let nodes: [ChoiceGraphNode]
        let containmentEdges: [ContainmentEdge]
        let dependencyEdges: [DependencyEdge]
    }

    /// Builds a subtree from a ``ChoiceTree`` for dynamic region replacement.
    ///
    /// Used by ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` to walk a new bound tree and produce nodes/edges that can be spliced into an existing graph.
    ///
    /// The walk uses internal node IDs starting from 0 so the builder's positional indexing into ``nodes`` (`nodes[nodeID] = ...`) works correctly. After the walk completes, every node ID, parent reference, child reference, and edge endpoint is renumbered by adding `nodeIDOffset`. The subtree root's parent is set to the supplied external `parent` (which is typically a bind node ID in the host graph) — every other node's parent is renumbered as a local subtree ID.
    ///
    /// The caller is responsible for appending a containment edge from the external `parent` to the renumbered subtree root, and for patching the parent's `children` array to reference the renumbered root ID.
    ///
    /// - Parameters:
    ///   - tree: The new subtree to walk.
    ///   - startingOffset: The ``ChoiceSequence`` offset where this subtree starts.
    ///   - parent: The parent node ID in the existing graph. Stored on the subtree root after renumbering.
    ///   - bindDepth: The bind nesting depth at this position.
    ///   - nodeIDOffset: The offset added to every internal node ID so the splice does not collide with existing graph IDs.
    ///   - parentPath: The ``BindPath`` prefix from the host graph's root to this subtree's insertion point. Every bind emitted inside the subtree will have its path computed as `parentPath + <local descent>` so the subtree's binds carry globally correct paths.
    static func buildSubtree(
        from tree: ChoiceTree,
        startingOffset: Int,
        parent: Int?,
        bindDepth: Int,
        nodeIDOffset: Int,
        parentPath: BindPath
    ) -> SubtreeResult {
        var builder = ChoiceGraphBuilder()
        // Walk with parent: nil so no internal node references the external
        // parent ID. The walk uses internal IDs starting from 0, which keeps
        // the builder's positional indexing into `nodes[nodeID]` correct.
        _ = builder.walk(tree, offset: startingOffset, parent: nil, bindDepth: bindDepth, path: parentPath)

        // Compute dependency edges within the subtree using internal IDs.
        var subtreeDependencyEdges: [DependencyEdge] = []
        for node in builder.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            var stack = [boundChildID]
            while stack.isEmpty == false {
                let current = stack.removeLast()
                guard current >= 0, current < builder.nodes.count else { continue }
                let target = builder.nodes[current]
                switch target.kind {
                case .bind, .pick:
                    subtreeDependencyEdges.append(DependencyEdge(source: innerChildID, target: current))
                case .chooseBits, .zip, .sequence, .just:
                    break
                }
                for child in target.children {
                    stack.append(child)
                }
            }
        }

        // Renumber every internal ID by adding `nodeIDOffset`. The subtree
        // root (the first emitted node) has its parent set to the supplied
        // external `parent` — every other node's parent is a local subtree
        // ID and gets shifted.
        let renumberedNodes: [ChoiceGraphNode] = builder.nodes.enumerated().map { index, node in
            let renumberedParent: Int? = if index == 0 {
                parent
            } else {
                node.parent.map { $0 + nodeIDOffset }
            }
            return ChoiceGraphNode(
                id: node.id + nodeIDOffset,
                kind: node.kind,
                positionRange: node.positionRange,
                children: node.children.map { $0 + nodeIDOffset },
                parent: renumberedParent
            )
        }

        let renumberedContainment = builder.containmentEdges.map { edge in
            ContainmentEdge(
                source: edge.source + nodeIDOffset,
                target: edge.target + nodeIDOffset
            )
        }
        let renumberedDependency = subtreeDependencyEdges.map { edge in
            DependencyEdge(
                source: edge.source + nodeIDOffset,
                target: edge.target + nodeIDOffset
            )
        }

        return SubtreeResult(
            nodes: renumberedNodes,
            containmentEdges: renumberedContainment,
            dependencyEdges: renumberedDependency
        )
    }
}
