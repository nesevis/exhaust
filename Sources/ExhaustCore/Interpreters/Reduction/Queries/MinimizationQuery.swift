//
//  MinimizationQuery.swift
//  Exhaust
//

// MARK: - Minimization Scope Query

/// Static scope builder for minimization operations.
///
/// Replaces the former `ChoiceGraph.minimizationScopes()` instance method. The builder is a free function over a ``ChoiceGraph`` so that callers that also need ``ExchangeQuery`` can share a single ``QueryHelpers/buildInnerDescendantToBind(graph:)`` allocation.
enum MinimizationQuery {
    /// Computes minimization scopes: one integer scope, one float scope, and one bound value scope per non-constant reduction edge.
    ///
    /// - Parameters:
    ///   - graph: The current choice graph.
    ///   - innerDescendantToBind: Precomputed bind-inner index from ``QueryHelpers/buildInnerDescendantToBind(graph:)``. Pass a shared instance when also building exchange scopes so the same dictionary is reused across both families.
    /// - Returns: All minimization scopes, each ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    static func build(
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int],
        deferBindInner: Bool = false
    ) -> [MinimizationScope] {
        var scopes: [MinimizationScope] = []

        let bindDepthByLeaf = QueryHelpers.buildBindDepthByLeaf(
            graph: graph,
            innerDescendantToBind: innerDescendantToBind
        )

        // Integer leaves.
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]

        // Float leaves.
        var floatLeafNodeIDs: [Int] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
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
                    graph: graph,
                    innerDescendantToBind: innerDescendantToBind
                )
                integerLeafNodeIDs.append(nodeID)
                integerValueYields[nodeID] = valueYield
            }
        }

        // Sort integer leaves by value yield descending.
        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        // Partition integer leaves into bind-inner and independent scopes. Bind-inner leaves require guided materialization (their value changes reshape bound subtrees); independent leaves use exact materialization. Mixing them in one scope forces guided mode for all leaves in batch phases.
        //
        // Depth-control leaves (TypeTag.depthControl) are excluded entirely. Reducing them through value search collapses recursive layers, destroying structural context (branch pivots) that substitution needs to converge to the optimal counterexample. Structural operations handle depth reduction while preserving structural integrity.
        if integerLeafNodeIDs.isEmpty == false {
            var bindInnerEntries: [LeafEntry] = []
            var independentEntries: [LeafEntry] = []
            for nodeID in integerLeafNodeIDs {
                if case let .chooseBits(metadata) = graph.nodes[nodeID].kind,
                   case .depthControl = metadata.typeTag
                {
                    continue
                }
                let entry = QueryHelpers.makeLeafEntry(
                    nodeID,
                    innerDescendantToBind: innerDescendantToBind,
                    bindDepthByLeaf: bindDepthByLeaf
                )
                if entry.mayReshapeOnAcceptance {
                    if deferBindInner == false {
                        bindInnerEntries.append(entry)
                    }
                } else {
                    independentEntries.append(entry)
                }
            }
            if independentEntries.isEmpty == false {
                scopes.append(.valueLeaves(ValueMinimizationScope(
                    leaves: independentEntries,
                    batchZeroEligible: independentEntries.count > 1
                )))
            }
            if bindInnerEntries.isEmpty == false {
                // Depth-partitioned ordering: group bind-inner leaves by bindDepth, emit shallowest first. Within each depth level, smallest downstream effect first (contravariant relative to yield). Top-down ordering ensures that by the time a leaf is searched, all its upstream ancestors are already converged — no cascade restarts from upstream acceptances invalidating downstream searches.
                let grouped = Dictionary(grouping: bindInnerEntries) { $0.bindDepth ?? 0 }
                for depth in grouped.keys.sorted() {
                    var depthEntries = grouped[depth]!
                    depthEntries.sort { ($0.bindDepth ?? 0) < ($1.bindDepth ?? 0) }
                    scopes.append(.valueLeaves(ValueMinimizationScope(
                        leaves: depthEntries,
                        batchZeroEligible: depthEntries.count > 1
                    )))
                }
            }
        }

        if floatLeafNodeIDs.isEmpty == false {
            var bindInnerFloats: [LeafEntry] = []
            var independentFloats: [LeafEntry] = []
            for nodeID in floatLeafNodeIDs {
                let entry = QueryHelpers.makeLeafEntry(
                    nodeID,
                    innerDescendantToBind: innerDescendantToBind,
                    bindDepthByLeaf: bindDepthByLeaf
                )
                if entry.mayReshapeOnAcceptance {
                    if deferBindInner == false {
                        bindInnerFloats.append(entry)
                    }
                } else {
                    independentFloats.append(entry)
                }
            }
            if independentFloats.isEmpty == false {
                scopes.append(.floatLeaves(FloatMinimizationScope(leaves: independentFloats)))
            }
            if bindInnerFloats.isEmpty == false {
                scopes.append(.floatLeaves(FloatMinimizationScope(leaves: bindInnerFloats)))
            }
        }

        // Bound value: one scope per bind node with an active inner child. Does NOT filter on ``isStructurallyConstant``: a structurally constant bind can still carry domain-dependent values whose ranges shift with the upstream value (Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))` is the canonical example). The composition's downstream encoder finds these via the lift's bound value coverage. Dispatch is gated per-site by ``ChoiceGraph/classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)`` in the scheduler, which rejects topology-divergent binds (Calculator's `.recursive`) before any probe runs.
        //
        // Deferred when structural reduction is still active: bound value compositions probe bind-inner values, which trigger reshapes that interleave with and invalidate structural search. Deferral avoids probing nodes that will be structurally removed.
        guard deferBindInner == false else { return scopes }
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            guard graph.nodes[innerChildID].positionRange != nil else { continue }

            let downstreamNodeIDs = collectDescendantLeaves(
                from: boundChildID,
                graph: graph
            )
            let boundSubtreeSize = graph.nodes[boundChildID].positionRange?.count ?? 0
            scopes.append(.boundValue(BoundValueScope(
                bindNodeID: findParentBind(of: innerChildID, graph: graph) ?? innerChildID,
                upstreamLeafNodeID: innerChildID,
                downstreamNodeIDs: downstreamNodeIDs,
                boundSubtreeSize: boundSubtreeSize
            )))
        }

        return scopes
    }

    /// Convenience overload that builds ``QueryHelpers/buildInnerDescendantToBind(graph:)`` on the caller's behalf. Prefer the primary overload when also building exchange scopes so the index is computed once and shared.
    static func build(graph: ChoiceGraph, deferBindInner: Bool = false) -> [MinimizationScope] {
        build(
            graph: graph,
            innerDescendantToBind: QueryHelpers.buildInnerDescendantToBind(graph: graph),
            deferBindInner: deferBindInner
        )
    }

    // MARK: - Private Helpers

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner, otherwise zero.
    ///
    /// Bind-inner leaves are sorted first in the integer scope because their mutations have the largest downstream effect — changing the inner value rebuilds the entire bound subtree. Independent of ``BindMetadata/isStructurallyConstant``: a "structurally constant" bind in the no-nested-binds-or-picks sense (for example, Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`) can still carry domain-dependent values whose ranges and lengths shift with the inner, so changing the inner is still a high-yield mutation.
    private static func computeValueYield(
        leafNodeID: Int,
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerDescendantToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return 0 }
        guard graph.nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Collects all leaf node IDs (chooseBits with non-nil position range) within the subtree rooted at the given node.
    private static func collectDescendantLeaves(
        from rootNodeID: Int,
        graph: ChoiceGraph
    ) -> [Int] {
        var result: [Int] = []
        var stack = [rootNodeID]
        while let current = stack.popLast() {
            let node = graph.nodes[current]
            if case .chooseBits = node.kind, node.positionRange != nil {
                result.append(current)
            }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// Finds the parent bind node of a given node, or nil.
    private static func findParentBind(of nodeID: Int, graph: ChoiceGraph) -> Int? {
        var current = nodeID
        while let parentID = graph.nodes[current].parent {
            if case .bind = graph.nodes[parentID].kind {
                return parentID
            }
            current = parentID
        }
        return nil
    }
}
