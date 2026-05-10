//
//  ChoiceGraph+Lifecycle.swift
//  Exhaust
//

// MARK: - Mutation Application

extension ChoiceGraph {
    /// Applies an encoder-reported mutation to the graph in place.
    ///
    /// Returns a ``ChangeApplication`` describing what changed. When ``ChangeApplication/requiresFullRebuild`` is true the scheduler should discard the partial result and rebuild the graph from `freshTree` via ``ChoiceGraph/build(from:)``.
    ///
    /// Both branches of ``ProjectedMutation/leafValues(_:)`` are handled in place: pure value-only changes (`mayReshape == false`) take the fast path that rewrites leaf metadata, and bind-inner reshape changes (`mayReshape == true`) trigger an in-place splice of the affected bound subtree extracted from `freshTree`. Sequence-element removals and branch pivots use the shared splice infrastructure to tombstone, shift, and resync in place. Remaining structural mutation cases still set `requiresFullRebuild = true`.
    ///
    /// - Parameters:
    ///   - mutation: The mutation reported by the encoder whose probe was just accepted.
    ///   - freshTree: The choice tree the materializer produced for the accepted candidate. The reshape path walks it to extract the new bound subtree at the affected bind's known position.
    /// - Returns: A ``ChangeApplication`` describing the in-place edits and any fallback signal.
    package func apply(_ mutation: ProjectedMutation, freshTree: ChoiceTree) -> ChangeApplication {
        var application = ChangeApplication()
        switch mutation {
        case let .leafValues(changes):
            applyLeafValues(changes, freshTree: freshTree, into: &application)
        case let .sequenceElementsRemoved(removals):
            let sortedRemovals = removals.sorted {
                (nodes[$0.seqNodeID].positionRange?.lowerBound ?? 0)
                    > (nodes[$1.seqNodeID].positionRange?.lowerBound ?? 0)
            }
            for (seqNodeID, removedIDs) in sortedRemovals {
                applySequenceRemoval(
                    seqNodeID: seqNodeID,
                    removedChildIDs: removedIDs,
                    freshTree: freshTree,
                    into: &application
                )
                if application.requiresFullRebuild { break }
            }
        case let .branchSelected(pickNodeID, newSelectedID):
            applyBranchPivot(
                pickNodeID: pickNodeID,
                newSelectedID: newSelectedID,
                freshTree: freshTree,
                into: &application
            )
        case .selfSimilarReplaced,
             .descendantPromoted,
             .sequenceElementsMigrated,
             .siblingsSwapped,
             .sequenceReordered:
            application.requiresFullRebuild = true
        }
        if application.requiresFullRebuild == false {
            if let divergence = leafPositionsDivergence(in: ChoiceSequence(freshTree)) {
                ExhaustLog.info(
                    category: .reducer,
                    event: "graph_freshtree_divergence",
                    metadata: [
                        "detail": divergence,
                    ]
                )
                application.requiresFullRebuild = true
            }
        }
        return application
    }

    /// Applies a ``ProjectedMutation/leafValues(_:)`` report.
    ///
    /// Partitions the changes into pure value-only (no bind-inner reshape) and reshape (`mayReshape == true`). Value-only changes always take the fast path and just rewrite leaf metadata. Reshape changes trigger ``applyBindReshape(forLeaf:freshTree:into:)`` for each affected leaf, which extracts the new bound subtree from `freshTree` and splices it into the graph in place.
    ///
    /// Conservative fallback: if more than one leaf in the same mutation report has `mayReshape == true`, fall back to a full rebuild. The simple case (one bind-inner change per probe) covers BinaryHeap and the typical Calculator workload; multi-bind reshape requires dependency-ordered processing.
    private func applyLeafValues(
        _ changes: [LeafChange],
        freshTree: ChoiceTree,
        into application: inout ChangeApplication
    ) {
        let reshapeChanges = changes.filter(\.mayReshape)
        let valueOnlyChanges = changes.filter { $0.mayReshape == false }

        // Multi-bind reshape conservative fallback. Only a single bind-inner change per acceptance is handled in place; multiple require dependency-ordered processing because the second bind's tree path may have shifted by the time the first bind's subtree was rebuilt.
        if reshapeChanges.count > 1 {
            application.requiresFullRebuild = true
            return
        }

        // Apply value-only changes first: rewrite leaf metadata in place, drop type-compatibility and source/sink caches at the end.
        for change in valueOnlyChanges {
            applyLeafValueWrite(change, into: &application)
        }

        // Apply the (at most one) reshape change.
        if let reshapeChange = reshapeChanges.first {
            applyLeafValueWrite(reshapeChange, into: &application)
            applyBindReshape(
                forLeaf: reshapeChange.leafNodeID,
                freshTree: freshTree,
                into: &application
            )
            if application.requiresFullRebuild {
                return
            }
        }

        // Leaf values changed → type-compatibility and source/sink caches depend on values and must drop. Topological order and reachability are invalidated separately by ``applyBindReshape`` when the bind subtree is rebuilt; pure value-only mutations leave them intact.
        invalidateDerivedEdges()
    }

