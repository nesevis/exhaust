//
//  MinimizationQuery.swift
//  Exhaust
//

// MARK: - Minimization Scope Query

/// Static scope builder for minimization operations.
enum MinimizationQuery {
    /// Computes minimization scopes: one integer scope, one float scope, and one bound value scope per non-constant reduction edge.
    ///
    /// Reads ``ScopeAnnotation`` on each node for bind-inner classification and depth ordering instead of building a separate index.
    static func build(
        graph: ChoiceGraph,
        deferBindInner: Bool = false
    ) -> [MinimizationScope] {
        var scopes: [MinimizationScope] = []

        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]
        var floatLeafNodeIDs: [Int] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }

            if let converged = metadata.convergedOrigin,
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

        // Partition integer leaves into bind-inner and independent scopes. Depth-control leaves are excluded entirely.
        if integerLeafNodeIDs.isEmpty == false {
            var bindInnerEntries: [LeafEntry] = []
            var independentEntries: [LeafEntry] = []
            for nodeID in integerLeafNodeIDs {
                let annotation = graph.nodes[nodeID].scopeAnnotation
                if annotation.isDepthControl { continue }
                let entry = LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: annotation.isBindInner,
                    bindDepth: annotation.controllingBindDepth
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
                let annotation = graph.nodes[nodeID].scopeAnnotation
                let entry = LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: annotation.isBindInner,
                    bindDepth: annotation.controllingBindDepth
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

        // Bound value: one scope per bind node with an active inner child.
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

    // MARK: - Private Helpers

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
