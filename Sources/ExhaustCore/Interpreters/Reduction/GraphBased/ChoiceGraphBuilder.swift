//
//  ChoiceGraphBuilder.swift
//  Exhaust
//

// MARK: - Builder

/// Constructs a ``ChoiceGraph`` from a ``ChoiceTree`` and its flattened ``ChoiceSequence``.
///
/// A single recursive walk of the tree produces nodes and containment/dependency edges. Post-walk passes compute self-similarity edges (grouping active picks by `depthMaskedSiteID`), topological order (Kahn's algorithm), and reachability (reverse topological propagation). Type-compatibility edges are computed after antichain construction.
///
/// The walk mirrors the offset arithmetic of ``ChoiceSequence/flatten(_:includingAllBranches:)`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)`` to maintain position-to-node correspondence.
struct ChoiceGraphBuilder {
    private var nodes: [ChoiceGraphNode] = []
    private var containmentEdges: [ContainmentEdge] = []
    private var dependencyEdges: [DependencyEdge] = []
    private var nextNodeID = 0

    // MARK: - Entry Point

    /// Builds a ``ChoiceGraph`` from a choice tree.
    ///
    /// The tree contains all structural and value information needed for graph construction. The ``ChoiceSequence`` is a projection of the tree and is not required — sequence offsets are computed from the tree's own structure.
    ///
    /// - Parameter tree: The generator's compositional structure. Produced by the materialiser with `materializePicks` controlling whether inactive branches have full subtrees.
    static func build(from tree: ChoiceTree) -> ChoiceGraph {
        var builder = ChoiceGraphBuilder()
        _ = builder.walk(tree, offset: 0, parent: nil, bindDepth: 0)
        return builder.assembleGraph()
    }

    // MARK: - Recursive Walk

