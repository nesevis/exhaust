//
//  ChoiceDependencyGraph.swift
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

/// A node in the ``ChoiceDependencyGraph`` representing a structural position or range of positions.
public struct DependencyNode: Equatable, Sendable {
    /// The range of ``ChoiceSequence`` indices this node covers.
    public let positionRange: ClosedRange<Int>

    /// Whether this position is structural (and what kind) or a leaf.
    public let kind: PositionClassification

    /// Whether reducing this node's value cannot change the structure of its bound subtree.
    ///
    /// Always `false` for branch selectors. For bind-inner nodes, `true` when the bound subtree contains no nested data-dependent binds.
    public let isStructurallyConstant: Bool

    /// The range of ``ChoiceSequence`` indices this node controls.
    ///
    /// For bind-inner nodes, this is the bound range. For branch-selector nodes, this is the selected subtree range. `nil` for branch selectors with an empty selected subtree.
    public let scopeRange: ClosedRange<Int>?

    /// Indices into ``ChoiceDependencyGraph/nodes`` of nodes that depend on this node's value.
    public var dependents: [Int]
}

// MARK: - Choice Dependency Graph

/// Directed acyclic graph capturing structural dependencies between positions in a ``ChoiceSequence``.
///
/// Nodes represent structural positions (bind inners and branch selectors). Edges point from a structural position to the structural positions it controls. Leaf positions (independent values) are collected separately.
public struct ChoiceDependencyGraph: Sendable {
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
    ) -> ChoiceDependencyGraph {
        // Collect bind tree nodes with their flattened offsets for constancy classification.
        var bindTreeNodes: [(bound: ChoiceTree, offset: Int)] = []
        _ = collectBindTreeNodes(from: tree, offset: 0, into: &bindTreeNodes)
        // Index by offset for O(1) lookup per region instead of a linear scan.
        let bindTreeByOffset = Dictionary(uniqueKeysWithValues: bindTreeNodes.map { ($0.offset, $0) })

        var nodes: [DependencyNode] = []

        // Bind-inner nodes.
        for (regionIndex, region) in bindIndex.regions.enumerated() {
            let treeNode = bindTreeByOffset[region.bindSpanRange.lowerBound]
            let isConstant = treeNode.map { $0.bound.containsBind == false && $0.bound.containsPicks == false } ?? false

            nodes.append(DependencyNode(
                positionRange: region.innerRange,
                kind: .structural(.bindInner(regionIndex: regionIndex)),
                isStructurallyConstant: isConstant,
                scopeRange: region.boundRange,
                dependents: []
            ))
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
                    let subtreeStart = branchIndex + 1
                    let subtreeEnd = groupRange.upperBound - 1
                    let subtreeRange: ClosedRange<Int>? =
                        subtreeStart <= subtreeEnd ? subtreeStart ... subtreeEnd : nil

                    nodes.append(DependencyNode(
                        positionRange: branchIndex ... branchIndex,
                        kind: .structural(.branchSelector),
                        isStructurallyConstant: false,
                        scopeRange: subtreeRange,
                        dependents: []
                    ))
                }
            }
            index += 1
        }

        // Build edges between structural nodes.
        // Sort by lowerBound once. Non-overlapping node ranges guarantee upperBound is also
        // non-decreasing in this order, enabling binary-search start points for both queries.
        let sortedByLower = (0..<nodes.count).sorted {
            nodes[$0].positionRange.lowerBound < nodes[$1].positionRange.lowerBound
        }
        for i in 0..<nodes.count {
            guard let scope = nodes[i].scopeRange else { continue }
            switch nodes[i].kind {
            case .structural(.bindInner):
                // Overlap: j.lowerBound ≤ scope.upperBound ∧ j.upperBound ≥ scope.lowerBound.
                // Binary-search for first j where j.upperBound ≥ scope.lowerBound.
                var lo = 0, hi = sortedByLower.count
                while lo < hi {
                    let mid = lo + (hi - lo) / 2
                    if nodes[sortedByLower[mid]].positionRange.upperBound < scope.lowerBound {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }
                while lo < sortedByLower.count {
                    let j = sortedByLower[lo]
                    let targetRange = nodes[j].positionRange
                    guard targetRange.lowerBound <= scope.upperBound else { break }
                    if j != i { nodes[i].dependents.append(j) }
                    lo += 1
                }
            case .structural(.branchSelector):
                // Containment: scope.lowerBound ≤ j.lowerBound ∧ j.upperBound ≤ scope.upperBound.
                // Binary-search for first j where j.lowerBound ≥ scope.lowerBound.
                var lo = 0, hi = sortedByLower.count
                while lo < hi {
                    let mid = lo + (hi - lo) / 2
                    if nodes[sortedByLower[mid]].positionRange.lowerBound < scope.lowerBound {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }
                while lo < sortedByLower.count {
                    let j = sortedByLower[lo]
                    let targetRange = nodes[j].positionRange
                    guard targetRange.lowerBound <= scope.upperBound else { break }
                    if j != i && targetRange.upperBound <= scope.upperBound {
                        nodes[i].dependents.append(j)
                    }
                    lo += 1
                }
            default:
                break
            }
        }

        let topologicalOrder = kahnSort(nodes: nodes)
        let leafPositions = collectLeafPositions(from: sequence, nodes: nodes)

        return ChoiceDependencyGraph(
            nodes: nodes,
            topologicalOrder: topologicalOrder,
            leafPositions: leafPositions
        )
    }
}

