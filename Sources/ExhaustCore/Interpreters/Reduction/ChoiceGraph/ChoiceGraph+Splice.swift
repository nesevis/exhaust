//
//  ChoiceGraph+Splice.swift
//  Exhaust
//

// MARK: - Splice Primitives
//
// Shared building blocks for incremental graph mutations that add or remove subtrees. Each primitive maintains a single invariant (positions, values, or topology); callers compose them into operation-specific splice methods. The bind-reshape path in ChoiceGraph+Lifecycle.swift and the structural-mutation paths below both build on these primitives.

extension ChoiceGraph {
    /// Tombstones a subtree: sets all descendant position ranges to nil, adds their IDs to the graph's removed set, and removes containment and dependency edges referencing them. Does not touch self-similarity groups — ``finalizeStructuralSplice()`` handles that.
    ///
    /// Returns the set of tombstoned node IDs for use as an exclusion set in subsequent position-shift propagation.
    ///
    /// - Complexity: O(*S*) where *S* is the subtree size.
    @discardableResult
    func tombstoneSubtree(
        rootNodeID: Int,
        into application: inout ChangeApplication
    ) -> Set<Int> {
        let nodeIDs = collectSubtreeNodeIDs(rootID: rootNodeID)
        for nodeID in nodeIDs {
            nodes[nodeID] = nodes[nodeID].with(positionRange: .some(nil))
            removedNodeIDs.insert(nodeID)
        }
        containmentEdges.removeAll { nodeIDs.contains($0.source) || nodeIDs.contains($0.target) }
        dependencyEdges.removeAll { nodeIDs.contains($0.source) || nodeIDs.contains($0.target) }
        application.removedNodeIDs.formUnion(nodeIDs)
        return nodeIDs
    }

    /// Builds a subtree from a choice tree and appends the resulting nodes and edges to the graph. The caller is responsible for adding a containment edge from `parent` to the returned root ID and for patching the parent's children array.
    ///
    /// Returns the node ID of the new subtree's root, or nil if the subtree produced no nodes.
    ///
    /// - Complexity: O(*T*) where *T* is the subtree's flattened entry count.
    func buildAndAppendSubtree(
        from subtree: ChoiceTree,
        startingOffset: Int,
        parent: Int,
        bindDepth: Int,
        parentPath: BindPath,
        into application: inout ChangeApplication
    ) -> Int? {
        let rebuilt = ChoiceGraphBuilder.buildSubtree(
            from: subtree,
            startingOffset: startingOffset,
            parent: parent,
            bindDepth: bindDepth,
            nodeIDOffset: nodes.count,
            parentPath: parentPath
        )
        let firstNewNodeID = rebuilt.nodes.first?.id
        for newNode in rebuilt.nodes {
            application.addedNodeIDs.insert(newNode.id)
        }
        nodes.append(contentsOf: rebuilt.nodes)
        containmentEdges.append(contentsOf: rebuilt.containmentEdges)
        dependencyEdges.append(contentsOf: rebuilt.dependencyEdges)
        graphStats.dynamicRegionRebuilds += 1
        graphStats.dynamicRegionNodesRebuilt += rebuilt.nodes.count
        return firstNewNodeID
    }

