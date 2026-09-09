//
//  MinimizationQuery.swift
//  Exhaust
//

// MARK: - Minimization Scope Query

/// Static scope builder for minimization operations.
enum MinimizationQuery {
    /// Computes minimization scopes: one integer scope, one float scope, and one bound value scope per non-constant reduction edge.
    ///
    /// Reads ``ScopeAnnotation`` on each node for bind-inner classification and depth ordering instead of building a separate index. With `deferBindInner` the result is the independent scopes alone; without it the scopes ``deferredScopes(graph:stopAtFirst:)`` describes are added, interleaved by kind after the independent scope of the same kind.
    static func build(
        graph: ChoiceGraph,
        deferBindInner: Bool = false
    ) -> [MinimizationScope] {
        let leaves = partitionLeaves(graph: graph)
        let deferred = deferBindInner
            ? DeferredScopes()
            : deferredScopes(from: leaves, graph: graph, stopAtFirst: false)

        var scopes: [MinimizationScope] = []
        if leaves.independentIntegers.isEmpty == false {
            scopes.append(.valueLeaves(ValueMinimizationScope(
                leaves: leaves.independentIntegers,
                batchZeroEligible: leaves.independentIntegers.count > 1
            )))
        }
        scopes += deferred.integerScopes
        if leaves.independentFloats.isEmpty == false {
            scopes.append(.floatLeaves(FloatMinimizationScope(leaves: leaves.independentFloats)))
        }
        scopes += deferred.floatScopes
        scopes += deferred.bindScopes
        return scopes
    }

    /// The scopes that releasing the bind-inner deferral adds: bind-inner integer leaves grouped by controlling bind depth, bind-inner float leaves, and per bind an ungated bind pivot for every alternative branch of every active pick in its inner subtree plus, for a `chooseBits` inner, a bound value scope. With `stopAtFirst` the walk returns at the first scope found, which is how the machine asks whether the release deserves a cycle.
    static func deferredScopes(graph: ChoiceGraph, stopAtFirst: Bool) -> [MinimizationScope] {
        deferredScopes(from: partitionLeaves(graph: graph), graph: graph, stopAtFirst: stopAtFirst).all
    }

    // MARK: - Private Helpers

    /// Leaves off their reduction target and not converged there, split by type and by whether they are a bind inner. Integer leaves are ordered by value yield, and depth-control and lane-control integers are left out entirely.
    private struct LeafPartition {
        var independentIntegers: [LeafEntry] = []
        var bindInnerIntegers: [LeafEntry] = []
        var independentFloats: [LeafEntry] = []
        var bindInnerFloats: [LeafEntry] = []
    }

