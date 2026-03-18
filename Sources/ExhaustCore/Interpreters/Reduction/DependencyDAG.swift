//
//  DependencyDAG.swift
//  Exhaust
//

// MARK: - Position Classification

/// Classifies a position in a ``ChoiceSequence`` as structural or leaf.
///
/// Structural positions control the shape of dependent subtrees (bind inners, branch selectors). Leaf positions are independent values that can be reduced without affecting structure.
public enum PositionClassification: Equatable, Sendable {
    /// A position that influences the structure of dependent positions.
    case structural(StructuralKind)

    /// A value position that does not affect the structure of other positions.
    case leaf

    /// The kind of structural influence a position exerts.
    public enum StructuralKind: Equatable, Sendable {
        /// The inner subtree of a data-dependent bind. Changing this value may alter the shape of the bound subtree.
        case bindInner(regionIndex: Int)

        /// A branch selector at a pick site. Changing the selected branch replaces the entire selected subtree.
        case branchSelector
    }
}

// MARK: - Dependency Node

/// A node in the ``DependencyDAG`` representing a structural position or range of positions.
public struct DependencyNode: Equatable, Sendable {
    /// The range of ``ChoiceSequence`` indices this node covers.
    public let positionRange: ClosedRange<Int>

    /// Whether this position is structural (and what kind) or a leaf.
    public let kind: PositionClassification

    /// Whether reducing this node's value cannot change the structure of its bound subtree.
    ///
    /// Always `false` for branch selectors. For bind-inner nodes, `true` when the bound subtree contains no nested data-dependent binds.
    public let isStructurallyConstant: Bool

    /// Indices into ``DependencyDAG/nodes`` of nodes that depend on this node's value.
    public var dependents: [Int]
}

// MARK: - Dependency DAG

/// Directed acyclic graph capturing structural dependencies between positions in a ``ChoiceSequence``.
///
/// Nodes represent structural positions (bind inners and branch selectors). Edges point from a structural position to the structural positions it controls. Leaf positions (independent values) are collected separately.
public struct DependencyDAG: Sendable {
    /// All structural nodes in the DAG.
    public let nodes: [DependencyNode]

    /// Indices into ``nodes`` in topological order (roots first).
    public let topologicalOrder: [Int]

    /// Ranges of ``ChoiceSequence`` indices that are leaf positions (values not inside any structural node's range).
    public let leafPositions: [ClosedRange<Int>]