    /// Shifts the `positionRange` of every live node whose range starts strictly after `insertionPoint` by `delta`. Nodes whose range *contains* `insertionPoint` (ancestors of the splice region) get their `upperBound` extended by `delta`. Sequence nodes additionally have their `childPositionRanges` metadata shifted in lockstep.
    ///
    /// `excluding` is the set of node IDs belonging to the rebuilt or tombstoned subtree — those nodes are already at the correct offsets and must not be shifted again.
    func propagatePositionShift(
        after insertionPoint: Int,
        delta: Int,
        excluding: Set<Int>
    ) {
        if delta == 0 { return }
        var shiftedSummary: [String] = []
        for index in nodes.indices {
            if isTombstoned(index) { continue }
            if excluding.contains(index) { continue }
            let node = nodes[index]
            guard let range = node.positionRange else { continue }

            let newRange: ClosedRange<Int>
            if range.lowerBound > insertionPoint {
                newRange = (range.lowerBound + delta) ... (range.upperBound + delta)
            } else if range.upperBound >= insertionPoint {
                newRange = range.lowerBound ... (range.upperBound + delta)
            } else {
                continue
            }
            if shiftedSummary.count < 16 {
                shiftedSummary.append("\(node.id):\(range.lowerBound)...\(range.upperBound)→\(newRange.lowerBound)...\(newRange.upperBound)")
            }

            let updatedKind: ChoiceGraphNodeKind
            if case let .sequence(seqMetadata) = node.kind {
                let shiftedChildRanges = seqMetadata.childPositionRanges.map { childRange -> ClosedRange<Int> in
                    if childRange.lowerBound > insertionPoint {
                        return (childRange.lowerBound + delta) ... (childRange.upperBound + delta)
                    }
                    if childRange.upperBound >= insertionPoint {
                        return childRange.lowerBound ... (childRange.upperBound + delta)
                    }
                    return childRange
                }
                updatedKind = .sequence(SequenceMetadata(
                    lengthConstraint: seqMetadata.lengthConstraint,
                    elementCount: seqMetadata.elementCount,
                    childPositionRanges: shiftedChildRanges,
                    childIndexByNodeID: seqMetadata.childIndexByNodeID,
                    elementTypeTag: seqMetadata.elementTypeTag
                ))
            } else {
                updatedKind = node.kind
            }

            nodes[index] = node.with(kind: updatedKind, positionRange: newRange)
        }
        ExhaustLog.debug(
            category: .reducer,
            event: "position_shift_complete",
            metadata: [
                "after": "\(insertionPoint)",
                "delta": "\(delta)",
                "sample": shiftedSummary.joined(separator: " "),
            ]
        )
    }

    /// Resyncs chooseBits leaf values from the post-mutation tree for leaves whose positions shifted. After a position-shifting splice, leaves right of the splice point may hold stale values relative to the ``ChoiceSequence`` at their new positions. This pass compares each shifted leaf's stored value against `freshTree` and updates mismatches.
    ///
    /// - Parameters:
    ///   - pastPosition: Leaves with `positionRange.lowerBound > pastPosition` are checked. Pass the last unshifted position so only shifted leaves are visited.
    ///   - freshTree: The post-mutation choice tree with correct values at all positions.
    ///   - excluding: Node IDs to skip (typically newly built nodes whose values are already correct).
    /// - Complexity: O(*L*) leaves plus one ``ChoiceSequence`` flatten.
    func resyncShiftedLeaves(
        pastPosition: Int,
        freshTree: ChoiceTree,
        excluding: Set<Int>
    ) {
        let freshSequence = ChoiceSequence(freshTree)
        for index in nodes.indices {
            if isTombstoned(index) { continue }
            if excluding.contains(index) { continue }
            guard case let .chooseBits(metadata) = nodes[index].kind else { continue }
            guard let range = nodes[index].positionRange else { continue }
            guard range.lowerBound > pastPosition else { continue }
            guard range.lowerBound < freshSequence.count else { continue }
            guard let entry = freshSequence[range.lowerBound].value else { continue }
            if entry.choice.bitPattern64 == metadata.value.bitPattern64 { continue }
            let updated = ChooseBitsMetadata(
                typeTag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                value: entry.choice,
                convergedOrigin: metadata.convergedOrigin
            )
            nodes[index] = nodes[index].with(kind: .chooseBits(updated))
        }
    }

    /// Post-splice bookkeeping: recomputes self-similarity groups from live pick nodes and invalidates all derived caches.
    func finalizeStructuralSplice() {
        recomputeSelfSimilarityGroups()
        invalidateTopologicalCaches()
        invalidateDerivedEdges()
    }
}

