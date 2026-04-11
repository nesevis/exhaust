//
//  RemovalScopeQuery.swift
//  Exhaust
//

// MARK: - Removal Scope Query

/// Static scope builder for removal operations (element removal, covering-array-backed aligned removal, and structural subtree removal).
///
/// Replaces the former `ChoiceGraph.elementRemovalScopes()`, `coveringAlignedRemovalScopes()`, and `subtreeRemovalScopes()` instance methods.
enum RemovalScopeQuery {
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
    /// Groups deletable elements by their parent sequence node. Each scope contains a single ``SequenceRemovalTarget`` with elements in position order.
    private static func perParentElementScopes(graph: ChoiceGraph) -> [ElementRemovalScope] {
        var parentGroups: [Int: [Int]] = [:]

        for node in graph.nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            parentGroups[parentID, default: []].append(node.id)
        }

        return parentGroups.sorted(by: { $0.key < $1.key }).map { parentID, elementNodeIDs in
            let sortedElements = elementNodeIDs.sorted { nodeA, nodeB in
                let rangeA = graph.nodes[nodeA].positionRange?.lowerBound ?? 0
                let rangeB = graph.nodes[nodeB].positionRange?.lowerBound ?? 0
                return rangeA < rangeB
            }
            let maxElementYield = sortedElements.reduce(0) { maxSoFar, nodeID in
                max(maxSoFar, graph.nodes[nodeID].positionRange?.count ?? 0)
            }
            let deletable: Int
            if case let .sequence(metadata) = graph.nodes[parentID].kind {
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                deletable = metadata.elementCount - minLength
            } else {
                deletable = sortedElements.count
            }
            return ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: parentID,
                    elementNodeIDs: sortedElements
                )],
                maxBatch: deletable,
                maxElementYield: maxElementYield
            )
        }
    }

    // MARK: - Covering Aligned Removal Scopes

    /// Computes covering-array-backed aligned removal scopes for all zip nodes with multiple deletable sequence children.
    ///
    /// Each zip node with two or more deletable sibling sequences produces one ``CoveringAlignedRemovalScope``. The scope contains a strength-2 ``PullBasedCoveringArrayGenerator`` whose parameters are the sibling sequences and whose domains are `elementCount + 1` (the extra value encodes "skip this sibling"). The encoder pulls rows from the generator, decoding each into an element deletion combination with pairwise interaction coverage.
    ///
    /// - Complexity: O(S) per zip node to build the generator, where S is the sibling count. The generator itself produces O(max(domain)^2 * log(S)) rows on demand, replacing the previous O(2^S) subset enumeration and O(nA * nB) cross-product expansion.
    static func coveringAlignedRemovalScopes(graph: ChoiceGraph) -> [CoveringAlignedRemovalScope] {
        var scopes: [CoveringAlignedRemovalScope] = []
        for node in graph.nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let allSequenceChildren = node.children.compactMap { childID -> CoveringAlignedRemovalScope.AlignedSibling? in
                guard let sequenceNodeID = ScopeQueryHelpers.findSequenceBeneath(childID, graph: graph) else { return nil }
                let sequenceNode = graph.nodes[sequenceNodeID]
                guard case let .sequence(metadata) = sequenceNode.kind else { return nil }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else { return nil }
                return CoveringAlignedRemovalScope.AlignedSibling(
                    sequenceNodeID: sequenceNodeID,
                    elementNodeIDs: sequenceNode.children
                )
            }
            guard allSequenceChildren.count >= 2 else { continue }

            // Each sibling becomes a parameter with domain = elementCount + 1.
            // The extra value (= elementCount) encodes "skip this sibling."
            let domainSizes = allSequenceChildren.map { UInt64($0.elementNodeIDs.count + 1) }
            let skipValues = allSequenceChildren.map { UInt64($0.elementNodeIDs.count) }

            let generator = PullBasedCoveringArrayGenerator(
                domainSizes: domainSizes,
                strength: 2
            )

            let maxElementYield = allSequenceChildren.reduce(0) { maxSoFar, sibling in
                let siblingMax = sibling.elementNodeIDs.reduce(0) { innerMax, nodeID in
                    max(innerMax, graph.nodes[nodeID].positionRange?.count ?? 0)
                }
                return max(maxSoFar, siblingMax)
            }

            scopes.append(CoveringAlignedRemovalScope(
                siblings: allSequenceChildren,
                handle: CoveringArrayHandle(generator: generator),
                skipValues: skipValues,
                maxElementYield: maxElementYield
            ))
        }
        return scopes
    }

    // MARK: - Subtree Removal Scopes

    /// Computes subtree removal scopes for compound structural nodes in the deletion antichain.
    ///
    /// Targets nodes with ``ChoiceGraphNode/positionRange`` count greater than one — bind subtrees, zip children, and other compound elements worth removing as a unit.
    ///
    /// - Returns: One scope per compound node in the deletion antichain.
    static func subtreeRemovalScopes(graph: ChoiceGraph) -> [SubtreeRemovalScope] {
        graph.deletionAntichain.compactMap { nodeID in
            guard let range = graph.nodes[nodeID].positionRange else { return nil }
            guard range.count > 1 else { return nil }
            return SubtreeRemovalScope(nodeID: nodeID, yield: range.count)
        }
    }
}