    /// Builds a dependency DAG from a choice sequence, its tree, and the bind span index.
    ///
    /// Identifies bind-inner and branch-selector structural nodes, builds dependency edges between them, computes a topological ordering via Kahn's algorithm, and collects leaf positions.
    public static func build(
        from sequence: ChoiceSequence,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex
    ) -> DependencyDAG {
        // Collect bind tree nodes with their flattened offsets for constancy classification.
        var bindTreeNodes: [(bound: ChoiceTree, offset: Int)] = []
        _ = collectBindTreeNodes(from: tree, offset: 0, into: &bindTreeNodes)

        var nodes: [DependencyNode] = []
        // Scope ranges track where each node's dependents must fall.
        var scopeRanges: [ClosedRange<Int>] = []

        // Bind-inner nodes.
        for (regionIndex, region) in bindIndex.regions.enumerated() {
            let treeNode = bindTreeNodes.first { $0.offset == region.bindSpanRange.lowerBound }
            let isConstant = treeNode.map { $0.bound.containsBind == false } ?? false

            nodes.append(DependencyNode(
                positionRange: region.innerRange,
                kind: .structural(.bindInner(regionIndex: regionIndex)),
                isStructurallyConstant: isConstant,
                dependents: []
            ))
            scopeRanges.append(region.boundRange)
        }

        // Branch selector nodes.
        let containerSpans = ChoiceSequence.extractContainerSpans(from: sequence)

        var index = 0
        while index < sequence.count {
            if case .branch = sequence[index] {
                let branchIndex = index
                let enclosingGroup = smallestContainingGroupSpan(
                    at: branchIndex,
                    among: containerSpans
                )

                if let groupRange = enclosingGroup {
                    nodes.append(DependencyNode(
                        positionRange: branchIndex ... branchIndex,
                        kind: .structural(.branchSelector),
                        isStructurallyConstant: false,
                        dependents: []
                    ))

                    let subtreeStart = branchIndex + 1
                    let subtreeEnd = groupRange.upperBound - 1
                    if subtreeStart <= subtreeEnd {
                        scopeRanges.append(subtreeStart ... subtreeEnd)
                    } else {
                        // Empty selected subtree — no dependents possible.
                        scopeRanges.append(branchIndex ... branchIndex)
                    }
                }
            }
            index += 1
        }

        // Build edges between structural nodes.
        for i in 0..<nodes.count {
            let scope = scopeRanges[i]
            for j in 0..<nodes.count where i != j {
                let targetRange = nodes[j].positionRange
                let isDependent: Bool
                switch nodes[i].kind {
                case .structural(.bindInner):
                    // Dependent if target's position range overlaps the bind's bound range.
                    isDependent = targetRange.overlaps(scope)
                case .structural(.branchSelector):
                    // Dependent if target's position range is fully inside the selected subtree.
                    isDependent = scope.lowerBound <= targetRange.lowerBound
                        && targetRange.upperBound <= scope.upperBound
                default:
                    isDependent = false
                }
                if isDependent {
                    nodes[i].dependents.append(j)
                }
            }
        }

        let topologicalOrder = kahnSort(nodes: nodes)
        let leafPositions = collectLeafPositions(from: sequence, nodes: nodes)

        return DependencyDAG(
            nodes: nodes,
            topologicalOrder: topologicalOrder,
            leafPositions: leafPositions
        )
    }
}

// MARK: - Internal Helpers

extension DependencyDAG {
    /// Finds the smallest group container span containing the given index.
    static func smallestContainingGroupSpan(
        at index: Int,
        among spans: [ChoiceSpan]
    ) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        for span in spans {
            guard case .group(true) = span.kind else {
                continue
            }
            guard span.range.contains(index) else {
                continue
            }
            if best == nil || span.range.count < best!.count {
                best = span.range
            }
        }
        return best
    }
}

// MARK: - Private Helpers