// MARK: - Sequence Element Removal

extension ChoiceGraph {
    /// Removes elements from a sequence node incrementally by tombstoning their subtrees, patching the sequence metadata, and propagating position shifts.
    ///
    /// Non-contiguous removals are handled by processing removal spans right-to-left so each shift does not affect the positions of spans to the left. Falls back to ``ChangeApplication/requiresFullRebuild`` when the sequence node is in an unexpected state.
    func applySequenceRemoval(
        seqNodeID: Int,
        removedChildIDs: [Int],
        freshTree: ChoiceTree,
        into application: inout ChangeApplication
    ) {
        guard removedChildIDs.isEmpty == false else { return }
        guard seqNodeID < nodes.count, isTombstoned(seqNodeID) == false else {
            application.requiresFullRebuild = true
            return
        }
        guard case let .sequence(metadata) = nodes[seqNodeID].kind else {
            application.requiresFullRebuild = true
            return
        }
        guard nodes[seqNodeID].positionRange != nil else {
            application.requiresFullRebuild = true
            return
        }

        let removedSet = Set(removedChildIDs)

        // Collect removal spans from the original (pre-tombstone) position ranges, sorted right-to-left by position so each shift does not affect spans to the left.
        struct RemovalSpan {
            let insertionPoint: Int
            let extent: Int
        }
        var spans: [RemovalSpan] = []
        for childID in removedChildIDs {
            guard let range = nodes[childID].positionRange else {
                application.requiresFullRebuild = true
                return
            }
            spans.append(RemovalSpan(
                insertionPoint: range.upperBound,
                extent: range.count
            ))
        }
        spans.sort { $0.insertionPoint > $1.insertionPoint }

        // Tombstone all removed subtrees.
        var allTombstoned = Set<Int>()
        for childID in removedChildIDs {
            let tombstoned = tombstoneSubtree(rootNodeID: childID, into: &application)
            allTombstoned.formUnion(tombstoned)
        }

        // Patch the sequence node before propagating shifts so the metadata only contains entries for surviving children. propagatePositionShift shifts childPositionRanges in lockstep — stale entries for removed children would produce invalid ranges.
        var newChildren: [Int] = []
        var newChildRanges: [ClosedRange<Int>] = []
        var newChildIndexByNodeID: [Int: Int] = [:]
        for childID in nodes[seqNodeID].children {
            if removedSet.contains(childID) { continue }
            guard let range = nodes[childID].positionRange else { continue }
            newChildIndexByNodeID[childID] = newChildren.count
            newChildren.append(childID)
            newChildRanges.append(range)
        }
        nodes[seqNodeID] = nodes[seqNodeID].with(
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.lengthConstraint,
                elementCount: newChildren.count,
                childPositionRanges: newChildRanges,
                childIndexByNodeID: newChildIndexByNodeID,
                elementTypeTag: metadata.elementTypeTag
            )),
            children: newChildren
        )

        // Propagate position shifts right-to-left.
        for span in spans {
            propagatePositionShift(
                after: span.insertionPoint,
                delta: -span.extent,
                excluding: allTombstoned
            )
            application.positionShifts.append(
                (insertionPoint: span.insertionPoint, delta: -span.extent)
            )
        }

        // Resync shifted leaves past the leftmost removal.
        let totalRemoved = spans.reduce(0) { $0 + $1.extent }
        if totalRemoved > 0 {
            let leftmostSpan = spans.last!
            let leftmostLowerBound = leftmostSpan.insertionPoint - leftmostSpan.extent + 1
            resyncShiftedLeaves(
                pastPosition: leftmostLowerBound - 1,
                freshTree: freshTree,
                excluding: application.addedNodeIDs
            )
        }

        finalizeStructuralSplice()
        application.touchedNodeIDs.insert(seqNodeID)
    }
}