// MARK: - Internal Helpers

extension ChoiceDependencyGraph {
    /// Returns bind-inner node indices in topological order with their dependency edges to other bind-inner nodes.
    ///
    /// Used by ``ProductSpaceBatchEncoder`` to determine which axes are independent (Cartesian product) versus dependent (topological enumeration).
    func bindInnerTopology() -> [(nodeIndex: Int, regionIndex: Int, dependsOn: [Int])] {
        // Collect bind-inner node indices.
        var bindInnerNodeIndices = Set<Int>()
        for (index, node) in nodes.enumerated() {
            if case .structural(.bindInner) = node.kind {
                bindInnerNodeIndices.insert(index)
            }
        }

        // Filter topological order to bind-inner nodes, with dependency edges restricted to other bind-inner nodes.
        var result: [(nodeIndex: Int, regionIndex: Int, dependsOn: [Int])] = []
        for nodeIndex in topologicalOrder {
            guard bindInnerNodeIndices.contains(nodeIndex) else { continue }
            let node = nodes[nodeIndex]
            guard case let .structural(.bindInner(regionIndex: regionIndex)) = node.kind else {
                continue
            }
            let bindInnerDependsOn = node.dependents.filter { bindInnerNodeIndices.contains($0) }
            result.append((nodeIndex: nodeIndex, regionIndex: regionIndex, dependsOn: bindInnerDependsOn))
        }
        return result
    }

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

private extension ChoiceDependencyGraph {
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
        var inStructural = [Bool](repeating: false, count: sequence.count)
        for node in nodes {
            for i in node.positionRange {
                inStructural[i] = true
            }
        }
        var leafPositions = [ClosedRange<Int>]()
        var currentLeafStart: Int?

        for i in 0..<sequence.count {
            let isLeaf: Bool
            switch sequence[i] {
            case .value, .reduced:
                isLeaf = inStructural[i] == false
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

// MARK: - Structural Fingerprint

/// A lightweight summary of a choice tree's structural shape.
///
/// Two trees with the same fingerprint have the same flattened width and the same total bind nesting depth across all value positions. A change in fingerprint indicates a structural change (positions added, removed, or moved across bind boundaries).
public struct StructuralFingerprint: Equatable, Sendable {
    /// The total number of entries in the flattened ``ChoiceSequence``.
    public let width: Int

    /// The sum of bind depths across all value positions.
    public let bindDepthSum: Int

    /// Computes the skeleton fingerprint from a choice tree and its bind span index.
    public static func from(
        _ tree: ChoiceTree,
        bindIndex: BindSpanIndex
    ) -> StructuralFingerprint {
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
        return StructuralFingerprint(width: width, bindDepthSum: depthSum)
    }
}
