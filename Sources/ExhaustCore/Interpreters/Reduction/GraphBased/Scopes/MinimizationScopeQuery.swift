//
//  MinimizationScopeQuery.swift
//  Exhaust
//

// MARK: - Minimization Scope Query

/// Static scope builder for minimization operations.
///
/// Replaces the former `ChoiceGraph.minimizationScopes()` instance method. The builder is a free function over a ``ChoiceGraph`` so that callers that also need ``ExchangeScopeQuery`` can share a single ``ScopeQueryHelpers/buildInnerChildToBind(graph:)`` allocation.
enum MinimizationScopeQuery {
    /// Computes minimization scopes: one integer scope, one float scope, and one bound value scope per non-constant reduction edge.
    ///
    /// - Parameters:
    ///   - graph: The current choice graph.
    ///   - innerChildToBind: Precomputed bind-inner index from ``ScopeQueryHelpers/buildInnerChildToBind(graph:)``. Pass a shared instance when also building exchange scopes so the same dictionary is reused across both families.
    /// - Returns: All minimization scopes, each ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    static func build(
        graph: ChoiceGraph,
        innerChildToBind: [Int: Int]
    ) -> [MinimizationScope] {
        var scopes: [MinimizationScope] = []

        // Integer leaves.
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]

        // Float leaves.
        var floatLeafNodeIDs: [Int] = []

        for node in graph.nodes {
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }

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
                floatLeafNodeIDs.append(node.id)
            } else {
                let valueYield = computeValueYield(
                    leafNodeID: node.id,
                    graph: graph,
                    innerChildToBind: innerChildToBind
                )
                integerLeafNodeIDs.append(node.id)
                integerValueYields[node.id] = valueYield
            }
        }

        // Sort integer leaves by value yield descending.
        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        if integerLeafNodeIDs.isEmpty == false {
            let entries = integerLeafNodeIDs.map { nodeID in
                ScopeQueryHelpers.makeLeafEntry(nodeID, innerChildToBind: innerChildToBind)
            }
            scopes.append(.valueLeaves(ValueMinimizationScope(
                leaves: entries,
                batchZeroEligible: entries.count > 1
            )))
        }

        if floatLeafNodeIDs.isEmpty == false {
            let entries = floatLeafNodeIDs.map { nodeID in
                ScopeQueryHelpers.makeLeafEntry(nodeID, innerChildToBind: innerChildToBind)
            }
            scopes.append(.floatLeaves(FloatMinimizationScope(leaves: entries)))
        }

        // bound value: one scope per reduction edge. Matches the CDG's
        // ``ChoiceDependencyGraph/reductionEdges()`` behavior, which deliberately does
        // NOT filter on ``isStructurallyConstant``: a structurally constant bind (no
        // nested binds/picks) can still carry domain-dependent values whose ranges
        // shift with the upstream value (Coupling's `int(in: 0...n).array(length: 2 ...
        // max(2, n+1))` is the canonical example — the bound subtree contains only
        // plain choices, but their ranges depend on `n`). The composition's downstream
        // encoder finds these via the lift's fibre coverage.
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
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

    /// Convenience overload that builds ``ScopeQueryHelpers/buildInnerChildToBind(graph:)`` on the caller's behalf. Prefer the primary overload when also building exchange scopes so the index is computed once and shared.
    static func build(graph: ChoiceGraph) -> [MinimizationScope] {
        build(
            graph: graph,
            innerChildToBind: ScopeQueryHelpers.buildInnerChildToBind(graph: graph)
        )
    }

    // MARK: - Private Helpers

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner, otherwise zero.
    ///
    /// Bind-inner leaves are sorted first in the integer scope because their mutations have the largest downstream effect — changing the inner value rebuilds the entire bound subtree. Independent of ``BindMetadata/isStructurallyConstant``: a "structurally constant" bind in the no-nested-binds-or-picks sense (for example, Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`) can still carry domain-dependent values whose ranges and lengths shift with the inner, so changing the inner is still a high-yield mutation.
    private static func computeValueYield(
        leafNodeID: Int,
        graph: ChoiceGraph,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
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
