//
//  ChoiceGraph+MinimizationScopes.swift
//  Exhaust
//

// MARK: - Minimization Scope Queries

extension ChoiceGraph {
    /// Computes minimization scopes: one integer scope, one float scope, and one Kleisli fibre scope per non-constant reduction edge.
    ///
    /// - Returns: All minimization scopes, each ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    func minimizationScopes() -> [MinimizationScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [MinimizationScope] = []

        // Integer leaves.
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]

        // Float leaves.
        var floatLeafNodeIDs: [Int] = []

        for nodeID in leafNodes {
            let node = nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }

            // Skip leaves at their convergence floor — no probe can move them closer to the target under the current graph structure. The signal type is irrelevant: whether convergence was monotone, non-monotone, or from a zeroing dependency, a leaf at its floor has no further search potential. A leaf whose value moved away from its floor (for example, after redistribution) passes this guard and re-enters value search with the surviving convergence record available as a warm-start bound.
            if let converged = metadata.convergedOrigin,
               converged.bound == currentBitPattern
            {
                continue
            }

            if metadata.typeTag.isFloatingPoint {
                floatLeafNodeIDs.append(nodeID)
            } else {
                let valueYield = computeValueYield(
                    leafNodeID: nodeID,
                    innerChildToBind: innerChildToBind
                )
                integerLeafNodeIDs.append(nodeID)
                integerValueYields[nodeID] = valueYield
            }
        }

        // Sort integer leaves by value yield descending.
        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        if integerLeafNodeIDs.isEmpty == false {
            let entries = integerLeafNodeIDs.map { nodeID in
                LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: isBindInner(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.valueLeaves(ValueMinimizationScope(
                leaves: entries,
                batchZeroEligible: entries.count > 1
            )))
        }

        if floatLeafNodeIDs.isEmpty == false {
            let entries = floatLeafNodeIDs.map { nodeID in
                LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: isBindInner(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.floatLeaves(FloatMinimizationScope(leaves: entries)))
        }

        // Kleisli fibre: one scope per reduction edge. Matches the CDG's
        // ``ChoiceDependencyGraph/reductionEdges()`` behaviour, which deliberately does
        // NOT filter on ``isStructurallyConstant``: a structurally constant bind (no
        // nested binds/picks) can still carry domain-dependent values whose ranges
        // shift with the upstream value (Coupling's `int(in: 0...n).array(length: 2 ...
        // max(2, n+1))` is the canonical example — the bound subtree contains only
        // plain choices, but their ranges depend on `n`). The composition's downstream
        // encoder finds these via the lift's fibre coverage.
        for edge in reductionEdges {
            guard nodes[edge.upstreamNodeID].positionRange != nil else { continue }
            let downstreamNodeIDs = collectDescendantLeaves(from: edge.downstreamNodeID)
            let boundSubtreeSize = nodes[edge.downstreamNodeID].positionRange?.count ?? 0
            scopes.append(.kleisliFibre(KleisliFibreScope(
                bindNodeID: findParentBind(of: edge.upstreamNodeID) ?? edge.upstreamNodeID,
                upstreamLeafNodeID: edge.upstreamNodeID,
                downstreamNodeIDs: downstreamNodeIDs,
                boundSubtreeSize: boundSubtreeSize
            )))
        }

        return scopes
    }

    // MARK: - Minimization Helpers

    /// Builds an index from inner-child node ID to its controlling bind node ID.
    func buildInnerChildToBind() -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            index[innerChildID] = node.id
        }
        return index
    }

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner, otherwise zero.
    ///
    /// Bind-inner leaves are sorted first in the integer scope because their mutations have the largest downstream effect — changing the inner value rebuilds the entire bound subtree. Independent of ``BindMetadata/isStructurallyConstant``: a "structurally constant" bind in the no-nested-binds-or-picks sense (for example, Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`) can still carry domain-dependent values whose ranges and lengths shift with the inner, so changing the inner is still a high-yield mutation.
    private func computeValueYield(
        leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = nodes[bindNodeID].kind else { return 0 }
        guard nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = nodes[bindNodeID].children[metadata.boundChildIndex]
        return nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Returns true when a leaf is the inner child of a bind. Any bind-inner mutation must route through ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` (not the value-only fast path) because the materialiser may produce a tree with a different bound-subtree shape — different array length, different value ranges, different content — even when the bind has no *nested* binds or picks.
    ///
    /// The previous predicate filtered on ``BindMetadata/isStructurallyConstant`` and missed Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`: the bound contains only plain choices (so `isStructurallyConstant == true`), but its length and element validRanges depend on `n`, so changing `n` changes the live tree's shape. The value-only fast path then left the graph holding the old bound subtree's nodes at positions that no longer corresponded to value entries in the live sequence, producing the position drift documented in `ExhaustDocs/graph-reducer-position-drift-bug.md`.
    ///
    /// Always treating bind-inner leaves as `mayReshape: true` is correct and simple. The cost is that the rare workloads where the bound subtree is genuinely shape-and-content-stable pay extra splice work; in exchange the splice path is the only place that handles bind-inner mutations and the contract is uniform.
    func isBindInner(
        _ leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Bool {
        innerChildToBind[leafNodeID] != nil
    }

    /// Wraps a leaf node ID in a ``LeafEntry`` with the bind-inner reshape marker populated from the supplied index.
    func makeLeafEntry(
        _ nodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> LeafEntry {
        LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: isBindInner(
                nodeID,
                innerChildToBind: innerChildToBind
            )
        )
    }

    /// Collects all leaf node IDs (chooseBits with non-nil position range) within the subtree rooted at the given node.
    private func collectDescendantLeaves(from rootNodeID: Int) -> [Int] {
        var result: [Int] = []
        var stack = [rootNodeID]
        while let current = stack.popLast() {
            let node = nodes[current]
            if case .chooseBits = node.kind, node.positionRange != nil {
                result.append(current)
            }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// Finds the parent bind node of a given node, or nil.
    private func findParentBind(of nodeID: Int) -> Int? {
        var current = nodeID
        while let parentID = nodes[current].parent {
            if case .bind = nodes[parentID].kind {
                return parentID
            }
            current = parentID
        }
        return nil
    }
}
