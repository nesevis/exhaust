//
//  ChoiceGraph+PermutationScopes.swift
//  Exhaust
//

// MARK: - Permutation Scope Queries

extension ChoiceGraph {
    /// Computes permutation scopes for zip nodes with same-shaped siblings.
    ///
    /// Groups children by structural shape derived from graph node metadata. Children with the same shape can be swapped for shortlex improvement.
    ///
    /// - Returns: One scope per zip node with at least one group of two or more same-shaped children.
    func permutationScopes() -> [PermutationScope] {
        var scopes: [PermutationScope] = []

        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard node.children.count >= 2 else { continue }

            var shapeGroups: [NodeShapeKey: [Int]] = [:]
            for childID in node.children {
                guard nodes[childID].positionRange != nil else { continue }
                let key = nodeShapeKey(nodes[childID])
                shapeGroups[key, default: []].append(childID)
            }

            let swappableGroups = shapeGroups.values
                .filter { $0.count >= 2 }
                .sorted { groupA, groupB in
                    let positionA = nodes[groupA[0]].positionRange?.lowerBound ?? 0
                    let positionB = nodes[groupB[0]].positionRange?.lowerBound ?? 0
                    return positionA < positionB
                }

            guard swappableGroups.isEmpty == false else { continue }

            scopes.append(.siblingPermutation(SiblingPermutationScope(
                zipNodeID: node.id,
                swappableGroups: swappableGroups
            )))
        }

        return scopes
    }

    // MARK: - Shape Key

    /// Lightweight shape discriminant for grouping siblings by structural kind.
    ///
    /// Derived from graph node metadata rather than the ``ChoiceTree``. Matches the grouping logic in ``GraphSiblingSwapEncoder``.
    private enum NodeShapeKey: Hashable {
        case value
        case sequence(elementCount: Int)
        case emptySequence
        case zip(childCount: Int)
        case bind
        case pick(branchCount: Int)
        case just
    }

    /// Computes the shape key for a graph node.
    private func nodeShapeKey(_ node: ChoiceGraphNode) -> NodeShapeKey {
        switch node.kind {
        case .chooseBits:
            return .value
        case let .sequence(metadata):
            if metadata.elementCount == 0 { return .emptySequence }
            return .sequence(elementCount: metadata.elementCount)
        case .zip:
            return .zip(childCount: node.children.count)
        case .bind:
            return .bind
        case let .pick(metadata):
            return .pick(branchCount: metadata.branchIDs.count)
        case .just:
            return .just
        }
    }
}