    /// Rewrites a single leaf's ``ChooseBitsMetadata/value`` in place.
    private func applyLeafValueWrite(
        _ change: LeafChange,
        into application: inout ChangeApplication
    ) {
        guard change.leafNodeID < nodes.count else { return }
        guard isTombstoned(change.leafNodeID) == false else { return }
        guard case let .chooseBits(metadata) = nodes[change.leafNodeID].kind else { return }
        let updatedMetadata = ChooseBitsMetadata(
            typeTag: metadata.typeTag,
            validRange: metadata.validRange,
            isRangeExplicit: metadata.isRangeExplicit,
            value: change.newValue,
            convergedOrigin: metadata.convergedOrigin
        )
        nodes[change.leafNodeID] = nodes[change.leafNodeID].with(kind: .chooseBits(updatedMetadata))
        application.touchedNodeIDs.insert(change.leafNodeID)
    }

    // MARK: - Bind Reshape

    /// Splices a rebuilt bound subtree into the graph in place after a bind-inner value change.
    ///
    /// 1. Locates the controlling bind node by walking from the leaf up the parent chain.
    /// 2. Reads the bind's ``BindMetadata/bindPath`` from its existing ``ChoiceGraphNode/kind``.
    /// 3. Walks `freshTree` along that path to extract the new bound subtree.
    /// 4. Detects picks in the old or new subtree and falls back to full rebuild if found (self-similarity edges are not maintained incrementally).
    /// 5. Tombstones the old subtree's node IDs and edges referencing them.
    /// 6. Walks the new subtree via ``ChoiceGraphBuilder/buildSubtree(from:startingOffset:parent:bindDepth:nodeIDOffset:parentPath:)`` and appends the resulting nodes / edges.
    /// 7. Patches the bind node's children to reference the new bound child.
    /// 8. Propagates the length delta to right siblings and ancestors via ``propagatePositionShift(after:delta:excluding:)``.
    /// 9. Refreshes the bind's ``BindMetadata/isStructurallyConstant`` flag from the new subtree.
    /// 10. Invalidates topology / reachability and derived-edge caches.
    private func applyBindReshape(
        forLeaf leafNodeID: Int,
        freshTree: ChoiceTree,
        into application: inout ChangeApplication
    ) {
        // Step 1: locate the controlling bind.
        guard let bindNodeID = controllingBind(forInnerLeaf: leafNodeID) else {
            application.requiresFullRebuild = true
            return
        }
        guard case let .bind(bindMetadata) = nodes[bindNodeID].kind else {
            application.requiresFullRebuild = true
            return
        }
        guard bindNodeID < nodes.count, isTombstoned(bindNodeID) == false else {
            application.requiresFullRebuild = true
            return
        }
        guard nodes[bindNodeID].positionRange != nil else {
            application.requiresFullRebuild = true
            return
        }
        guard nodes[bindNodeID].children.count >= 2 else {
            application.requiresFullRebuild = true
            return
        }

        let oldBoundChildID = nodes[bindNodeID].children[bindMetadata.boundChildIndex]
        guard let oldBoundRange = nodes[oldBoundChildID].positionRange else {
            application.requiresFullRebuild = true
            return
        }

        // Path-based bind identification stays correct when an upstream change shifts sequence positions. The prior offset-based lookup could silently match the wrong bind in divergent freshTrees — for example, symmetric recursive generators where sibling binds sit at near-identical offsets.
        guard let newBoundSubtree = Self.extractBoundSubtree(
            from: freshTree,
            matchingPath: bindMetadata.bindPath
        ) else {
            application.requiresFullRebuild = true
            return
        }

        // Compute length delta from the OLD bound subtree's stored extent versus the NEW bound subtree's flattened entry count.
        let oldBoundLength = oldBoundRange.count
        let newBoundLength = newBoundSubtree.flattenedEntryCount
        let lengthDelta = newBoundLength - oldBoundLength


        ExhaustLog.debug(
            category: .reducer,
            event: "bind_reshape_extents",
            metadata: [
                "bind_node": "\(bindNodeID)",
                "old_range": "\(oldBoundRange.lowerBound)...\(oldBoundRange.upperBound)",
                "new_length": "\(newBoundLength)",
                "delta": "\(lengthDelta)",
                "leaf": "\(leafNodeID)",
            ]
        )

        // Step 5: tombstone the old bound subtree.
        let oldBoundNodeIDs = tombstoneSubtree(rootNodeID: oldBoundChildID, into: &application)

        // Step 6: walk the new bound subtree.
        let firstNewNodeID = buildAndAppendSubtree(
            from: newBoundSubtree,
            startingOffset: oldBoundRange.lowerBound,
            parent: bindNodeID,
            bindDepth: bindMetadata.bindDepth + 1,
            parentPath: bindMetadata.bindPath + [.bindBound],
            into: &application
        )

        // Step 7: patch the bind node's children to reference the new bound child, and add the containment edge from the bind to the new bound child. ``ChoiceGraphBuilder/buildSubtree`` walks with
        // `parent: nil` and renumbers internally, which means it does NOT emit the containment edge from the external bind to the subtree root. The caller (this method) is responsible for adding it.
        if let firstNewNodeID {
            var updatedChildren = nodes[bindNodeID].children
            updatedChildren[bindMetadata.boundChildIndex] = firstNewNodeID
            nodes[bindNodeID] = nodes[bindNodeID].with(children: updatedChildren)
            containmentEdges.append(ContainmentEdge(
                source: bindNodeID,
                target: firstNewNodeID
            ))
        }

        // Step 8: propagate the length delta to right siblings and ancestors, then resync leaf values at their new positions.
        if lengthDelta != 0 {
            propagatePositionShift(
                after: oldBoundRange.upperBound,
                delta: lengthDelta,
                excluding: oldBoundNodeIDs.union(application.addedNodeIDs)
            )
            application.positionShifts.append((insertionPoint: oldBoundRange.upperBound, delta: lengthDelta))
            resyncShiftedLeaves(
                pastPosition: oldBoundRange.upperBound + lengthDelta,
                freshTree: freshTree,
                excluding: application.addedNodeIDs
            )
        }

        // Step 9: refresh structural-constancy on the bind, and clear any cached classification. The new subtree may have changed shape.
        let newIsStructurallyConstant = newBoundSubtree.containsBind == false
            && newBoundSubtree.containsPicks == false
        let hadClassification = bindMetadata.classification != nil || bindMetadata.downstreamFingerprint != nil
        if newIsStructurallyConstant != bindMetadata.isStructurallyConstant || hadClassification {
            nodes[bindNodeID] = nodes[bindNodeID].with(kind: .bind(BindMetadata(
                fingerprint: bindMetadata.fingerprint,
                isStructurallyConstant: newIsStructurallyConstant,
                bindDepth: bindMetadata.bindDepth,
                innerChildIndex: bindMetadata.innerChildIndex,
                boundChildIndex: bindMetadata.boundChildIndex,
                bindPath: bindMetadata.bindPath,
                classification: nil,
                downstreamFingerprint: nil
            )))
        }

        // Resync pick metadata after position-shifting splices when surviving picks exist past the insertion point. Those picks retain their pre-shift selectedID even though the sequence entry at their new position may encode a different branch.
        if lengthDelta != 0 {
            let hasShiftedPicks = nodes.contains { node in
                guard case .pick = node.kind else { return false }
                guard let range = node.positionRange else { return false }
                return range.lowerBound > oldBoundRange.upperBound
            }
            if hasShiftedPicks {
                let freshSequence = ChoiceSequence(freshTree)
                resyncPickMetadata(
                    pastPosition: oldBoundRange.upperBound,
                    acceptedSequence: freshSequence
                )
            }
        }


        // Step 10: finalize — recompute self-similarity groups, invalidate caches.
        finalizeStructuralSplice()

        application.touchedNodeIDs.insert(bindNodeID)
    }

