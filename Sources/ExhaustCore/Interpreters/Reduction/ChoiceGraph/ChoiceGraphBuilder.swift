//
//  ChoiceGraphBuilder.swift
//  Exhaust
//

// MARK: - Builder

/// Constructs a ``ChoiceGraph`` from a ``ChoiceTree`` and its flattened ``ChoiceSequence``.
///
/// A single recursive walk of the tree produces nodes and containment/dependency edges. ``assembleGraph()`` then computes self-similarity groups, live node IDs, leaf nodes, dependency adjacency, and topological order — all stored eagerly on the resulting struct.
///
/// The walk mirrors the offset arithmetic of ``ChoiceSequence/flatten(_:includingAllBranches:)`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)`` to maintain position-to-node correspondence.
///
/// Active branches carry position ranges and offset arithmetic. Inactive branches (unselected pick alternatives) are walked with `isActive: false`, which emits nodes with nil position ranges and skips offset tracking.
struct ChoiceGraphBuilder {
    var nodes: [ChoiceGraphNode] = []
    var containmentEdges: [ContainmentEdge] = []
    var dependencyEdges: [DependencyEdge] = []
    var nextNodeID = 0

    /// Tracks the outermost enclosing bind's node ID for nodes inside a bind's inner subtree. Set when entering a bind's inner child; cleared when entering the bound child. Outermost-wins: once set, nested binds do not override.
    var enclosingBindNodeID: Int?

    /// The ``BindMetadata/bindDepth`` of the outermost enclosing bind, when inside a bind's inner subtree.
    var enclosingBindDepth: Int?