    /// Walks a ``ChoiceTree`` node, emitting graph nodes and edges.
    ///
    /// - Returns: The number of ``ChoiceSequence`` entries consumed (mirrors flatten order).
    @discardableResult
    private mutating func walk(
        _ tree: ChoiceTree,
        offset: Int,
        parent: Int?,
        bindDepth: Int
    ) -> Int {
        switch tree {
        case let .choice(value, metadata):
            return walkChoice(value: value, metadata: metadata, offset: offset, parent: parent)

        case .just:
            // Invisible — no choices, no graph node.
            return 1

        case .getSize:
            // Invisible — fixed at 100 during reduction, 0 entries in sequence.
            return 0

        case let .sequence(_, elements, metadata):
            return walkSequence(elements: elements, metadata: metadata, offset: offset, parent: parent, bindDepth: bindDepth)

        case let .branch(_, _, _, _, choice):
            // Branch nodes are handled by pick-site detection in walkGroup.
            // If reached directly, walk the choice subtree.
            return walk(choice, offset: offset, parent: parent, bindDepth: bindDepth)

        case let .group(array, isOpaque):
            return walkGroup(children: array, isOpaque: isOpaque, offset: offset, parent: parent, bindDepth: bindDepth)

        case let .bind(inner, bound):
            return walkBind(inner: inner, bound: bound, offset: offset, parent: parent, bindDepth: bindDepth)

        case let .resize(_, choices):
            // Resize is operational — skip the node, walk children as a group.
            return walkGroupChildren(choices, offset: offset, parent: parent, bindDepth: bindDepth)

        case let .selected(inner):
            // Unwrap and walk the inner tree.
            return walk(inner, offset: offset, parent: parent, bindDepth: bindDepth)
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
        bindDepth: Int
    ) -> Int {
        let nodeID = emitNode(
            kind: .sequence(SequenceMetadata(
                lengthConstraint: metadata.validRange,
                elementCount: elements.count
            )),
            positionRange: nil, // Set after children are walked
            children: [],
            parent: parent
        )
        if let parent {
            containmentEdges.append(ContainmentEdge(source: parent, target: nodeID))
        }

        var consumed = 1 // open marker
        var childIDs: [Int] = []
        childIDs.reserveCapacity(elements.count)

        var elementIndex = 0
        while elementIndex < elements.count {
            let childStartID = nextNodeID
            let elementConsumed = walk(
                elements[elementIndex],
                offset: offset + consumed,
                parent: nodeID,
                bindDepth: bindDepth
            )
            consumed += elementConsumed
            // The walk may have emitted one or more nodes; the first is the direct child.
            if childStartID < nextNodeID {
                childIDs.append(childStartID)
            }
            elementIndex += 1
        }

        consumed += 1 // close marker

        // Patch the node with children and position range.
        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
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
        bindDepth: Int
    ) -> Int {
        // Detect pick site: all children are .branch or .selected, with exactly one .selected(.branch(...)).
        if let pickResult = detectPickSite(array) {
            return walkPickSite(
                array: array,
                selectedBranch: pickResult,
                offset: offset,
                parent: parent,
                bindDepth: bindDepth
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
                bindDepth: bindDepth
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
        bindDepth: Int
    ) -> Int {
        let nodeID = emitNode(
            kind: .pick(PickMetadata(
                siteID: selectedBranch.siteID,
                depthMaskedSiteID: selectedBranch.siteID / 1000,
                branchIDs: selectedBranch.branchIDs,
                selectedID: selectedBranch.selectedID,
                selectedChildIndex: 0 // Patched below
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
                    bindDepth: bindDepth
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
                    siteID: metadata.siteID,
                    depthMaskedSiteID: metadata.depthMaskedSiteID,
                    branchIDs: metadata.branchIDs,
                    selectedID: metadata.selectedID,
                    selectedChildIndex: selectedChildIndex
                )),
                positionRange: offset ... (offset + consumed - 1),
                children: childIDs,
                parent: parent
            )
        }
        return consumed
    }

    /// Walks an inactive (unselected) branch subtree with nil position ranges on all nodes.
    private mutating func walkInactiveBranch(
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

        case .just, .getSize:
            break

        case let .sequence(_, elements, metadata):
            let nodeID = emitNode(
                kind: .sequence(SequenceMetadata(
                    lengthConstraint: metadata.validRange,
                    elementCount: elements.count
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
                        boundChildIndex: 1
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
                siteID: info.siteID,
                depthMaskedSiteID: info.siteID / 1000,
                branchIDs: info.branchIDs,
                selectedID: info.selectedID,
                selectedChildIndex: 0
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

    private mutating func walkBind(
        inner: ChoiceTree,
        bound: ChoiceTree,
        offset: Int,
        parent: Int?,
        bindDepth: Int
    ) -> Int {
        if inner.isGetSize {
            // getSize-bind is transparent — flattens as group markers. Walk children directly.
            // getSize contributes 0 entries; bound content appears as-is.
            var consumed = 1 // group open
            // getSize is skipped (0 entries).
            let boundConsumed = walk(bound, offset: offset + consumed, parent: parent, bindDepth: bindDepth)
            consumed += boundConsumed
            consumed += 1 // group close
            return consumed
        }

        let nodeID = emitNode(
            kind: .bind(BindMetadata(
                isStructurallyConstant: bound.containsBind == false && bound.containsPicks == false,
                bindDepth: bindDepth,
                innerChildIndex: 0,
                boundChildIndex: 1
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
        let innerConsumed = walk(inner, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth)
        consumed += innerConsumed

        let boundStartID = nextNodeID
        let boundConsumed = walk(bound, offset: offset + consumed, parent: nodeID, bindDepth: bindDepth + 1)
        consumed += boundConsumed

        consumed += 1 // bind close

        var childIDs: [Int] = []
        if innerStartID < nextNodeID {
            childIDs.append(innerStartID)
        }
        if boundStartID < nextNodeID {
            childIDs.append(boundStartID)
        }

        // Dependency edges are computed in the post-walk assembly pass from bind
        // node metadata (innerChildIndex → bound subtree structural nodes).

        nodes[nodeID] = ChoiceGraphNode(
            id: nodeID,
            kind: nodes[nodeID].kind,
            positionRange: offset ... (offset + consumed - 1),
            children: childIDs,
            parent: parent
        )
        return consumed
    }

    // MARK: - Helpers

    /// Walks an array of children as a group (for .resize), without emitting a zip node.
    private mutating func walkGroupChildren(
        _ children: [ChoiceTree],
        offset: Int,
        parent: Int?,
        bindDepth: Int
    ) -> Int {
        var consumed = 1 // group open
        for child in children {
            consumed += walk(child, offset: offset + consumed, parent: parent, bindDepth: bindDepth)
        }
        consumed += 1 // group close
        return consumed
    }

    private mutating func emitNode(
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

    // MARK: - Pick-Site Detection

    /// Information extracted from a pick-site group.
    private struct PickSiteInfo {
        let siteID: UInt64
        let selectedID: UInt64
        let branchIDs: [UInt64]
    }

    /// Detects whether a group's children form a pick site.
    ///
    /// A pick site is a group where all children are `.branch` or `.selected`, with exactly one `.selected(.branch(...))`. Mirrors the detection logic in ``ChoiceTree/flattenedEntryCount`` and ``ChoiceDependencyGraph/collectBindTreeNodes(from:offset:into:)``.
    private func detectPickSite(_ array: [ChoiceTree]) -> PickSiteInfo? {
        guard array.allSatisfy({ $0.isBranch || $0.isSelected }) else {
            return nil
        }
        guard let selected = array.first(where: \.isSelected) else {
            return nil
        }
        guard case let .selected(.branch(siteID, _, id, branchIDs, _)) = selected else {
            return nil
        }
        return PickSiteInfo(siteID: siteID, selectedID: id, branchIDs: branchIDs)
    }

    // MARK: - Subtree Construction (for lifecycle rebuilds)

    /// Result of building a subtree for dynamic region replacement.
    struct SubtreeResult {
        let nodes: [ChoiceGraphNode]
        let containmentEdges: [ContainmentEdge]
        let dependencyEdges: [DependencyEdge]
    }

    /// Builds a subtree from a ``ChoiceTree`` for dynamic region replacement.
    ///
    /// Used by ``ChoiceGraph/rebuildBoundSubtree(bindNodeID:newBoundTree:)`` to walk a new bound tree and produce nodes/edges that can be spliced into an existing graph.
    ///
    /// - Parameters:
    ///   - tree: The new subtree to walk.
    ///   - startingOffset: The ``ChoiceSequence`` offset where this subtree starts.
    ///   - parent: The parent node ID in the existing graph.
    ///   - bindDepth: The bind nesting depth at this position.
    ///   - nodeIDOffset: The starting node ID for new nodes (to avoid collisions with existing graph nodes).
    static func buildSubtree(
        from tree: ChoiceTree,
        startingOffset: Int,
        parent: Int?,
        bindDepth: Int,
        nodeIDOffset: Int
    ) -> SubtreeResult {
        var builder = ChoiceGraphBuilder()
        builder.nextNodeID = nodeIDOffset
        _ = builder.walk(tree, offset: startingOffset, parent: parent, bindDepth: bindDepth)

        // Compute dependency edges within the subtree.
        var subtreeDependencyEdges: [DependencyEdge] = []
        for node in builder.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            var stack = [boundChildID]
            while stack.isEmpty == false {
                let current = stack.removeLast()
                guard current - nodeIDOffset >= 0,
                      current - nodeIDOffset < builder.nodes.count else { continue }
                let target = builder.nodes[current - nodeIDOffset]
                switch target.kind {
                case .bind, .pick:
                    subtreeDependencyEdges.append(DependencyEdge(source: innerChildID, target: current))
                case .chooseBits, .zip, .sequence:
                    break
                }
                for child in target.children {
                    stack.append(child)
                }
            }
        }

        return SubtreeResult(
            nodes: builder.nodes,
            containmentEdges: builder.containmentEdges,
            dependencyEdges: subtreeDependencyEdges
        )
    }

    // MARK: - Assembly

    /// Assembles the final ``ChoiceGraph`` from collected nodes and edges.
    private func assembleGraph() -> ChoiceGraph {
        // Post-walk: compute dependency edges from bind node metadata.
        var allDependencyEdges = dependencyEdges
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            let boundChildID = node.children[metadata.boundChildIndex]
            // Add edges from the inner child to all structural nodes in the bound subtree.
            var stack = [boundChildID]
            while stack.isEmpty == false {
                let current = stack.removeLast()
                guard current < nodes.count else { continue }
                let target = nodes[current]
                switch target.kind {
                case .bind, .pick:
                    allDependencyEdges.append(DependencyEdge(source: innerChildID, target: current))
                case .chooseBits, .zip, .sequence:
                    break
                }
                for child in target.children {
                    stack.append(child)
                }
            }
        }

        // Self-similarity edges: group active pick nodes by depthMaskedSiteID.
        var selfSimilarityEdges: [SelfSimilarityEdge] = []
        var picksByMaskedSiteID: [UInt64: [Int]] = [:]
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue } // Active picks only
            picksByMaskedSiteID[metadata.depthMaskedSiteID, default: []].append(node.id)
        }
        for (_, pickIDs) in picksByMaskedSiteID where pickIDs.count >= 2 {
            var indexA = 0
            while indexA < pickIDs.count {
                var indexB = indexA + 1
                while indexB < pickIDs.count {
                    let nodeA = nodes[pickIDs[indexA]]
                    let nodeB = nodes[pickIDs[indexB]]
                    let sizeA = subtreeSequenceLength(nodeA)
                    let sizeB = subtreeSequenceLength(nodeB)
                    selfSimilarityEdges.append(SelfSimilarityEdge(
                        nodeA: pickIDs[indexA],
                        nodeB: pickIDs[indexB],
                        sizeDelta: sizeA - sizeB
                    ))
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Topological order via Kahn's algorithm on dependency edges.
        let topologicalOrder = computeTopologicalOrder(
            nodeCount: nodes.count,
            dependencyEdges: allDependencyEdges
        )

        // Reachability via reverse topological propagation.
        let reachability = computeReachability(
            nodeCount: nodes.count,
            dependencyEdges: allDependencyEdges,
            topologicalOrder: topologicalOrder
        )

        return ChoiceGraph(
            nodes: nodes,
            containmentEdges: containmentEdges,
            dependencyEdges: allDependencyEdges,
            selfSimilarityEdges: selfSimilarityEdges,
            typeCompatibilityEdges: [],
            sourceSinkStatus: [:],
            topologicalOrder: topologicalOrder,
            reachability: reachability
        )
    }

    /// Computes the sequence length covered by a node's subtree.
    private func subtreeSequenceLength(_ node: ChoiceGraphNode) -> Int {
        guard let range = node.positionRange else { return 0 }
        return range.count
    }

    // MARK: - Topological Sort

    /// Computes topological order of nodes via Kahn's algorithm on dependency edges.
    ///
    /// Returns node IDs in dependency order (roots first). Only nodes that appear in dependency edges are included.
    ///
    /// - Complexity: O(*V* + *E*) where *V* is the node count and *E* is the dependency edge count.
    private func computeTopologicalOrder(
        nodeCount: Int,
        dependencyEdges: [DependencyEdge]
    ) -> [Int] {
        var inDegree = [Int](repeating: 0, count: nodeCount)
        var adjacency = [[Int]](repeating: [], count: nodeCount)
        for edge in dependencyEdges {
            adjacency[edge.source].append(edge.target)
            inDegree[edge.target] += 1
        }

        // Only include nodes that participate in dependency relationships.
        var participatingNodes = Set<Int>()
        for edge in dependencyEdges {
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
            for dependent in adjacency[current] {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }
        return order
    }

    // MARK: - Reachability

    /// Computes transitive closure of dependency edges via reverse topological propagation.
    ///
    /// `reachability[i]` contains all node IDs reachable from node `i` via one or more dependency edges.
    ///
    /// - Complexity: O(*V* * *E*) time, O(*V*^2) space.
    private func computeReachability(
        nodeCount: Int,
        dependencyEdges: [DependencyEdge],
        topologicalOrder: [Int]
    ) -> [Int: Set<Int>] {
        var adjacency = [[Int]](repeating: [], count: nodeCount)
        for edge in dependencyEdges {
            adjacency[edge.source].append(edge.target)
        }

        var result = [Int: Set<Int>]()
        for nodeID in topologicalOrder.reversed() {
            var reachable = Set<Int>()
            for dependent in adjacency[nodeID] {
                reachable.insert(dependent)
                if let transitive = result[dependent] {
                    reachable.formUnion(transitive)
                }
            }
            if reachable.isEmpty == false {
                result[nodeID] = reachable
            }
        }
        return result
    }
}
