//
//  ChoiceGraphBuilder+InactiveBranch.swift
//  Exhaust
//

// MARK: - Inactive Branch Walking

extension ChoiceGraphBuilder {
    /// Walks an inactive (unselected) branch subtree with nil position ranges on all nodes.
    mutating func walkInactiveBranch(
        _ tree: ChoiceTree,
        parent: Int?,
        bindDepth: Int
    ) {
        switch tree {
        case let .choice(value, metadata):
            let nodeID = emitNode(
                kind: .chooseBits(ChooseBitsMetadata(
                    typeTag: value.tag,
                    validRange: metadata.validRange,
                    isRangeExplicit: metadata.isRangeExplicit,
                    value: value
                )),
                positionRange: nil,
                children: [],
                parent: parent
            )
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }

        case .just:
            let nodeID = emitNode(kind: .just, positionRange: nil, children: [], parent: parent)
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }

        case .getSize:
            break

        case let .sequence(_, elements, metadata):
            let nodeID = emitNode(
                kind: .sequence(SequenceMetadata(
                    lengthConstraint: metadata.validRange,
                    elementCount: elements.count,
                    childPositionRanges: [],
                    elementTypeTag: nil
                )),
                positionRange: nil,
                children: [],
                parent: parent
            )
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }
            var childIDs: [Int] = []
            for element in elements {
                let childStartID = nextNodeID
                walkInactiveBranch(element, parent: nodeID, bindDepth: bindDepth)
                if childStartID < nextNodeID {
                    childIDs.append(childStartID)
                }
            }
            nodes[nodeID] = ChoiceGraphNode(
                id: nodeID,
                kind: nodes[nodeID].kind,
                positionRange: nil,
                children: childIDs,
                parent: parent
            )

        case let .branch(_, _, _, _, choice):
            walkInactiveBranch(choice, parent: parent, bindDepth: bindDepth)

        case let .group(array, isOpaque):
            if detectPickSite(array) != nil {
                // Inactive pick site — record metadata but all children are inactive.
                walkInactivePickSite(array, parent: parent, bindDepth: bindDepth)
            } else {
                let nodeID = emitNode(
                    kind: .zip(ZipMetadata(isOpaque: isOpaque)),
                    positionRange: nil,
                    children: [],
                    parent: parent
                )
                if let parent {
                    containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
                }
                var childIDs: [Int] = []
                for child in array {
                    let childStartID = nextNodeID
                    walkInactiveBranch(child, parent: nodeID, bindDepth: bindDepth)
                    if childStartID < nextNodeID {
                        childIDs.append(childStartID)
                    }
                }
                nodes[nodeID] = ChoiceGraphNode(
                    id: nodeID,
                    kind: nodes[nodeID].kind,
                    positionRange: nil,
                    children: childIDs,
                    parent: parent
                )
            }

        case let .bind(inner, bound):
            if inner.isGetSize {
                // getSize-bind is transparent — walk bound directly.
                walkInactiveBranch(bound, parent: parent, bindDepth: bindDepth)
            } else {
                let nodeID = emitNode(
                    kind: .bind(BindMetadata(
                        isStructurallyConstant: bound.containsBind == false && bound.containsPicks == false,
                        bindDepth: bindDepth,
                        innerChildIndex: 0,
                        boundChildIndex: 1,
                        bindPath: []
                    )),
                    positionRange: nil,
                    children: [],
                    parent: parent
                )
                if let parent {
                    containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
                }
                let innerStartID = nextNodeID
                walkInactiveBranch(inner, parent: nodeID, bindDepth: bindDepth)
                let boundStartID = nextNodeID
                walkInactiveBranch(bound, parent: nodeID, bindDepth: bindDepth + 1)

                var childIDs: [Int] = []
                if innerStartID < nextNodeID {
                    childIDs.append(innerStartID)
                }
                if boundStartID < nextNodeID {
                    childIDs.append(boundStartID)
                }
                nodes[nodeID] = ChoiceGraphNode(
                    id: nodeID,
                    kind: nodes[nodeID].kind,
                    positionRange: nil,
                    children: childIDs,
                    parent: parent
                )
            }

        case let .resize(_, choices):
            for choice in choices {
                walkInactiveBranch(choice, parent: parent, bindDepth: bindDepth)
            }

        case let .selected(inner):
            walkInactiveBranch(inner, parent: parent, bindDepth: bindDepth)
        }
    }

    private mutating func walkInactivePickSite(
        _ array: [ChoiceTree],
        parent: Int?,
        bindDepth: Int
    ) {
        guard let info = detectPickSite(array) else { return }

        let nodeID = emitNode(
            kind: .pick(PickMetadata(
                fingerprint: info.fingerprint,
                branchIDs: info.branchIDs,
                selectedID: info.selectedID,
                selectedChildIndex: 0,
                branchElements: array
            )),
            positionRange: nil,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var childIDs: [Int] = []
        for child in array {
            let childStartID = nextNodeID
            walkInactiveBranch(child, parent: nodeID, bindDepth: bindDepth)
            if childStartID < nextNodeID {
                childIDs.append(childStartID)
                containmentEdges.append(ContainmentEdge(source: nodeID, target: childStartID))
            }
        }
        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
            positionRange: nil,
            children: childIDs,
            parent: parent
        )
    }
}
