extension ChoiceGraph {
    /// Finds an active bind by both site and path, preserving live-node traversal order when several expansions share a fingerprint.
    func bindNodeID(fingerprint: UInt64, path: ChoicePath) -> Int? {
        liveNodeIDs.first { nodeID in
            guard case let .bind(metadata) = nodes[nodeID].kind else {
                return false
            }
            return metadata.fingerprint == fingerprint && metadata.bindPath == path
        }
    }

    /// Returns the sole nested bind when composition can descend without revisiting a bind site. Repeated fingerprints identify recursive expansions, which remain separate scheduler work rather than additional composition dimensions.
    func composableNestedBind(
        under bindNodeID: Int,
        seenBindFingerprints: Set<UInt64>
    ) -> (nodeID: Int, metadata: BindMetadata)? {
        let nestedBindNodeIDs = directNestedBindNodeIDs(under: bindNodeID)
        guard nestedBindNodeIDs.count == 1 else {
            return nil
        }
        let nestedBindNodeID = nestedBindNodeIDs[0]
        guard nestedBindNodeID < nodes.count,
              case let .bind(metadata) = nodes[nestedBindNodeID].kind,
              seenBindFingerprints.contains(metadata.fingerprint) == false
        else {
            return nil
        }
        return (nestedBindNodeID, metadata)
    }

    /// Finds outermost active binds with a numeric controller below this bind's bound child. More than one marks a branching dependency, so composition does not descend through it.
    private func directNestedBindNodeIDs(under bindNodeID: Int) -> [Int] {
        guard bindNodeID < nodes.count,
              case let .bind(metadata) = nodes[bindNodeID].kind,
              nodes[bindNodeID].children.count > metadata.boundChildIndex
        else {
            return []
        }

        let boundChildID = nodes[bindNodeID].children[metadata.boundChildIndex]
        var nestedBindNodeIDs: [Int] = []
        var stack = [boundChildID]
        while let nodeID = stack.popLast() {
            let node = nodes[nodeID]
            guard node.positionRange != nil else {
                continue
            }
            if case let .bind(nestedMetadata) = node.kind,
               node.children.count > max(
                   nestedMetadata.innerChildIndex,
                   nestedMetadata.boundChildIndex
               )
            {
                let innerChildID = node.children[nestedMetadata.innerChildIndex]
                let nestedBoundChildID = node.children[nestedMetadata.boundChildIndex]
                if case .chooseBits = nodes[innerChildID].kind,
                   nodes[nestedBoundChildID].positionRange != nil
                {
                    nestedBindNodeIDs.append(nodeID)
                    continue
                }
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return nestedBindNodeIDs
    }
}
