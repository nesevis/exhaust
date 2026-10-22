//
//  RemovalQuery.swift
//  Exhaust
//

// MARK: - Removal Scope Query

/// Static scope builder for removal operations (element removal and covering array backed aligned removal).
enum RemovalQuery {
    /// Computes element removal scopes for all sequence nodes with deletable elements.
    ///
    /// Returns per-parent scopes (single target) only. Aligned removal across sibling sequences under zip nodes is handled separately by ``coveringAlignedRemovalScopes(graph:)``, which uses a covering array generator instead of exponential subset enumeration.
    ///
    /// - Returns: One scope per sequence node with deletable elements.
    static func elementRemovalScopes(graph: ChoiceGraph) -> [ElementRemovalScope] {
        perParentElementScopes(graph: graph)
    }

    // MARK: - Per-Parent Element Scopes

    /// Computes per-parent removal scopes for all sequence nodes with deletable elements.
    ///
    /// Visits sequences in node order and their active children in element order, both established by the graph builder. Each scope contains a single ``SequenceRemovalTarget``.
    private static func perParentElementScopes(graph: ChoiceGraph) -> [ElementRemovalScope] {
        var scopes: [ElementRemovalScope] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind else {
                continue
            }
            let minimumLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minimumLength else {
                continue
            }
            var elementNodeIDs: [Int] = []
            var maximumElementYield = 0
            for childID in node.children {
                guard let range = graph.nodes[childID].positionRange else {
                    continue
                }
                elementNodeIDs.append(childID)
                maximumElementYield = max(maximumElementYield, range.count)
            }
            guard elementNodeIDs.isEmpty == false else {
                continue
            }
            scopes.append(ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: nodeID,
                    elementNodeIDs: elementNodeIDs
                )],
                maxBatch: metadata.elementCount - Int(minimumLength),
                maxElementYield: maximumElementYield
            ))
        }
        return scopes
    }

    // MARK: - Covering Aligned Removal Scopes

    /// Computes covering array backed aligned removal scopes for all zip nodes with multiple deletable sequence children.
    ///
    /// Each zip node with two or more deletable sibling sequences produces one ``CoveringAlignedRemovalScope``. The scope contains a ``BalancedCoveringArrayGenerator`` whose parameters are the sibling sequences and whose domains are `elementCount + 1` (the extra value encodes "skip this sibling"). The encoder pulls rows from the generator, decoding each into an element deletion combination with pairwise interaction coverage.
    ///
    /// - Complexity: O(S) per zip node to build the generator, where S is the sibling count. The generator itself produces O(max(domain)^2 * log(S)) rows on demand, replacing the previous O(2^S) subset enumeration and O(nA * nB) cross-product expansion.
    static func coveringAlignedRemovalScopes(graph: ChoiceGraph) -> [CoveringAlignedRemovalScope] {
        var scopes: [CoveringAlignedRemovalScope] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case .zip = node.kind else {
                continue
            }

            let allSequenceChildren = node.children.compactMap { childID -> CoveringAlignedRemovalScope.AlignedSibling? in
                guard let sequenceNodeID = QueryHelpers.findSequenceBeneath(childID, graph: graph) else {
                    return nil
                }
                let sequenceNode = graph.nodes[sequenceNodeID]
                guard case let .sequence(metadata) = sequenceNode.kind else {
                    return nil
                }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else {
                    return nil
                }
                return CoveringAlignedRemovalScope.AlignedSibling(
                    sequenceNodeID: sequenceNodeID,
                    elementNodeIDs: sequenceNode.children
                )
            }
            guard allSequenceChildren.count >= 2 else {
                continue
            }

            // Each sibling becomes a parameter with domain = elementCount + 1.
            // The extra value (= elementCount) encodes "skip this sibling."
            let domainSizes = allSequenceChildren.map { UInt64($0.elementNodeIDs.count + 1) }
            let skipValues = allSequenceChildren.map { UInt64($0.elementNodeIDs.count) }

            let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)

            let maxElementYield = allSequenceChildren.reduce(0) { maxSoFar, sibling in
                let siblingMax = sibling.elementNodeIDs.reduce(0) { innerMax, nodeID in
                    max(innerMax, graph.nodes[nodeID].positionRange?.count ?? 0)
                }
                return max(maxSoFar, siblingMax)
            }

            scopes.append(CoveringAlignedRemovalScope(
                siblings: allSequenceChildren,
                generator: generator,
                skipValues: skipValues,
                maxElementYield: maxElementYield
            ))
        }
        return scopes
    }

    // MARK: - Subtree Removal Scopes
}
