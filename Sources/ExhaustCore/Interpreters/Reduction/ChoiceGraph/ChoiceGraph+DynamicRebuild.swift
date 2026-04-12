//
//  ChoiceGraph+DynamicRebuild.swift
//  Exhaust
//

// MARK: - Dynamic Region Rebuild

public extension ChoiceGraph {
    /// Updates leaf node values from the current sequence without rebuilding the graph structure.
    ///
    /// For value-only cycles (no structural changes), this replaces a full ``ChoiceGraphBuilder/build(from:)`` call. Only ``ChooseBitsMetadata/value`` on active leaf nodes is refreshed. Edges, topological order, reachability, and position ranges are unchanged. Type-compatibility edges and source/sink annotations are invalidated since they depend on leaf values.
    func refreshLeafValues(from sequence: ChoiceSequence) {
        for nodeID in leafNodes {
            guard case let .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            guard let range = nodes[nodeID].positionRange else { continue }
            guard range.lowerBound < sequence.count else { continue }
            guard let entryValue = sequence[range.lowerBound].value else { continue }
            guard entryValue.choice != metadata.value else { continue }
            nodes[nodeID] = ChoiceGraphNode(
                id: nodes[nodeID].id,
                kind: .chooseBits(ChooseBitsMetadata(
                    typeTag: metadata.typeTag,
                    validRange: metadata.validRange,
                    isRangeExplicit: metadata.isRangeExplicit,
                    value: entryValue.choice,
                    convergedOrigin: metadata.convergedOrigin
                )),
                positionRange: nodes[nodeID].positionRange,
                children: nodes[nodeID].children,
                parent: nodes[nodeID].parent
            )
        }
        invalidateDerivedEdges()
    }

    /// Rebuilds the bound subtree of a bind node from a new ``ChoiceTree``.
    ///
    /// Walks the new bound tree, replaces the old bound subgraph in place, and recomputes dependency edges within the region. The static part of the bind node (the node itself, its dependency edge to the inner, its containment edge from its parent) is preserved. Type-compatibility edges and source/sink annotations are invalidated and will be recomputed lazily on next access.
    ///
    /// - Parameters:
    ///   - bindNodeID: The bind node whose bound subtree changed.
    ///   - newBoundTree: The new bound ``ChoiceTree`` produced by `forward(newValue)`.
    func rebuildBoundSubtree(
        bindNodeID: Int,
        newBoundTree: ChoiceTree
    ) {
        let bindNode = nodes[bindNodeID]
        guard case let .bind(metadata) = bindNode.kind else { return }
        guard bindNode.children.count >= 2 else { return }

        let boundChildID = bindNode.children[metadata.boundChildIndex]
        let boundNode = nodes[boundChildID]
        guard let boundRange = boundNode.positionRange else { return }

        // Remove old bound subtree nodes and their edges.
        let oldBoundNodeIDs = collectSubtreeNodeIDs(rootID: boundChildID)
        removeNodesAndEdges(nodeIDs: oldBoundNodeIDs)

        // Walk the new bound tree into the graph at the same offset.
        let rebuilt = ChoiceGraphBuilder.buildSubtree(
            from: newBoundTree,
            startingOffset: boundRange.lowerBound,
            parent: bindNodeID,
            bindDepth: metadata.bindDepth + 1,
            nodeIDOffset: nodes.count
        )

        // Append new nodes and edges.
        nodes.append(contentsOf: rebuilt.nodes)
        containmentEdges.append(contentsOf: rebuilt.containmentEdges)
        dependencyEdges.append(contentsOf: rebuilt.dependencyEdges)

        // Patch the bind node's children to reference the new bound child.
        if let firstNewNodeID = rebuilt.nodes.first?.id {
            var updatedChildren = bindNode.children
            updatedChildren[metadata.boundChildIndex] = firstNewNodeID
            nodes[bindNodeID] = ChoiceGraphNode(
                id: bindNodeID,
                kind: bindNode.kind,
                positionRange: bindNode.positionRange,
                children: updatedChildren,
                parent: bindNode.parent
            )
        }

        invalidateDerivedEdges()
    }

    /// Updates a pick node after a branch pivot.
    ///
    /// The previously-active branch becomes inactive (nil position ranges on all its subtree nodes). The newly-active branch's subtree is populated from the materialised result. This is a structural change that invalidates derived edges.
    ///
    /// - Parameters:
    ///   - pickNodeID: The pick node whose selection changed.
    ///   - newSelectedID: The branch ID of the newly selected branch.
    ///   - newTree: The new ``ChoiceTree`` for the pick site, produced by the materialiser.
    func updateBranchSelection(
        pickNodeID: Int,
        newSelectedID: UInt64,
        newTree _: ChoiceTree
    ) {
        let pickNode = nodes[pickNodeID]
        guard case let .pick(metadata) = pickNode.kind else { return }

        // Depopulate the old active branch (set position ranges to nil).
        let oldActiveChildID = pickNode.children[metadata.selectedChildIndex]
        depopulateSubtree(rootID: oldActiveChildID)

        // Find the new active child index.
        var newSelectedChildIndex = metadata.selectedChildIndex
        for (index, childID) in pickNode.children.enumerated() {
            if case let .pick(childPickMeta) = nodes[childID].kind,
               childPickMeta.selectedID == newSelectedID
            {
                newSelectedChildIndex = index
                break
            }
        }

        // Update the pick node's metadata.
        nodes[pickNodeID] = ChoiceGraphNode(
            id: pickNodeID,
            kind: .pick(PickMetadata(
                fingerprint: metadata.fingerprint,
                branchIDs: metadata.branchIDs,
                selectedID: newSelectedID,
                selectedChildIndex: newSelectedChildIndex,
                branchElements: metadata.branchElements
            )),
            positionRange: pickNode.positionRange,
            children: pickNode.children,
            parent: pickNode.parent
        )

        invalidateDerivedEdges()
    }

    /// Invalidates sensitivity flags for all leaves within a bind node's bound subtree.
    ///
    /// Called when a structurally-constant bind-inner value changes. The predicate's behavior at leaves in the bound subtree may have changed even though the tree shape did not. Sensitivity flags for affected leaves are cleared, forcing re-evaluation.
    ///
    /// - Parameter bindNodeID: The bind node whose inner value changed.
    /// - Returns: The IDs of leaf nodes whose sensitivity flags were invalidated.
    func leafNodesInBoundSubtree(of bindNodeID: Int) -> [Int] {
        let bindNode = nodes[bindNodeID]
        guard case let .bind(metadata) = bindNode.kind else { return [] }
        guard bindNode.children.count >= 2 else { return [] }
        let boundChildID = bindNode.children[metadata.boundChildIndex]
        return collectLeafNodeIDs(rootID: boundChildID)
    }
}