    // MARK: - Bind Reshape Helpers

    /// Rebuilds the self-similarity group index from live (non-tombstoned) active pick nodes.
    ///
    /// Used by ``applyBindReshape(forLeaf:freshTree:into:)`` after splicing in a new bound subtree, since the splice may have removed picks from the old region and added picks in the new region.
    ///
    /// - Complexity: O(P) where P is the number of active pick nodes.
    func recomputeSelfSimilarityGroups() {
        selfSimilarityGroups.removeAll(keepingCapacity: true)
        for node in nodes {
            guard isTombstoned(node.id) == false else { continue }
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            selfSimilarityGroups[metadata.fingerprint, default: []].append(node.id)
        }
    }

    /// Patches `selectedID` on pick nodes whose positions shifted past `pastPosition`.
    ///
    /// A bind-inner reshape may shift positions of surviving pick nodes that were created by a prior splice. Those nodes retain their old `selectedID` because the current splice only rebuilds its own subtree. The accepted sequence's `.branch(Branch)` entry at `positionRange.lowerBound + 1` is authoritative.
    private func resyncPickMetadata(
        pastPosition: Int,
        acceptedSequence: ChoiceSequence
    ) {
        for nodeID in 0 ..< nodes.count {
            guard isTombstoned(nodeID) == false else { continue }
            guard case let .pick(pickMetadata) = nodes[nodeID].kind else { continue }
            guard let range = nodes[nodeID].positionRange else { continue }
            guard range.lowerBound > pastPosition else { continue }
            let branchEntryPosition = range.lowerBound + 1
            guard branchEntryPosition < acceptedSequence.count else { continue }
            guard case let .branch(branchInfo) = acceptedSequence[branchEntryPosition] else { continue }
            guard branchInfo.id != pickMetadata.selectedID else { continue }

            let correctedChildIndex = nodes[nodeID].children.firstIndex { childID in
                guard childID < nodes.count else { return false }
                guard nodes[childID].positionRange != nil else { return false }
                return true
            } ?? pickMetadata.selectedChildIndex

            ExhaustLog.debug(
                category: .reducer,
                event: "pick_metadata_resynced",
                metadata: [
                    "node_id": "\(nodeID)",
                    "stale_selected_id": "\(pickMetadata.selectedID)",
                    "corrected_selected_id": "\(branchInfo.id)",
                ]
            )

            nodes[nodeID] = nodes[nodeID].with(kind: .pick(PickMetadata(
                fingerprint: pickMetadata.fingerprint,
                branchCount: pickMetadata.branchCount,
                selectedID: branchInfo.id,
                selectedChildIndex: correctedChildIndex,
                branchElements: pickMetadata.branchElements
            )))
        }
    }

