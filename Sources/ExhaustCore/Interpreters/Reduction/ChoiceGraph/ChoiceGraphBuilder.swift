//
//  ChoiceGraphBuilder.swift
//  Exhaust
//

// MARK: - Builder

/// Constructs a ``ChoiceGraph`` from a ``ChoiceTree`` and its flattened ``ChoiceSequence``.
///
/// A single recursive walk of the tree produces nodes and containment/dependency edges. Post-walk passes compute self-similarity edges (grouping active picks by `fingerprint`), topological order (Kahn's algorithm), and reachability (reverse topological propagation). Type-compatibility edges are computed after antichain construction.
///
/// The walk mirrors the offset arithmetic of ``ChoiceSequence/flatten(_:includingAllBranches:)`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)`` to maintain position-to-node correspondence.
///
/// The active-branch walk and assembly pass live in this file. The inactive-branch walk (used to materialize non-selected branches with nil position ranges) lives in `ChoiceGraphBuilder+InactiveBranch.swift`. The subtree splice helpers used by ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` live in `ChoiceGraphBuilder+Subtree.swift`.
struct ChoiceGraphBuilder {
    var nodes: [ChoiceGraphNode] = []
    var containmentEdges: [ContainmentEdge] = []
    var dependencyEdges: [DependencyEdge] = []
    var nextNodeID = 0