private extension DependencyDAG {
    /// Topological sort using Kahn's algorithm. Returns node indices in dependency order (roots first).
    static func kahnSort(nodes: [DependencyNode]) -> [Int] {
        let count = nodes.count
        var inDegree = [Int](repeating: 0, count: count)
        for node in nodes {
            for dependent in node.dependents {
                inDegree[dependent] += 1
            }
        }

        var queue = [Int]()
        for i in 0..<count where inDegree[i] == 0 {
            queue.append(i)
        }

        var order = [Int]()
        order.reserveCapacity(count)
        var front = 0

        while front < queue.count {
            let current = queue[front]
            front += 1
            order.append(current)
            for dependent in nodes[current].dependents {
                inDegree[dependent] -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }

        return order
    }

    /// Collects leaf positions: value or reduced entries not inside any structural node's position range.
    static func collectLeafPositions(
        from sequence: ChoiceSequence,
        nodes: [DependencyNode]
    ) -> [ClosedRange<Int>] {
        let structuralPositions = Set(nodes.flatMap { Array($0.positionRange) })
        var leafPositions = [ClosedRange<Int>]()
        var currentLeafStart: Int?

        for i in 0..<sequence.count {
            let isLeaf: Bool
            switch sequence[i] {
            case .value, .reduced:
                isLeaf = structuralPositions.contains(i) == false
            default:
                isLeaf = false
            }

            if isLeaf {
                if currentLeafStart == nil {
                    currentLeafStart = i
                }
            } else {
                if let start = currentLeafStart {
                    leafPositions.append(start ... (i - 1))
                    currentLeafStart = nil
                }
            }
        }

        if let start = currentLeafStart {
            leafPositions.append(start ... (sequence.count - 1))
        }

        return leafPositions
    }

    /// Walks the choice tree in flatten order, collecting data-dependent bind nodes with their flattened offsets.
    ///
    /// Mirrors the traversal order of ``ChoiceSequence/flatten(_:includingAllBranches:)`` so that offsets correspond to ``ChoiceSequence`` indices.
    @discardableResult
    static func collectBindTreeNodes(
        from tree: ChoiceTree,
        offset: Int,
        into result: inout [(bound: ChoiceTree, offset: Int)]
    ) -> Int {
        switch tree {
        case .choice:
            return 1

        case .just:
            return 1

        case .getSize:
            return 0

        case let .sequence(_, elements, _):
            var consumed = 1 // open marker
            for element in elements {
                consumed += collectBindTreeNodes(from: element, offset: offset + consumed, into: &result)
            }
            return consumed + 1 // close marker

        case let .branch(_, _, _, _, choice):
            return collectBindTreeNodes(from: choice, offset: offset, into: &result)

        case let .group(array, _):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, _, _, choice)) = array.first(where: \.isSelected)
            {
                // Pick-site group: group open + branch entry + selected choice + group close.
                var consumed = 2
                consumed += collectBindTreeNodes(from: choice, offset: offset + consumed, into: &result)
                return consumed + 1
            } else {
                var consumed = 1 // group open
                for child in array {
                    consumed += collectBindTreeNodes(from: child, offset: offset + consumed, into: &result)
                }
                return consumed + 1 // group close
            }

        case let .bind(inner, bound):
            if inner.isGetSize {
                // getSize-bind flattens as group markers, not bind markers.
                var consumed = 1 // group open
                consumed += collectBindTreeNodes(from: inner, offset: offset + consumed, into: &result)
                consumed += collectBindTreeNodes(from: bound, offset: offset + consumed, into: &result)
                return consumed + 1 // group close
            } else {
                result.append((bound: bound, offset: offset))
                var consumed = 1 // bind open
                consumed += collectBindTreeNodes(from: inner, offset: offset + consumed, into: &result)
                consumed += collectBindTreeNodes(from: bound, offset: offset + consumed, into: &result)
                return consumed + 1 // bind close
            }

        case let .resize(_, choices):
            var consumed = 1 // group open
            for choice in choices {
                consumed += collectBindTreeNodes(from: choice, offset: offset + consumed, into: &result)
            }
            return consumed + 1 // group close

        case let .selected(inner):
            return collectBindTreeNodes(from: inner, offset: offset, into: &result)
        }
    }
}

// MARK: - Skeleton Fingerprint

/// A lightweight summary of a choice tree's structural shape.
///
/// Two trees with the same fingerprint have the same flattened width and the same total bind nesting depth across all value positions. A change in fingerprint indicates a structural change (positions added, removed, or moved across bind boundaries).
public struct SkeletonFingerprint: Equatable, Sendable {
    /// The total number of entries in the flattened ``ChoiceSequence``.
    public let width: Int

    /// The sum of bind depths across all value positions.
    public let bindDepthSum: Int

    /// Computes the skeleton fingerprint from a choice tree and its bind span index.
    public static func from(
        _ tree: ChoiceTree,
        bindIndex: BindSpanIndex
    ) -> SkeletonFingerprint {
        let width = tree.flattenedEntryCount
        let sequence = ChoiceSequence(tree)
        var depthSum = 0
        for i in 0..<sequence.count {
            switch sequence[i] {
            case .value, .reduced:
                depthSum += bindIndex.bindDepth(at: i)
            default:
                break
            }
        }
        return SkeletonFingerprint(width: width, bindDepthSum: depthSum)
    }
}