    /// Finds the bind node whose inner child is `leafNodeID` by walking up the parent-pointer chain.
    ///
    /// The inner leaf is a direct child of its controlling bind, so this is O(depth) — typically one or two hops — instead of the previous O(N) scan over all nodes.
    private func controllingBind(forInnerLeaf leafNodeID: Int) -> Int? {
        var current = leafNodeID
        while let parentID = nodes[current].parent {
            guard isTombstoned(parentID) == false else { return nil }
            if case let .bind(metadata) = nodes[parentID].kind,
               nodes[parentID].children.count >= 2,
               nodes[parentID].children[metadata.innerChildIndex] == current
            {
                return parentID
            }
            current = parentID
        }
        return nil
    }

}

// MARK: - Internal Node-Set Helpers

extension ChoiceGraph {
    /// Collects all node IDs in a subtree rooted at the given node.
    func collectSubtreeNodeIDs(rootID: Int) -> Set<Int> {
        var result = Set<Int>()
        var stack = [rootID]
        while stack.isEmpty == false {
            let current = stack.removeLast()
            guard current < nodes.count else { continue }
            result.insert(current)
            for child in nodes[current].children {
                stack.append(child)
            }
        }
        return result
    }

    /// Collects all chooseBits leaf node IDs in a subtree.
    func collectLeafNodeIDs(rootID: Int) -> [Int] {
        var result: [Int] = []
        var stack = [rootID]
        while stack.isEmpty == false {
            let current = stack.removeLast()
            guard current < nodes.count else { continue }
            if case .chooseBits = nodes[current].kind {
                result.append(current)
            }
            for child in nodes[current].children {
                stack.append(child)
            }
        }
        return result
    }

    /// Removes nodes and all edges referencing them. Invalidates derived edges.
    func removeNodesAndEdges(nodeIDs: Set<Int>) {
        containmentEdges.removeAll { nodeIDs.contains($0.source) || nodeIDs.contains($0.target) }
        dependencyEdges.removeAll { nodeIDs.contains($0.source) || nodeIDs.contains($0.target) }
        for (key, group) in selfSimilarityGroups {
            let filtered = group.filter { nodeIDs.contains($0) == false }
            selfSimilarityGroups[key] = filtered.isEmpty ? nil : filtered
        }
        invalidateDerivedEdges()
    }

    /// Sets position ranges to nil for all nodes in a subtree.
    func depopulateSubtree(rootID: Int) {
        var stack = [rootID]
        while stack.isEmpty == false {
            let current = stack.removeLast()
            guard current < nodes.count else { continue }
            let node = nodes[current]
            nodes[current] = node.with(positionRange: .some(nil))
            for child in node.children {
                stack.append(child)
            }
        }
    }
}