    // MARK: - Entry Point

    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. The ``ChoiceSequence`` is a projection of the tree and is not required — sequence offsets are computed from the tree's own structure.
    ///
    /// - Parameter tree: The generator's compositional structure. Produced by the materializer with `materializePicks` controlling whether inactive branches have full subtrees.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        var builder = ChoiceGraphBuilder()
        _ = builder.walk(tree, offset: 0, parent: nil, bindDepth: 0, path: [])
        return builder.assembleGraph()
    }

    // MARK: - Recursive Walk

    /// Walks a ``ChoiceTree`` node, emitting graph nodes and edges.
    ///
    /// The `path` parameter is the accumulated ``BindPath`` from the tree root down to the current walk position. Non-getSize ``ChoiceTree/bind(_:_:)`` nodes are stamped with this path as their ``BindMetadata/bindPath`` so that ``ChoiceGraph/extractBoundSubtree(from:matchingPath:)`` can later locate the same bind in a post-mutation freshTree even when sequence offsets have shifted.
    ///
    /// - Returns: The number of ``ChoiceSequence`` entries consumed (mirrors flatten order).
    @discardableResult
    mutating func walk(
        _ tree: ChoiceTree,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath
    ) -> Int {
        switch tree {
        case let .choice(value, metadata):
            return walkChoice(value: value, metadata: metadata, offset: offset, parent: parent)

        case .just:
            let nodeID = emitNode(kind: .just, positionRange: offset ... offset, children: [], parent: parent)
            if let parent {
                containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
            }
            return 1

        case .getSize:
            // Invisible — fixed at 100 during reduction, 0 entries in sequence.
            return 0

        case let .sequence(_, elements, metadata):
            return walkSequence(elements: elements, metadata: metadata, offset: offset, parent: parent, bindDepth: bindDepth, path: path)

        case let .branch(_, _, _, _, choice):
            // Branch nodes are handled by pick-site detection in walkGroup.
            // If reached directly, walk the choice subtree.
            return walk(choice, offset: offset, parent: parent, bindDepth: bindDepth, path: path)

        case let .group(array, isOpaque):
            return walkGroup(children: array, isOpaque: isOpaque, offset: offset, parent: parent, bindDepth: bindDepth, path: path)

        case let .bind(fingerprint, inner, bound):
            return walkBind(
                fingerprint: fingerprint,
                inner: inner,
                bound: bound,
                offset: offset,
                parent: parent,
                bindDepth: bindDepth,
                path: path
            )

        case let .resize(_, choices):
            // Resize is operational — skip the node, walk children as a group.
            return walkGroupChildren(choices, offset: offset, parent: parent, bindDepth: bindDepth, path: path)

        case let .selected(inner):
            // Unwrap and walk the inner tree.
            return walk(inner, offset: offset, parent: parent, bindDepth: bindDepth, path: path)
        }
    }

    // MARK: - Per-Kind Walk Methods

    private mutating func walkChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        offset: Int,
        parent: Int?
    ) -> Int {
        let nodeID = emitNode(
            kind: .chooseBits(ChooseBitsMetadata(
                typeTag: value.tag,
                validRange: metadata.validRange,
                isRangeExplicit: metadata.isRangeExplicit,
                value: value
            )),
            positionRange: offset ... offset,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }
        return 1
    }

    private mutating func walkSequence(
        elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath
    ) -> Int {
        let nodeID = emitNode(
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.validRange,
                elementCount: elements.count,
                childPositionRanges: [], // Patched after children are walked.
                elementTypeTag: nil
            )),
            positionRange: nil,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
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
            // The walk may have emitted one or more nodes; the first is the direct child.
            if childStartID < nextNodeID, elementConsumed > 0 {
                childIDs.append(childStartID)
                childExtents.append(elementStart ... (elementStart + elementConsumed - 1))
            }
            elementIndex += 1
        }

        consumed += 1 // close marker

        // Patch the node with children, position range, child extents, and element type homogeneity.
        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.validRange,
                elementCount: elements.count,
                childPositionRanges: childExtents,
                elementTypeTag: deriveElementTypeTag(childIDs: childIDs)
            )),
            positionRange: offset ... (offset + consumed - 1),
            children: childIDs,
            parent: parent
        )
        return consumed
    }

    private mutating func walkGroup(
        children array: [ChoiceTree],
        isOpaque: Bool,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath
    ) -> Int {
        // Detect pick site: all children are .branch or .selected, with exactly one .selected(.branch(...)).
        if let pickResult = detectPickSite(array) {
            return walkPickSite(
                array: array,
                selectedBranch: pickResult,
                offset: offset,
                parent: parent,
                bindDepth: bindDepth,
                path: path
            )
        }

        // Regular zip group.
        let nodeID = emitNode(
            kind: .zip(ZipMetadata(isOpaque: isOpaque)),
            positionRange: nil,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = 1 // group open
        var childIDs: [Int] = []
        childIDs.reserveCapacity(array.count)

        var childIndex = 0
        while childIndex < array.count {
            let childStartID = nextNodeID
            let childConsumed = walk(
                array[childIndex],
                offset: offset + consumed,
                parent: nodeID,
                bindDepth: bindDepth,
                path: path + [.groupChild(childIndex)]
            )
            consumed += childConsumed
            if childStartID < nextNodeID {
                childIDs.append(childStartID)
            }
            childIndex += 1
        }

        consumed += 1 // group close

        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
            positionRange: offset ... (offset + consumed - 1),
            children: childIDs,
            parent: parent
        )
        return consumed
    }

    private mutating func walkPickSite(
        array: [ChoiceTree],
        selectedBranch: PickSiteInfo,
        offset: Int,
        parent: Int?,
        bindDepth: Int,
        path: BindPath
    ) -> Int {
        let nodeID = emitNode(
            kind: .pick(PickMetadata(
                fingerprint: selectedBranch.fingerprint,
                branchIDs: selectedBranch.branchIDs,
                selectedID: selectedBranch.selectedID,
                selectedChildIndex: 0, // Patched below
                branchElements: array // Stored verbatim — see ``PickMetadata/branchElements``.
            )),
            positionRange: nil,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        // Pick-site flattens as: group(true), branch marker, selected choice entries, group(false).
        // Only the selected branch has sequence positions.
        var consumed = 2 // group open + branch marker

        var childIDs: [Int] = []
        childIDs.reserveCapacity(array.count)
        var selectedChildIndex = 0

        var branchIndex = 0
        while branchIndex < array.count {
            let child = array[branchIndex]
            let isSelected = child.isSelected

            if isSelected {
                // Active branch — walk with position mapping.
                selectedChildIndex = childIDs.count
                let childStartID = nextNodeID
                let childConsumed = walk(
                    child,
                    offset: offset + consumed,
                    parent: nodeID,
                    bindDepth: bindDepth,
                    path: path + [.pickBranch(selectedBranch.selectedID)]
                )
                consumed += childConsumed
                if childStartID < nextNodeID {
                    childIDs.append(childStartID)
                    containmentEdges.append(ContainmentEdge(source: nodeID, target: childStartID))
                }
            } else {
                // Inactive branch — walk with nil positions for structural information.
                let childStartID = nextNodeID
                walkInactiveBranch(child, parent: nodeID, bindDepth: bindDepth)
                if childStartID < nextNodeID {
                    childIDs.append(childStartID)
                    containmentEdges.append(ContainmentEdge(source: nodeID, target: childStartID))
                }
            }
            branchIndex += 1
        }

        consumed += 1 // group close

        // Patch node with children, position range, and correct selectedChildIndex.
        if case let .pick(metadata) = nodes[nodeID].kind {
            nodes[nodeID] = ChoiceGraphNode(
                id: nodeID,
                kind: .pick(PickMetadata(
                    fingerprint: metadata.fingerprint,
                    branchIDs: metadata.branchIDs,
                    selectedID: metadata.selectedID,
                    selectedChildIndex: selectedChildIndex,
                    branchElements: metadata.branchElements
                )),
                positionRange: offset ... (offset + consumed - 1),
                children: childIDs,
                parent: parent
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
        path: BindPath
    ) -> Int {
        if inner.isGetSize {
            // getSize-bind is transparent — flattens as group markers. Walk children directly.
            // getSize contributes 0 entries; bound content appears as-is.
            var consumed = 1 // group open
            // getSize is skipped (0 entries).
            let boundConsumed = walk(bound, offset: offset + consumed, parent: parent, bindDepth: bindDepth, path: path)
            consumed += boundConsumed
            consumed += 1 // group close
            return consumed
        }

        let nodeID = emitNode(
            kind: .bind(BindMetadata(
                fingerprint: fingerprint,
                isStructurallyConstant: bound.containsBind == false && bound.containsPicks == false,
                bindDepth: bindDepth,
                innerChildIndex: 0,
                boundChildIndex: 1,
                bindPath: path
            )),
            positionRange: nil,
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = 1 // bind open

        let innerStartID = nextNodeID
        let innerConsumed = walk(inner, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth, path: path)
        consumed += innerConsumed

        let boundStartID = nextNodeID
        let boundConsumed = walk(bound, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth + 1, path: path + [.bindBound])
        consumed += boundConsumed

        consumed += 1 // bind close

        var childIDs: [Int] = []
        if innerStartID < nextNodeID {
            childIDs.append(innerStartID)
        }
        if boundStartID < nextNodeID {
            childIDs.append(boundStartID)
        }

        // Dependency edges are computed in the post-walk assembly pass from bind node metadata (innerChildIndex → bound subtree structural nodes).

        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
            positionRange: offset ... (offset + consumed - 1),
            children: childIDs,
            parent: parent
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

    mutating func emitNode(
        kind: ChoiceGraphNodeKind,
        positionRange: ClosedRange<Int>?,
        children: [Int],
        parent: Int?
    ) -> Int {
        let nodeID = nextNodeID
        nextNodeID += 1
        nodes.append(ChoiceGraphNode(
            id: nodeID,
            kind: kind,
            positionRange: positionRange,
            children: children,
            parent: parent
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
        let branchIDs: [UInt64]
    }

    /// Detects whether a group's children form a pick site.
    ///
    /// A pick site is a group where all children are `.branch` or `.selected`, with exactly one `.selected(.branch(...))`. Mirrors the detection logic in ``ChoiceTree/flattenedEntryCount`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)``.
    func detectPickSite(_ array: [ChoiceTree]) -> PickSiteInfo? {
        guard array.allSatisfy({ $0.isBranch || $0.isSelected }) else {
            return nil
        }
        guard let selected = array.first(where: \.isSelected) else {
            return nil
        }
        guard case let .selected(.branch(fingerprint, _, id, branchIDs, _)) = selected else {
            return nil
        }
        return PickSiteInfo(fingerprint: fingerprint, selectedID: id, branchIDs: branchIDs)
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

            // The fundamental dependency: inner → bound.
            allDependencyEdges.append(DependencyEdge(source: innerChildID, target: boundChildID))

            // Additional edges to structural nodes deeper in the bound subtree.
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
        // O(P) construction instead of the previous O(P²) all-pairs edge array.
        var selfSimilarityGroups: [UInt64: [Int]] = [:]
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            selfSimilarityGroups[metadata.fingerprint, default: []].append(node.id)
        }

        // Topological order and dependency adjacency are computed lazily on first access. The builder no longer eagerly computes them — keeping the computation close to the cache slot lets Layer 4's partial-rebuild path invalidate and recompute through the same code path.
        return ChoiceGraph(
            nodes: nodes,
            containmentEdges: containmentEdges,
            dependencyEdges: allDependencyEdges,
            selfSimilarityGroups: selfSimilarityGroups
        )
    }

    /// Computes the sequence length covered by a node's subtree.
    private func subtreeSequenceLength(_ node: ChoiceGraphNode) -> Int {
        guard let range = node.positionRange else { return 0 }
        return range.count
    }
}