    private static func partitionLeaves(graph: ChoiceGraph) -> LeafPartition {
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]
        var floatLeafNodeIDs: [Int] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }

            if let converged = graph.convergenceStore[nodeID],
               converged.bound == currentBitPattern
            {
                continue
            }

            if metadata.typeTag.isFloatingPoint {
                floatLeafNodeIDs.append(nodeID)
            } else {
                let valueYield = computeValueYield(leafNodeID: nodeID, graph: graph)
                integerLeafNodeIDs.append(nodeID)
                integerValueYields[nodeID] = valueYield
            }
        }

        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        var partition = LeafPartition()
        for nodeID in integerLeafNodeIDs {
            let annotation = graph.nodes[nodeID].scopeAnnotation
            if annotation.isDepthControl || annotation.isLaneControl { continue }
            let entry = LeafEntry(
                nodeID: nodeID,
                mayReshapeOnAcceptance: annotation.isBindInner,
                bindDepth: annotation.controllingBindDepth
            )
            if entry.mayReshapeOnAcceptance {
                partition.bindInnerIntegers.append(entry)
            } else {
                partition.independentIntegers.append(entry)
            }
        }
        for nodeID in floatLeafNodeIDs {
            let annotation = graph.nodes[nodeID].scopeAnnotation
            let entry = LeafEntry(
                nodeID: nodeID,
                mayReshapeOnAcceptance: annotation.isBindInner,
                bindDepth: annotation.controllingBindDepth
            )
            if entry.mayReshapeOnAcceptance {
                partition.bindInnerFloats.append(entry)
            } else {
                partition.independentFloats.append(entry)
            }
        }
        return partition
    }

    /// The deferred scopes by kind, so ``build(graph:deferBindInner:)`` can place each kind after the independent scope of the same kind.
    private struct DeferredScopes {
        var integerScopes: [MinimizationScope] = []
        var floatScopes: [MinimizationScope] = []
        var bindScopes: [MinimizationScope] = []

        var all: [MinimizationScope] {
            integerScopes + floatScopes + bindScopes
        }
    }

    private static func deferredScopes(
        from leaves: LeafPartition,
        graph: ChoiceGraph,
        stopAtFirst: Bool
    ) -> DeferredScopes {
        var scopes = DeferredScopes()

        if leaves.bindInnerIntegers.isEmpty == false {
            let grouped = Dictionary(grouping: leaves.bindInnerIntegers) { $0.bindDepth ?? 0 }
            for depth in grouped.keys.sorted() {
                var depthEntries = grouped[depth]!
                depthEntries.sort { ($0.bindDepth ?? 0) < ($1.bindDepth ?? 0) }
                scopes.integerScopes.append(.valueLeaves(ValueMinimizationScope(
                    leaves: depthEntries,
                    batchZeroEligible: depthEntries.count > 1
                )))
                if stopAtFirst {
                    return scopes
                }
            }
        }

        if leaves.bindInnerFloats.isEmpty == false {
            scopes.floatScopes.append(.floatLeaves(FloatMinimizationScope(leaves: leaves.bindInnerFloats)))
            if stopAtFirst {
                return scopes
            }
        }

        // Bound value and bind pivot: one scope per bind node with an active inner child, and one bind pivot per alternative branch of every pick in the inner subtree, ungated.
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            guard graph.nodes[innerChildID].positionRange != nil else { continue }

            let boundSubtreeSize = graph.nodes[boundChildID].positionRange?.count ?? 0
            if boundSubtreeSize > 0 {
                let estimatedProbes = estimatedBindPivotProbes(boundChildID: boundChildID, graph: graph)
                // No leaf-count gate on the alternatives, unlike branch pivot: an inner branch with more leaves can still shorten the sequence when the bound subtree it selects is smaller, and only the lifted candidate's length can tell. The encoder gates on that.
                for pickNodeID in collectActivePicks(from: innerChildID, graph: graph) {
                    guard case let .pick(pickMetadata) = graph.nodes[pickNodeID].kind else {
                        continue
                    }
                    for index in 0 ..< Int(pickMetadata.branchCount) {
                        let branchID = UInt64(index)
                        guard branchID != pickMetadata.selectedID else {
                            continue
                        }
                        scopes.bindScopes.append(.bindPivot(BindPivotScope(
                            bindNodeID: nodeID,
                            pickNodeID: pickNodeID,
                            targetBranchID: branchID,
                            boundSubtreeSize: boundSubtreeSize,
                            estimatedProbes: estimatedProbes
                        )))
                        if stopAtFirst {
                            return scopes
                        }
                    }
                }
            }

            // Bound value search needs a `chooseBits` inner: the classifier lifts the inner's range endpoints, and any other inner kind is unclassifiable and never dispatched.
            guard case .chooseBits = graph.nodes[innerChildID].kind else {
                continue
            }
            let downstreamNodeIDs = collectDescendantLeaves(
                from: boundChildID,
                graph: graph
            )
            scopes.bindScopes.append(.boundValue(BoundValueScope(
                bindNodeID: findParentBind(of: innerChildID, graph: graph) ?? innerChildID,
                upstreamLeafNodeID: innerChildID,
                downstreamNodeIDs: downstreamNodeIDs,
                boundSubtreeSize: boundSubtreeSize
            )))
            if stopAtFirst {
                return scopes
            }
        }

        return scopes
    }

    /// Probes a bind pivot on this bound subtree is expected to emit: per seed, the lifted sequence plus the covering rows ``BoundValueCoveringEncoder`` would build for the subtree's current leaves, exhaustive up to its threshold, otherwise its budget for several leaves and the smaller of the budget and the domain for one. Seeds are the plain pivot plus the transplant donors the encoder will try.
    private static func estimatedBindPivotProbes(boundChildID: Int, graph: ChoiceGraph) -> Int {
        guard let boundRange = graph.nodes[boundChildID].positionRange else {
            return 1
        }
        var domainSizes: [UInt64] = []
        for leafID in collectDescendantLeaves(from: boundChildID, graph: graph) {
            guard case let .chooseBits(metadata) = graph.nodes[leafID].kind,
                  let validRange = metadata.validRange
            else {
                continue
            }
            domainSizes.append(validRange.saturatingCount)
        }
        var totalSpace: UInt64 = 1
        for size in domainSizes {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: size)
            totalSpace = overflow ? UInt64.max : product
        }
        let rows: Int
        if domainSizes.isEmpty {
            rows = 0
        } else if totalSpace <= BoundValueCoveringEncoder.exhaustiveThreshold {
            rows = Int(totalSpace)
        } else if domainSizes.count == 1 {
            rows = Int(min(totalSpace, UInt64(BoundValueCoveringEncoder.coveringBudget)))
        } else {
            rows = BoundValueCoveringEncoder.coveringBudget
        }
        let donors = GraphBindPivotEncoder.transplantDonors(boundChildID: boundChildID, boundRange: boundRange, graph: graph)
        let seeds = 1 + donors.count
        return seeds * (1 + rows)
    }

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner, otherwise zero.
    private static func computeValueYield(
        leafNodeID: Int,
        graph: ChoiceGraph
    ) -> Int {
        let annotation = graph.nodes[leafNodeID].scopeAnnotation
        guard let bindNodeID = annotation.controllingBindNodeID else { return 0 }
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

    /// Active pick nodes in the containment subtree under `rootNodeID`, including `rootNodeID` itself. Inactive branch alternatives have nil position ranges and are not descended into, since a pick below an unselected branch cannot be pivoted in place.
    private static func collectActivePicks(
        from rootNodeID: Int,
        graph: ChoiceGraph
    ) -> [Int] {
        var result: [Int] = []
        var stack = [rootNodeID]
        while let current = stack.popLast() {
            let node = graph.nodes[current]
            guard node.positionRange != nil else {
                continue
            }
            if case let .pick(metadata) = node.kind,
               metadata.branchCount >= 2,
               node.children.count == Int(metadata.branchCount)
            {
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