    // MARK: - Entry Point

    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. The ``ChoiceSequence`` is a projection of the tree and is not required — sequence offsets are computed from the tree's own structure.
    ///
    /// - Parameter tree: The generator's compositional structure. Produced by the materializer with `materializePicks` controlling whether inactive branches have full subtrees.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        if case .just = tree {
            return ChoiceGraph(
                nodes: [],
                containmentEdges: [],
                dependencyEdges: [],
                selfSimilarityGroups: [:],
                liveNodeIDs: [],
                leafNodes: [],
                topologicalOrder: [],
                dependencyAdjacency: []
            )
        }
        var builder = ChoiceGraphBuilder()
        _ = builder.walk(tree, offset: 0, parent: nil, bindDepth: 0, path: [])
        return builder.assembleGraph()
    }

    // MARK: - Recursive Walk

    /// Walks a ``ChoiceTree`` node, emitting graph nodes and edges.
    ///
    /// When `isActive` is false, all emitted nodes get nil position ranges and offset arithmetic is skipped. Used for unselected pick branches that need structural representation without sequence positions.
    ///
    /// - Returns: The number of ``ChoiceSequence`` entries consumed (0 for inactive walks).
    @discardableResult
    mutating func walk(
        _ tree: ChoiceTree,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath,
        isActive: Bool = true
    ) -> Int {
        switch tree {
        case let .choice(value, metadata):
            let isDepthControl: Bool
            if case .depthControl = value.tag { isDepthControl = true } else { isDepthControl = false }
            let nodeID = emitNode(
                kind: .chooseBits(ChooseBitsMetadata(
                    typeTag: value.tag,
                    validRange: metadata.validRange,
                    isRangeExplicit: metadata.isRangeExplicit,
                    value: value
                )),
                positionRange: isActive ? (offset ... offset) : nil,
                children: [],
                parent: parent,
                choicePath: path,
                scopeAnnotation: ScopeAnnotation(
                    isBindInner: enclosingBindNodeID != nil,
                    controllingBindNodeID: enclosingBindNodeID,
                    controllingBindDepth: enclosingBindDepth,
                    isDepthControl: isDepthControl
                )
            )
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }
            return isActive ? 1 : 0

        case .just:
            let nodeID = emitNode(
                kind: .just,
                positionRange: isActive ? (offset ... offset) : nil,
                children: [],
                parent: parent,
                choicePath: path,
                scopeAnnotation: ScopeAnnotation(
                    isBindInner: enclosingBindNodeID != nil,
                    controllingBindNodeID: enclosingBindNodeID,
                    controllingBindDepth: enclosingBindDepth,
                    isDepthControl: false
                )
            )
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }
            return isActive ? 1 : 0

        case .getSize:
            return 0

        case let .sequence(_, elements, metadata):
            return walkSequence(
                elements: elements, metadata: metadata, offset: offset,
                parent: parent, bindDepth: bindDepth, path: path, isActive: isActive
            )

        case let .branch(b):
            return walk(b.choice, offset: offset, parent: parent, bindDepth: bindDepth, path: path, isActive: isActive)

        case let .group(array, isOpaque):
            return walkGroup(
                children: array, isOpaque: isOpaque, offset: offset,
                parent: parent, bindDepth: bindDepth, path: path, isActive: isActive
            )

        case let .bind(fingerprint, inner, bound):
            return walkBind(
                fingerprint: fingerprint, inner: inner, bound: bound, offset: offset,
                parent: parent, bindDepth: bindDepth, path: path, isActive: isActive
            )

        case let .resize(_, choices):
            if isActive {
                return walkGroupChildren(choices, offset: offset, parent: parent, bindDepth: bindDepth, path: path)
            }
            for choice in choices {
                walk(choice, offset: 0, parent: parent, bindDepth: bindDepth, path: [], isActive: false)
            }
            return 0

        }
    }

    // MARK: - Per-Kind Walk Methods

    private mutating func walkSequence(
        elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath,
        isActive: Bool
    ) -> Int {
        let nodeID = emitNode(
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.validRange,
                elementCount: elements.count,
                childPositionRanges: [],
                childIndexByNodeID: [:],
                elementTypeTag: nil
            )),
            positionRange: nil,
            children: [],
            parent: parent,
            choicePath: path
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        if isActive == false {
            var childIDs: [Int] = []
            for element in elements {
                let childStartID = nextNodeID
                walk(element, offset: 0, parent: nodeID, bindDepth: bindDepth, path: [], isActive: false)
                if childStartID < nextNodeID {
                    childIDs.append(childStartID)
                }
            }
            nodes[nodeID] = ChoiceGraphNode(
                id: nodeID,
                kind: nodes[nodeID].kind,
                positionRange: nil,
                children: childIDs,
                parent: parent,
                choicePath: path,
                scopeAnnotation: nodes[nodeID].scopeAnnotation
            )
            return 0
        }

        var consumed = 1 // open marker
        var childIDs: [Int] = []
        childIDs.reserveCapacity(elements.count)
        var childExtents: [ClosedRange<Int>] = []
        childExtents.reserveCapacity(elements.count)

        var elementIndex = 0
        while elementIndex < elements.count {
            let childStartID = nextNodeID
            let elementStart = offset + consumed
            let elementConsumed = walk(
                elements[elementIndex],
                offset: elementStart,
                parent: nodeID,
                bindDepth: bindDepth,
                path: path + [.sequenceChild(elementIndex)]
            )
            consumed += elementConsumed
            if childStartID < nextNodeID, elementConsumed > 0 {
                childIDs.append(childStartID)
                childExtents.append(elementStart ... (elementStart + elementConsumed - 1))
            }
            elementIndex += 1
        }

        consumed += 1 // close marker

        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.validRange,
                elementCount: elements.count,
                childPositionRanges: childExtents,
                childIndexByNodeID: childIDs.enumerated().reduce(into: [:]) { dict, pair in
                    precondition(dict[pair.element] == nil, "duplicate child node ID \(pair.element) at index \(pair.offset)")
                    dict[pair.element] = pair.offset
                },
                elementTypeTag: deriveElementTypeTag(childIDs: childIDs)
            )),
            positionRange: offset ... (offset + consumed - 1),
            children: childIDs,
            parent: parent,
            choicePath: path,
            scopeAnnotation: ScopeAnnotation(
                isBindInner: enclosingBindNodeID != nil,
                controllingBindNodeID: enclosingBindNodeID,
                controllingBindDepth: enclosingBindDepth,
                isDepthControl: false
            )
        )
        return consumed
    }

    private mutating func walkGroup(
        children array: [ChoiceTree],
        isOpaque: Bool,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath,
        isActive: Bool
    ) -> Int {
        if let pickResult = detectPickSite(array) {
            return walkPickSite(
                array: array,
                selectedBranch: pickResult,
                offset: offset,
                parent: parent,
                bindDepth: bindDepth,
                path: path,
                isActive: isActive
            )
        }

        let nodeID = emitNode(
            kind: .zip(ZipMetadata(isOpaque: isOpaque)),
            positionRange: nil,
            children: [],
            parent: parent,
            choicePath: path
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = isActive ? 1 : 0
        var childIDs: [Int] = []
        childIDs.reserveCapacity(array.count)

        var childIndex = 0
        while childIndex < array.count {
            let childStartID = nextNodeID
            if isActive {
                let childConsumed = walk(
                    array[childIndex],
                    offset: offset + consumed,
                    parent: nodeID,
                    bindDepth: bindDepth,
                    path: path + [.groupChild(childIndex)]
                )
                consumed += childConsumed
            } else {
                walk(array[childIndex], offset: 0, parent: nodeID, bindDepth: bindDepth, path: [], isActive: false)
            }
            if childStartID < nextNodeID {
                childIDs.append(childStartID)
            }
            childIndex += 1
        }

        if isActive { consumed += 1 }

        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
            positionRange: isActive ? (offset ... (offset + consumed - 1)) : nil,
            children: childIDs,
            parent: parent,
            choicePath: path,
            scopeAnnotation: nodes[nodeID].scopeAnnotation
        )
        return consumed
    }

    private mutating func walkPickSite(
        array: [ChoiceTree],
        selectedBranch: PickSiteInfo,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath,
        isActive: Bool
    ) -> Int {
        let nodeID = emitNode(
            kind: .pick(PickMetadata(
                fingerprint: selectedBranch.fingerprint,
                branchCount: selectedBranch.branchCount,
                selectedID: selectedBranch.selectedID,
                selectedChildIndex: 0,
                branchElements: array
            )),
            positionRange: nil,
            children: [],
            parent: parent,
            choicePath: path
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = isActive ? 2 : 0 // group open + branch marker (active only)
        var childIDs: [Int] = []
        childIDs.reserveCapacity(array.count)
        var selectedChildIndex = 0

        var branchIndex = 0
        while branchIndex < array.count {
            let child = array[branchIndex]
            let childStartID = nextNodeID

            if isActive, child.isSelected {
                selectedChildIndex = childIDs.count
                let childConsumed = walk(
                    child,
                    offset: offset + consumed,
                    parent: nodeID,
                    bindDepth: bindDepth,
                    path: path + [.pickBranch(selectedBranch.selectedID)]
                )
                consumed += childConsumed
            } else {
                walk(child, offset: 0, parent: nodeID, bindDepth: bindDepth, path: [], isActive: false)
            }

            if childStartID < nextNodeID {
                childIDs.append(childStartID)
                containmentEdges.append(ContainmentEdge(source: nodeID, target: childStartID))
            }
            branchIndex += 1
        }

        if isActive { consumed += 1 } // group close

        if case let .pick(metadata) = nodes[nodeID].kind {
            nodes[nodeID] = ChoiceGraphNode(
                id: nodeID,
                kind: .pick(PickMetadata(
                    fingerprint: metadata.fingerprint,
                    branchCount: metadata.branchCount,
                    selectedID: metadata.selectedID,
                    selectedChildIndex: selectedChildIndex,
                    branchElements: metadata.branchElements
                )),
                positionRange: isActive ? (offset ... (offset + consumed - 1)) : nil,
                children: childIDs,
                parent: parent,
                choicePath: path,
                scopeAnnotation: nodes[nodeID].scopeAnnotation
            )
        }
        return consumed
    }

    private mutating func walkBind(
        fingerprint: UInt64,
        inner: ChoiceTree,
        bound: ChoiceTree,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath,
        isActive: Bool
    ) -> Int {
        if inner.isGetSize {
            if isActive {
                var consumed = 1
                let boundConsumed = walk(bound, offset: offset + consumed, parent: parent, bindDepth: bindDepth, path: path)
                consumed += boundConsumed
                consumed += 1
                return consumed
            }
            walk(bound, offset: 0, parent: parent, bindDepth: bindDepth, path: [], isActive: false)
            return 0
        }

        let nodeID = emitNode(
            kind: .bind(BindMetadata(
                fingerprint: fingerprint,
                isStructurallyConstant: bound.containsBind == false && bound.containsPicks == false,
                bindDepth: bindDepth,
                innerChildIndex: 0,
                boundChildIndex: 1,
                bindPath: isActive ? path : []
            )),
            positionRange: nil,
            children: [],
            parent: parent,
            choicePath: path
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = isActive ? 1 : 0

        // Walk the inner subtree with bind-inner context. Outermost-wins: only set if not already inside another bind's inner subtree.
        let savedBindNodeID = enclosingBindNodeID
        let savedBindDepth = enclosingBindDepth
        if enclosingBindNodeID == nil {
            enclosingBindNodeID = nodeID
            enclosingBindDepth = bindDepth
        }

        let innerStartID = nextNodeID
        if isActive {
            let innerConsumed = walk(inner, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth, path: path + [.bindInner])
            consumed += innerConsumed
        } else {
            walk(inner, offset: 0, parent: nodeID, bindDepth: bindDepth, path: [], isActive: false)
        }

        // Restore bind-inner context before walking the bound subtree — bound children are NOT bind-inner.
        enclosingBindNodeID = savedBindNodeID
        enclosingBindDepth = savedBindDepth

        let boundStartID = nextNodeID
        if isActive {
            let boundConsumed = walk(bound, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth + 1, path: path + [.bindBound])
            consumed += boundConsumed
            consumed += 1 // bind close
        } else {
            walk(bound, offset: 0, parent: nodeID, bindDepth: bindDepth + 1, path: [], isActive: false)
        }

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
            positionRange: isActive ? (offset ... (offset + consumed - 1)) : nil,
            children: childIDs,
            parent: parent,
            choicePath: path,
            scopeAnnotation: nodes[nodeID].scopeAnnotation
        )
        return consumed
    }

    // MARK: - Walk Helpers

    /// Walks an array of children as a group (for .resize), without emitting a zip node.
    private mutating func walkGroupChildren(
        _ children: [ChoiceTree],
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath
    ) -> Int {
        var consumed = 1 // group open
        for (index, child) in children.enumerated() {
            consumed += walk(child, offset: offset + consumed, parent: parent, bindDepth: bindDepth, path: path + [.groupChild(index)])
        }
        consumed += 1 // group close
        return consumed
    }

    /// Allocates a node ID, appends the node to the builder's array, and records containment and dependency edges.
    mutating func emitNode(
        kind: ChoiceGraphNodeKind,
        positionRange: ClosedRange<Int>?,
        children: [Int],
        parent: Int?,
        choicePath: ChoicePath,
        scopeAnnotation: ScopeAnnotation = .default
    ) -> Int {
        let nodeID = nextNodeID
        nextNodeID += 1
        nodes.append(ChoiceGraphNode(
            id: nodeID,
            kind: kind,
            positionRange: positionRange,
            children: children,
            parent: parent,
            choicePath: choicePath,
            scopeAnnotation: scopeAnnotation
        ))
        return nodeID
    }

    // MARK: - Element Type Homogeneity

    /// Derives the common ``TypeTag`` for a sequence's children when all elements share the same type.
    ///
    /// Checks at most two children — sequence elements come from the same generator, so if the first two agree, all do. Two structural patterns qualify:
    /// - Direct: both children are ``ChoiceGraphNodeKind/chooseBits(_:)`` with matching tags.
    /// - Nested: both children are ``ChoiceGraphNodeKind/sequence(_:)`` with matching non-nil ``SequenceMetadata/elementTypeTag``.
    ///
    /// Returns nil for empty sequences, single-element sequences where the child is neither chooseBits nor a homogeneous sequence, or when the first two children disagree.
    func deriveElementTypeTag(childIDs: [Int]) -> TypeTag? {
        guard let firstID = childIDs.first else { return nil }
        let firstTag = leafTypeTag(of: firstID)
        guard let tag = firstTag else { return nil }
        if childIDs.count >= 2 {
            let secondTag = leafTypeTag(of: childIDs[1])
            guard secondTag == tag else { return nil }
        }
        return tag
    }

    /// Extracts the element-level ``TypeTag`` from a single child node.
    ///
    /// For chooseBits nodes, returns the tag directly. For sequence nodes with a non-nil ``SequenceMetadata/elementTypeTag``, returns that tag (implying nested homogeneity). Returns nil for all other node kinds.
    private func leafTypeTag(of nodeID: Int) -> TypeTag? {
        let node = nodes[nodeID]
        switch node.kind {
        case let .chooseBits(metadata):
            return metadata.typeTag
        case let .sequence(metadata):
            return metadata.elementTypeTag
        default:
            return nil
        }
    }

    // MARK: - Pick-Site Detection

    /// Information extracted from a pick-site group.
    struct PickSiteInfo {
        let fingerprint: UInt64
        let selectedID: UInt64
        let branchCount: UInt64
    }

    /// Detects whether a group's children form a pick site.
    ///
    /// A pick site is a group where all children are `.branch`, with exactly one having `isSelected: true`. Mirrors the detection logic in ``ChoiceTree/flattenedEntryCount`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)``.
    func detectPickSite(_ array: [ChoiceTree]) -> PickSiteInfo? {
        guard array.allSatisfy({ $0.isBranch }) else {
            return nil
        }
        guard case let .branch(b) = array.first(where: \.isSelected), b.isSelected else {
            return nil
        }
        return PickSiteInfo(fingerprint: b.fingerprint, selectedID: b.id, branchCount: b.branchCount)
    }

    // MARK: - Assembly

    /// Assembles the final ``ChoiceGraph`` from collected nodes and edges.
    private func assembleGraph() -> ChoiceGraph {
        // Post-walk: compute dependency edges from bind node metadata.
        // Every bind has a fundamental dependency: inner child → bound child.
        // Additionally, the inner child depends on any structural (bind/pick) nodes nested within the bound subtree.
        var allDependencyEdges = dependencyEdges
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]

            allDependencyEdges.append(DependencyEdge(source: innerChildID, target: boundChildID))

            var stack = [boundChildID]
            while stack.isEmpty == false {
                let current = stack.removeLast()
                guard current < nodes.count else { continue }
                let target = nodes[current]
                switch target.kind {
                case .bind, .pick:
                    if current != boundChildID {
                        allDependencyEdges.append(DependencyEdge(source: innerChildID, target: current))
                    }
                case .chooseBits, .zip, .sequence, .just:
                    break
                }
                for child in target.children {
                    stack.append(child)
                }
            }
        }

        // Self-similarity groups: active pick nodes indexed by fingerprint.
        var selfSimilarityGroups: [UInt64: [Int]] = [:]
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            selfSimilarityGroups[metadata.fingerprint, default: []].append(node.id)
        }

        // Eagerly compute derived fields that are accessed multiple times per cycle.
        let liveNodeIDs = nodes.indices.filter { nodes[$0].positionRange != nil }

        let leafNodes = liveNodeIDs.filter { nodeID in
            guard case .chooseBits = nodes[nodeID].kind else { return false }
            return true
        }

        // Dependency adjacency list for reachability queries.
        var dependencyAdjacency = [[Int]](repeating: [], count: nodes.count)
        for edge in allDependencyEdges {
            dependencyAdjacency[edge.source].append(edge.target)
        }

        // Topological order via Kahn's algorithm over dependency edges.
        let topologicalOrder: [Int] = {
            let nodeCount = nodes.count
            var inDegree = [Int](repeating: 0, count: nodeCount)
            for edge in allDependencyEdges {
                inDegree[edge.target] += 1
            }

            var participatingNodes = Set<Int>()
            for edge in allDependencyEdges {
                participatingNodes.insert(edge.source)
                participatingNodes.insert(edge.target)
            }

            var queue: [Int] = []
            for nodeID in participatingNodes where inDegree[nodeID] == 0 {
                queue.append(nodeID)
            }

            var order: [Int] = []
            order.reserveCapacity(participatingNodes.count)
            var front = 0

            while front < queue.count {
                let current = queue[front]
                front += 1
                order.append(current)
                for dependent in dependencyAdjacency[current] {
                    inDegree[dependent] -= 1
                    if inDegree[dependent] == 0 {
                        queue.append(dependent)
                    }
                }
            }
            return order
        }()

        return ChoiceGraph(
            nodes: nodes,
            containmentEdges: containmentEdges,
            dependencyEdges: allDependencyEdges,
            selfSimilarityGroups: selfSimilarityGroups,
            liveNodeIDs: liveNodeIDs,
            leafNodes: leafNodes,
            topologicalOrder: topologicalOrder,
            dependencyAdjacency: dependencyAdjacency
        )
    }
}
