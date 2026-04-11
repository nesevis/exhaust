//
//  ChoiceGraph+RemovalScopes.swift
//  Exhaust
//

// MARK: - Removal Scope Queries

extension ChoiceGraph {
    /// Computes element removal scopes for all sequence nodes with deletable elements.
    ///
    /// Returns per-parent scopes (single target) only. Aligned removal across sibling sequences under zip nodes is handled separately by ``coveringAlignedRemovalScopes()``, which uses a covering array generator instead of exponential subset enumeration.
    ///
    /// - Returns: One scope per sequence node with deletable elements.
    func elementRemovalScopes() -> [ElementRemovalScope] {
        perParentElementScopes()
    }

    // MARK: - Per-Parent Element Scopes

    /// Computes per-parent removal scopes for all sequence nodes with deletable elements.
    ///
    /// Groups deletable elements by their parent sequence node. Each scope contains a single ``SequenceRemovalTarget`` with elements in position order.
    private func perParentElementScopes() -> [ElementRemovalScope] {
        var parentGroups: [Int: [Int]] = [:]

        for node in nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            parentGroups[parentID, default: []].append(node.id)
        }

        return parentGroups.sorted(by: { $0.key < $1.key }).map { parentID, elementNodeIDs in
            let sortedElements = elementNodeIDs.sorted { nodeA, nodeB in
                let rangeA = nodes[nodeA].positionRange?.lowerBound ?? 0
                let rangeB = nodes[nodeB].positionRange?.lowerBound ?? 0
                return rangeA < rangeB
            }
            let maxElementYield = sortedElements.reduce(0) { maxSoFar, nodeID in
                max(maxSoFar, nodes[nodeID].positionRange?.count ?? 0)
            }
            let deletable: Int
            if case let .sequence(metadata) = nodes[parentID].kind {
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
    func coveringAlignedRemovalScopes() -> [CoveringAlignedRemovalScope] {
        var scopes: [CoveringAlignedRemovalScope] = []
        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let allSequenceChildren = node.children.compactMap { childID -> CoveringAlignedRemovalScope.AlignedSibling? in
                guard let sequenceNodeID = findSequenceBeneath(childID) else { return nil }
                let sequenceNode = nodes[sequenceNodeID]
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
                    max(innerMax, nodes[nodeID].positionRange?.count ?? 0)
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

    // MARK: - Transparent Wrapper Traversal

    /// Walks through transparent wrappers (groups, structurally-constant binds) beneath a node to find the first sequence node.
    ///
    /// Returns the sequence node's ID, or nil if no sequence is found beneath the transparent chain. Used by both removal scope construction (aligned deletion) and exchange scope construction (cross-zip homogeneous redistribution).
    func findSequenceBeneath(_ nodeID: Int) -> Int? {
        let node = nodes[nodeID]
        if case .sequence = node.kind {
            return nodeID
        }
        switch node.kind {
        case .zip:
            for childID in node.children {
                if let found = findSequenceBeneath(childID) {
                    return found
                }
            }
            return nil
        case let .bind(metadata):
            if metadata.isStructurallyConstant, node.children.count >= 2 {
                let boundChildID = node.children[metadata.boundChildIndex]
                return findSequenceBeneath(boundChildID)
            }
            return nil
        case .chooseBits, .pick, .just:
            return nil
        case .sequence:
            return nodeID
        }
    }

    /// Computes subtree removal scopes for compound structural nodes in the deletion antichain.
    ///
    /// Targets nodes with ``ChoiceGraphNode/positionRange`` count greater than one — bind subtrees, zip children, and other compound elements worth removing as a unit.
    ///
    /// - Returns: One scope per compound node in the deletion antichain.
    func subtreeRemovalScopes() -> [SubtreeRemovalScope] {
        deletionAntichain.compactMap { nodeID in
            guard let range = nodes[nodeID].positionRange else { return nil }
            guard range.count > 1 else { return nil }
            return SubtreeRemovalScope(nodeID: nodeID, yield: range.count)
        }
    }
}
