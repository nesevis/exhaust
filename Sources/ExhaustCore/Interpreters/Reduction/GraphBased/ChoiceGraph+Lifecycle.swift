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
    /// Layer 4 implements both branches of ``ProjectedMutation/leafValues(_:)``: pure value-only changes (`mayReshape == false`) take the fast path that just rewrites leaf metadata, and bind-inner reshape changes (`mayReshape == true`) trigger an in-place splice of the affected bound subtree extracted from `freshTree`. Structural mutation cases still set `requiresFullRebuild = true` until Layer 7 wires them up.
    ///
    /// - Parameters:
    ///   - mutation: The mutation reported by the encoder whose probe was just accepted.
    ///   - freshTree: The choice tree the materializer produced for the accepted candidate. The reshape path walks it to extract the new bound subtree at the affected bind's known position.
    /// - Returns: A ``ChangeApplication`` describing the in-place edits and any fallback signal.
    func apply(_ mutation: ProjectedMutation, freshTree: ChoiceTree) -> ChangeApplication {
        var application = ChangeApplication()
        switch mutation {
        case let .leafValues(changes):
            applyLeafValues(changes, freshTree: freshTree, into: &application)
        case .sequenceElementsRemoved,
             .branchSelected,
             .selfSimilarReplaced,
             .descendantPromoted,
             .sequenceElementsMigrated,
             .siblingsSwapped:
            // Structural mutations are not yet implemented in the partial
            // path. Layer 7 replaces these fallbacks with proper splice logic.
            application.requiresFullRebuild = true
        }
        return application
    }

    /// Applies a ``ProjectedMutation/leafValues(_:)`` report.
    ///
    /// Partitions the changes into pure value-only (no bind-inner reshape) and reshape (`mayReshape == true`). Value-only changes always take the fast path and just rewrite leaf metadata. Reshape changes trigger ``applyBindReshape(forLeaf:freshTree:into:)`` for each affected leaf, which extracts the new bound subtree from `freshTree` and splices it into the graph in place.
    ///
    /// Conservative fallback: if more than one leaf in the same mutation report has `mayReshape == true`, fall back to a full rebuild. The simple case (one bind-inner change per probe) covers BinaryHeap and the typical Calculator workload; multi-bind reshape requires dependency-ordered processing that Layer 4 defers as future work.
    private func applyLeafValues(
        _ changes: [LeafChange],
        freshTree: ChoiceTree,
        into application: inout ChangeApplication
    ) {
        let reshapeChanges = changes.filter(\.mayReshape)
        let valueOnlyChanges = changes.filter { $0.mayReshape == false }

        // Multi-bind reshape conservative fallback. Layer 4 handles a single
        // bind-inner change per acceptance; multiple require dependency-ordered
        // processing because the second bind's tree path may have shifted by
        // the time the first bind's subtree was rebuilt.
        if reshapeChanges.count > 1 {
            application.requiresFullRebuild = true
            return
        }

        // Apply value-only changes first. These are the same fast path the
        // pre-Layer-4 implementation used: rewrite leaf metadata in place,
        // drop type-compatibility and source/sink caches at the end.
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

        // Leaf values changed → type-compatibility and source/sink caches
        // depend on values and must drop. Topological order and reachability
        // are invalidated separately by ``applyBindReshape`` when the bind
        // subtree is rebuilt; pure value-only mutations leave them intact.
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
        nodes[change.leafNodeID] = ChoiceGraphNode(
            id: nodes[change.leafNodeID].id,
            kind: .chooseBits(updatedMetadata),
            positionRange: nodes[change.leafNodeID].positionRange,
            children: nodes[change.leafNodeID].children,
            parent: nodes[change.leafNodeID].parent
        )
        application.touchedNodeIDs.insert(change.leafNodeID)
    }

    // MARK: - Bind Reshape

    /// Splices a rebuilt bound subtree into the graph in place after a bind-inner value change.
    ///
    /// 1. Locates the controlling bind node by walking from the leaf up the parent chain.
    /// 2. Reads the bind's known offset from its existing ``ChoiceGraphNode/positionRange``.
    /// 3. Walks `freshTree` to extract the new bound subtree at that offset.
    /// 4. Detects picks in the old or new subtree and falls back to full rebuild if found (Layer 4 does not yet maintain self-similarity edges incrementally).
    /// 5. Tombstones the old subtree's node IDs and edges referencing them.
    /// 6. Walks the new subtree via ``ChoiceGraphBuilder/buildSubtree(from:startingOffset:parent:bindDepth:nodeIDOffset:)`` and appends the resulting nodes / edges.
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
        guard let bindRange = nodes[bindNodeID].positionRange else {
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

        // Step 2/3: extract the new bound subtree from freshTree at the bind's
        // known offset. The bind's lowerBound is unchanged for a single
        // bind-inner mutation because positions before the bind are not
        // affected by the bound subtree's reshape.
        guard let newBoundSubtree = Self.extractBoundSubtree(
            from: freshTree,
            bindAtOffset: bindRange.lowerBound
        ) else {
            application.requiresFullRebuild = true
            return
        }

        // Compute length delta from the OLD bound subtree's stored extent
        // versus the NEW bound subtree's flattened entry count.
        let oldBoundLength = oldBoundRange.count
        let newBoundLength = newBoundSubtree.flattenedEntryCount
        let lengthDelta = newBoundLength - oldBoundLength

        // Step 5: tombstone the old bound subtree's node IDs and drop edges
        // referencing them. Tombstones (Layer 1) keep node IDs stable so
        // existing scopes that captured node IDs at construction time stay
        // referencing valid entries. Nil-ing the position range makes every
        // iteration site that filters on `positionRange != nil` (including
        // ``structuralFingerprint``, ``leafNodes``, ``leafPositions``, the
        // type-compatibility computation, and the source-sink computation)
        // treat them as inactive uniformly.
        let oldBoundNodeIDs = collectSubtreeNodeIDs(rootID: oldBoundChildID)
        for nodeID in oldBoundNodeIDs {
            let node = nodes[nodeID]
            nodes[nodeID] = ChoiceGraphNode(
                id: node.id,
                kind: node.kind,
                positionRange: nil,
                children: node.children,
                parent: node.parent
            )
            removedNodeIDs.insert(nodeID)
        }
        containmentEdges.removeAll { oldBoundNodeIDs.contains($0.source) || oldBoundNodeIDs.contains($0.target) }
        dependencyEdges.removeAll { oldBoundNodeIDs.contains($0.source) || oldBoundNodeIDs.contains($0.target) }
        selfSimilarityEdges.removeAll { oldBoundNodeIDs.contains($0.nodeA) || oldBoundNodeIDs.contains($0.nodeB) }
        application.removedNodeIDs.formUnion(oldBoundNodeIDs)

        // Step 6: walk the new bound subtree.
        let rebuilt = ChoiceGraphBuilder.buildSubtree(
            from: newBoundSubtree,
            startingOffset: oldBoundRange.lowerBound,
            parent: bindNodeID,
            bindDepth: bindMetadata.bindDepth + 1,
            nodeIDOffset: nodes.count
        )
        let firstNewNodeID = rebuilt.nodes.first?.id
        for newNode in rebuilt.nodes {
            application.addedNodeIDs.insert(newNode.id)
        }
        nodes.append(contentsOf: rebuilt.nodes)
        containmentEdges.append(contentsOf: rebuilt.containmentEdges)
        dependencyEdges.append(contentsOf: rebuilt.dependencyEdges)

        // Step 7: patch the bind node's children to reference the new bound
        // child, and add the containment edge from the bind to the new
        // bound child. ``ChoiceGraphBuilder/buildSubtree`` walks with
        // `parent: nil` and renumbers internally, which means it does NOT
        // emit the containment edge from the external bind to the subtree
        // root. The caller (this method) is responsible for adding it.
        if let firstNewNodeID {
            var updatedChildren = nodes[bindNodeID].children
            updatedChildren[bindMetadata.boundChildIndex] = firstNewNodeID
            nodes[bindNodeID] = ChoiceGraphNode(
                id: bindNodeID,
                kind: nodes[bindNodeID].kind,
                positionRange: nodes[bindNodeID].positionRange,
                children: updatedChildren,
                parent: nodes[bindNodeID].parent
            )
            containmentEdges.append(ContainmentEdge(
                source: bindNodeID,
                target: firstNewNodeID
            ))
        }

        // Step 8: propagate the length delta to right siblings and ancestors,
        // then resync chooseBits leaf values from the live tree for any leaf
        // propagation moved.
        //
        // ``propagatePositionShift`` only moves ``positionRange``; it leaves
        // each propagated leaf's ``ChooseBitsMetadata/value`` untouched. The
        // value was set when the leaf was created (either by an original
        // ``ChoiceGraphBuilder/build(from:)`` walk or by an earlier
        // ``buildSubtree`` splice) from the freshTree of *that* moment. After
        // the current reshape, the live tree's content at the leaf's *new*
        // position can be different from what the leaf's value field still
        // holds — the materializer in guided decode mode walks the new tree
        // with the candidate as a prefix, and the values it produces at
        // shifted positions don't necessarily match what the candidate's same
        // numerical position contained. Without this resync, every active
        // leaf right of ``insertionPoint`` (and not in the rebuilt region) is
        // a position drift candidate: its stored value diverges from the
        // sequence content at its new ``positionRange.lowerBound``. The
        // ``graph_sequence_drift`` probe in ``ChoiceGraphScheduler/runProbeLoop``
        // catches this exact divergence; this pass eliminates the cause.
        //
        // The resync is gated on ``lengthDelta != 0``: when delta is zero, no
        // positions shifted, no leaf can have a stale value relative to its
        // (unchanged) position, and the entire flatten + walk is skipped.
        // Most bind-inner mutations leave the bound subtree's flattened
        // length unchanged (changing a leaf's value within its type does not
        // add or remove sequence entries), so this gate is the common case.
        //
        // When the resync does run, only leaves whose new position lies
        // strictly past ``newBoundUpper`` need to be checked: those are
        // exactly the propagated leaves. Leaves in the new bound region are
        // already in ``application.addedNodeIDs`` and skipped; leaves in the
        // unchanged prefix sit at positions ≤ the bind's lowerBound and were
        // never touched by propagation, so their values and positions both
        // still match ``freshTree``.
        //
        // - Complexity: zero when delta is zero. Otherwise O(*L*) leaves +
        //   one ``ChoiceSequence(freshTree)`` flatten, where the per-leaf
        //   inner work is gated on ``range.lowerBound > newBoundUpper``.
        if lengthDelta != 0 {
            propagatePositionShift(
                after: oldBoundRange.upperBound,
                delta: lengthDelta,
                excluding: oldBoundNodeIDs.union(application.addedNodeIDs)
            )
            application.positionShifts.append((insertionPoint: oldBoundRange.upperBound, delta: lengthDelta))

            let newBoundUpper = oldBoundRange.upperBound + lengthDelta
            let freshSequence = ChoiceSequence(freshTree)
            for index in nodes.indices {
                if isTombstoned(index) { continue }
                if application.addedNodeIDs.contains(index) { continue }
                guard case let .chooseBits(metadata) = nodes[index].kind else { continue }
                guard let range = nodes[index].positionRange else { continue }
                // Only propagated leaves (now strictly past the new bound's
                // last position) can hold a stale value relative to the
                // post-mutation tree.
                guard range.lowerBound > newBoundUpper else { continue }
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
                nodes[index] = ChoiceGraphNode(
                    id: nodes[index].id,
                    kind: .chooseBits(updated),
                    positionRange: nodes[index].positionRange,
                    children: nodes[index].children,
                    parent: nodes[index].parent
                )
            }
        }

        // Step 9: refresh structural-constancy on the bind. The new subtree
        // may have flipped from "constant" to "non-constant" or vice versa
        // depending on whether it contains nested binds or picks.
        let newIsStructurallyConstant = newBoundSubtree.containsBind == false
            && newBoundSubtree.containsPicks == false
        if newIsStructurallyConstant != bindMetadata.isStructurallyConstant {
            nodes[bindNodeID] = ChoiceGraphNode(
                id: bindNodeID,
                kind: .bind(BindMetadata(
                    isStructurallyConstant: newIsStructurallyConstant,
                    bindDepth: bindMetadata.bindDepth,
                    innerChildIndex: bindMetadata.innerChildIndex,
                    boundChildIndex: bindMetadata.boundChildIndex
                )),
                positionRange: nodes[bindNodeID].positionRange,
                children: nodes[bindNodeID].children,
                parent: nodes[bindNodeID].parent
            )
        }

        // Step 10: recompute self-similarity edges from scratch. The splice
        // may have removed picks from the old subtree and added picks in the
        // new subtree; the existing edge set is now incomplete (no edges to
        // new picks, may have edges to picks that no longer have valid IDs
        // — actually those were dropped above). Recomputing is O(picks²)
        // where pick count is in the dozens, so much cheaper than a full
        // graph rebuild.
        recomputeSelfSimilarityEdges()

        // Step 11: invalidate caches. Topological order and reachability
        // depend on dependency edges (which we just modified). Type-compat
        // and source/sink depend on leaf values (the value-only path
        // already calls ``invalidateDerivedEdges``; calling it twice is
        // idempotent).
        invalidateTopologicalCaches()
        invalidateDerivedEdges()

        application.touchedNodeIDs.insert(bindNodeID)
    }

    // MARK: - Bind Reshape Helpers

    /// Recomputes the self-similarity edge set from scratch from the live (non-tombstoned) active pick nodes.
    ///
    /// Used by ``applyBindReshape(forLeaf:freshTree:into:)`` after splicing in a new bound subtree, since the splice may have removed picks from the old region and added picks in the new region. Mirrors the self-similarity computation in ``ChoiceGraphBuilder/assembleGraph()``.
    ///
    /// - Complexity: O(*p*²) where *p* is the number of active pick nodes. Pick counts are typically in the dozens, so this is much cheaper than a full ``ChoiceGraph/build(from:)`` call.
    func recomputeSelfSimilarityEdges() {
        selfSimilarityEdges.removeAll(keepingCapacity: true)
        var picksByMaskedSiteID: [UInt64: [Int]] = [:]
        for node in nodes {
            guard isTombstoned(node.id) == false else { continue }
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            picksByMaskedSiteID[metadata.depthMaskedSiteID, default: []].append(node.id)
        }
        for (_, pickIDs) in picksByMaskedSiteID where pickIDs.count >= 2 {
            var indexA = 0
            while indexA < pickIDs.count {
                var indexB = indexA + 1
                while indexB < pickIDs.count {
                    let sizeA = nodes[pickIDs[indexA]].positionRange?.count ?? 0
                    let sizeB = nodes[pickIDs[indexB]].positionRange?.count ?? 0
                    selfSimilarityEdges.append(SelfSimilarityEdge(
                        nodeA: pickIDs[indexA],
                        nodeB: pickIDs[indexB],
                        sizeDelta: sizeA - sizeB
                    ))
                    indexB += 1
                }
                indexA += 1
            }
        }
    }

    /// Walks bind nodes in the live graph (skipping tombstones) and returns the bind whose `innerChildIndex`-indexed child is `leafNodeID`, or nil.
    private func controllingBind(forInnerLeaf leafNodeID: Int) -> Int? {
        for node in nodes {
            guard isTombstoned(node.id) == false else { continue }
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            if node.children[metadata.innerChildIndex] == leafNodeID {
                return node.id
            }
        }
        return nil
    }

    /// Shifts the `positionRange` of every live node whose range starts strictly after `insertionPoint` by `delta`. Nodes whose range *contains* `insertionPoint` (the changed subtree's ancestors) get their `upperBound` extended by `delta`. Sequence nodes additionally have their `childPositionRanges` metadata shifted in lockstep.
    ///
    /// `excluding` is the set of node IDs that belong to the rebuilt subtree itself — those nodes are already laid out at the correct offsets by ``ChoiceGraphBuilder/buildSubtree(from:startingOffset:parent:bindDepth:nodeIDOffset:)`` and must not be shifted again.
    private func propagatePositionShift(
        after insertionPoint: Int,
        delta: Int,
        excluding: Set<Int>
    ) {
        if delta == 0 { return }
        for index in nodes.indices {
            if isTombstoned(index) { continue }
            if excluding.contains(index) { continue }
            let node = nodes[index]
            guard let range = node.positionRange else { continue }

            let newRange: ClosedRange<Int>
            if range.lowerBound > insertionPoint {
                // Right of the change: shift both bounds.
                newRange = (range.lowerBound + delta) ... (range.upperBound + delta)
            } else if range.upperBound >= insertionPoint {
                // Contains the change: extend upperBound only.
                newRange = range.lowerBound ... (range.upperBound + delta)
            } else {
                continue
            }

            // Sequence nodes also store per-child extents that move with
            // the same shift rule.
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
                    childPositionRanges: shiftedChildRanges
                ))
            } else {
                updatedKind = node.kind
            }

            nodes[index] = ChoiceGraphNode(
                id: node.id,
                kind: updatedKind,
                positionRange: newRange,
                children: node.children,
                parent: node.parent
            )
        }
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
        selfSimilarityEdges.removeAll { nodeIDs.contains($0.nodeA) || nodeIDs.contains($0.nodeB) }
        invalidateDerivedEdges()
    }

    /// Sets position ranges to nil for all nodes in a subtree.
    func depopulateSubtree(rootID: Int) {
        var stack = [rootID]
        while stack.isEmpty == false {
            let current = stack.removeLast()
            guard current < nodes.count else { continue }
            let node = nodes[current]
            nodes[current] = ChoiceGraphNode(
                id: node.id,
                kind: node.kind,
                positionRange: nil,
                children: node.children,
                parent: node.parent
            )
            for child in node.children {
                stack.append(child)
            }
        }
    }
}
