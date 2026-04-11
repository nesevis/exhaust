//
//  ChoiceGraph+RemovalScopes.swift
//  Exhaust
//

// MARK: - Removal Scope Queries

extension ChoiceGraph {
    /// Computes element removal scopes for all sequence nodes with deletable elements and all aligned sibling groupings.
    ///
    /// Returns both per-parent scopes (single target) and aligned scopes (multiple targets under a common zip). The ``TransformationEnumerator`` feeds these into the priority queue; scope sources handle geometric halving and window placement.
    ///
    /// - Returns: One scope per sequence node with deletable elements, plus one per aligned sibling subset (size >= 2) per zip node.
    func elementRemovalScopes() -> [ElementRemovalScope] {
        var scopes: [ElementRemovalScope] = []

        // Per-parent scopes: one target per sequence.
        scopes.append(contentsOf: perParentElementScopes())

        // Aligned scopes: multiple targets across sibling sequences under zip nodes.
        scopes.append(contentsOf: alignedElementScopes())

        return scopes
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

    // MARK: - Aligned Element Scopes

    /// Intermediate type used during aligned scope computation.
    private struct SiblingInfo {
        let sequenceNodeID: Int
        let elementNodeIDs: [Int]
        let deletableCount: Int
    }

    /// Computes aligned removal scopes for all zip nodes with multiple sequence children, including partial sibling subsets.
    ///
    /// Looks through transparent wrappers (groups, structurally-constant binds) beneath each zip child to find the underlying sequence node. Generates scopes for all subsets of siblings of size two or more.
    private func alignedElementScopes() -> [ElementRemovalScope] {
        var scopes: [ElementRemovalScope] = []
        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let allSequenceChildren = node.children.compactMap { childID -> SiblingInfo? in
                guard let sequenceNodeID = findSequenceBeneath(childID) else { return nil }
                let sequenceNode = nodes[sequenceNodeID]
                guard case let .sequence(metadata) = sequenceNode.kind else { return nil }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else { return nil }
                return SiblingInfo(
                    sequenceNodeID: sequenceNodeID,
                    elementNodeIDs: sequenceNode.children,
                    deletableCount: deletable
                )
            }
            guard allSequenceChildren.count >= 2 else { continue }

            let subsets = siblingSubsets(allSequenceChildren)
            for subset in subsets {
                guard subset.map(\.deletableCount).allSatisfy({ $0 > 0 }) else { continue }
                if subset.count == 2 {
                    generateAlignedCrossProductScopes(
                        subset: subset,
                        siblingIndex: 0,
                        currentIndices: [],
                        into: &scopes
                    )
                } else {
                    let elementCount = subset.map(\.elementNodeIDs.count).min() ?? 0
                    for elementIndex in 0 ..< elementCount {
                        var targets: [SequenceRemovalTarget] = []
                        var totalYield = 0
                        var valid = true
                        for sibling in subset {
                            guard elementIndex < sibling.elementNodeIDs.count else { valid = false; break }
                            let nodeID = sibling.elementNodeIDs[elementIndex]
                            targets.append(SequenceRemovalTarget(
                                sequenceNodeID: sibling.sequenceNodeID,
                                elementNodeIDs: [nodeID]
                            ))
                            totalYield += nodes[nodeID].positionRange?.count ?? 0
                        }
                        guard valid else { continue }
                        scopes.append(ElementRemovalScope(
                            targets: targets,
                            maxBatch: 1,
                            maxElementYield: totalYield
                        ))
                    }
                }
            }
        }
        return scopes
    }

    private func siblingSubsets(_ siblings: [SiblingInfo]) -> [[SiblingInfo]] {
        let count = siblings.count
        guard count >= 2 else { return [] }
        var subsets: [[SiblingInfo]] = []
        for size in stride(from: count, through: 2, by: -1) {
            generateCombinations(siblings, choose: size, into: &subsets)
        }
        return subsets
    }

    private func generateCombinations(
        _ source: [SiblingInfo],
        choose: Int,
        into result: inout [[SiblingInfo]]
    ) {
        let count = source.count
        guard choose >= 1, choose <= count else { return }
        var indices = Array(0 ..< choose)
        while true {
            result.append(indices.map { source[$0] })
            var position = choose - 1
            while position >= 0, indices[position] == count - choose + position {
                position -= 1
            }
            if position < 0 { break }
            indices[position] += 1
            for subsequent in (position + 1) ..< choose {
                indices[subsequent] = indices[subsequent - 1] + 1
            }
        }
    }

    /// Recursively generates all cross-product combinations of one element index per sibling and emits one ``ElementRemovalScope`` per combination.
    private func generateAlignedCrossProductScopes(
        subset: [SiblingInfo],
        siblingIndex: Int,
        currentIndices: [Int],
        into scopes: inout [ElementRemovalScope]
    ) {
        guard siblingIndex < subset.count else {
            var targets: [SequenceRemovalTarget] = []
            var totalYield = 0
            for (sibling, index) in zip(subset, currentIndices) {
                let nodeID = sibling.elementNodeIDs[index]
                targets.append(SequenceRemovalTarget(
                    sequenceNodeID: sibling.sequenceNodeID,
                    elementNodeIDs: [nodeID]
                ))
                totalYield += nodes[nodeID].positionRange?.count ?? 0
            }
            scopes.append(ElementRemovalScope(
                targets: targets,
                maxBatch: 1,
                maxElementYield: totalYield
            ))
            return
        }
        let sibling = subset[siblingIndex]
        for index in 0 ..< sibling.elementNodeIDs.count {
            generateAlignedCrossProductScopes(
                subset: subset,
                siblingIndex: siblingIndex + 1,
                currentIndices: currentIndices + [index],
                into: &scopes
            )
        }
    }

    // MARK: - Transparent Wrapper Traversal

    /// Walks through transparent wrappers (groups, structurally-constant binds) beneath a node to find the first sequence node.
    ///
    /// Returns the sequence node's ID, or nil if no sequence is found beneath the transparent chain.
    private func findSequenceBeneath(_ nodeID: Int) -> Int? {
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
