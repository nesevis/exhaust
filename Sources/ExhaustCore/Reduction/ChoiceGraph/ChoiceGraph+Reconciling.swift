//
//  ChoiceGraph+Reconciling.swift
//  Exhaust
//

// MARK: - Reconciling

extension ChoiceGraph {
    /// Finds the node in `lifted` that corresponds to `nodeID` in this graph, or nil when it cannot be reconciled safely.
    ///
    /// `lifted` is built from this graph's tree after a lift that edited `changedNodeID`, so the two graphs agree on every node built before that one. Each tier checks the kind it resolves to:
    /// - A node built before the change, the change's ancestors included, keeps its ID. Node IDs are assigned in preorder, so this holds only when both graphs number that prefix the same way: built in the same mode, and either both or neither missing unselected branches.
    /// - A bind built after the change is found by fingerprint and path.
    /// - A leaf built after the change is found through its nearest enclosing bind: as that bind's inner child, or at the same offset in a bound range of unchanged length.
    ///
    /// The result is a corresponding position, not a verified logical identity: a regenerated bound subtree can hold a different logical leaf at the same offset. Callers keep their operation-specific checks.
    func reconciling(_ nodeID: Int, in lifted: ChoiceGraph, changedAt changedNodeID: Int) -> Int? {
        guard nodes.indices.contains(nodeID) else {
            return nil
        }
        if nodeID < changedNodeID {
            guard isControllerTopology == lifted.isControllerTopology,
                  lacksUnselectedBranches == lifted.lacksUnselectedBranches,
                  lifted.nodes.indices.contains(nodeID),
                  Self.hasSameKind(nodes[nodeID].kind, lifted.nodes[nodeID].kind)
            else {
                return nil
            }
            return nodeID
        }
        switch nodes[nodeID].kind {
            case let .bind(metadata):
                return lifted.bindNodeID(fingerprint: metadata.fingerprint, path: metadata.bindPath)
            case .chooseBits:
                return reconcilingLeaf(nodeID, in: lifted)
            case .pick, .zip, .sequence, .just:
                return nil
        }
    }

    // MARK: - Helpers

    /// Resolves a leaf through its nearest enclosing bind, which must hold it as its inner child or inside its bound subtree.
    private func reconcilingLeaf(_ leafID: Int, in lifted: ChoiceGraph) -> Int? {
        var childID = leafID
        var ancestorID = nodes[leafID].parent
        while let bindCandidateID = ancestorID {
            guard case let .bind(metadata) = nodes[bindCandidateID].kind else {
                childID = bindCandidateID
                ancestorID = nodes[bindCandidateID].parent
                continue
            }
            guard let liftedBindID = lifted.bindNodeID(fingerprint: metadata.fingerprint, path: metadata.bindPath),
                  case let .bind(liftedMetadata) = lifted.nodes[liftedBindID].kind
            else {
                return nil
            }
            let children = nodes[bindCandidateID].children
            let liftedChildren = lifted.nodes[liftedBindID].children
            if children.count > metadata.innerChildIndex, children[metadata.innerChildIndex] == leafID {
                guard liftedChildren.count > liftedMetadata.innerChildIndex else {
                    return nil
                }
                let innerID = liftedChildren[liftedMetadata.innerChildIndex]
                guard case .chooseBits = lifted.nodes[innerID].kind, lifted.nodes[innerID].positionRange != nil else {
                    return nil
                }
                return innerID
            }
            guard children.count > metadata.boundChildIndex,
                  children[metadata.boundChildIndex] == childID,
                  liftedChildren.count > liftedMetadata.boundChildIndex,
                  let bound = nodes[childID].positionRange,
                  let liftedBound = lifted.nodes[liftedChildren[liftedMetadata.boundChildIndex]].positionRange,
                  bound.count == liftedBound.count,
                  let leafIndex = nodes[leafID].positionRange?.lowerBound,
                  bound.contains(leafIndex)
            else {
                return nil
            }
            return lifted.leaf(
                at: liftedBound.lowerBound + (leafIndex - bound.lowerBound),
                within: liftedChildren[liftedMetadata.boundChildIndex]
            )
        }
        return nil
    }

    /// The active leaf at `sequenceIndex` in the subtree rooted at `rootID`.
    private func leaf(at sequenceIndex: Int, within rootID: Int) -> Int? {
        var stack = [rootID]
        while let nodeID = stack.popLast() {
            guard let range = nodes[nodeID].positionRange, range.contains(sequenceIndex) else {
                continue
            }
            if case .chooseBits = nodes[nodeID].kind {
                return nodeID
            }
            stack.append(contentsOf: nodes[nodeID].children)
        }
        return nil
    }

    private static func hasSameKind(_ first: ChoiceGraphNodeKind, _ second: ChoiceGraphNodeKind) -> Bool {
        switch (first, second) {
            case (.chooseBits, .chooseBits), (.pick, .pick), (.bind, .bind), (.zip, .zip), (.sequence, .sequence), (.just, .just):
                true
            default:
                false
        }
    }
}
