//
//  ReorderingScopeQuery.swift
//  Exhaust
//

// MARK: - Reordering Scope Query

/// Static scope builder for the numeric reordering pass.
///
/// Derives pre-filtered sibling groups from graph ``SequenceMetadata/childPositionRanges`` and bind node metadata.
enum ReorderingScopeQuery {
    /// Builds a reordering scope from the graph's sequence and zip nodes, or `nil` if no eligible groups exist.
    ///
    /// For each sequence and zip node the builder groups direct children by ``kindCategory(_:)`` and emits one ``ReorderableGroup`` per kind-category bucket that has two or more members and passes the bind-inner containment check.
    ///
    /// The bind-inner exclusion uses a containment test (sibling ⊆ bind-inner range), not overlap. A bind block whose own length chooseBits sits inside it overlaps the bind-inner range but is not contained by it — moving the complete block carries inner and bound together, which is safe. Only a sibling whose range is entirely within a bind-inner range (that is, the sibling IS the bind-inner child) must be excluded.
    ///
    /// Returned groups are sorted deepest-first, rightmost-first so inner groups settle before outer groups compare them.
    static func build(graph: ChoiceGraph) -> ReorderingScope? {
        let bindInnerRanges = collectBindInnerRanges(graph: graph)
        var groups: [ReorderableGroup] = []

        for node in graph.nodes {
            guard node.positionRange != nil else { continue }

            let childRanges: [ClosedRange<Int>]
            let childKinds: [ChoiceGraphNodeKind]

            switch node.kind {
            case let .sequence(metadata):
                guard metadata.elementCount >= 2 else { continue }
                guard metadata.childPositionRanges.count >= 2 else { continue }
                childRanges = metadata.childPositionRanges
                childKinds = node.children.map { graph.nodes[$0].kind }

            case .zip:
                guard node.children.count >= 2 else { continue }
                let childNodes = node.children.map { graph.nodes[$0] }
                guard childNodes.allSatisfy({ $0.positionRange != nil }) else { continue }
                childRanges = childNodes.compactMap(\.positionRange)
                guard childRanges.count >= 2 else { continue }
                childKinds = childNodes.map(\.kind)

            default:
                continue
            }

            let depth = nodeDepth(nodeID: node.id, graph: graph)

            // Group children by kind category — one group per kind with >= 2 members.
            var byCategory: [Int: [(range: ClosedRange<Int>, kind: ChoiceGraphNodeKind)]] = [:]
            for (range, kind) in zip(childRanges, childKinds) {
                byCategory[kindCategory(kind), default: []].append((range, kind))
            }

            for (_, children) in byCategory where children.count >= 2 {
                let ranges = children.map(\.range)
                guard noBindInnerContainment(ranges, bindInnerRanges: bindInnerRanges) else { continue }
                groups.append(ReorderableGroup(depth: depth, ranges: ranges))
            }
        }

        guard groups.isEmpty == false else { return nil }

        let sorted = groups.sorted { lhs, rhs in
            if lhs.depth != rhs.depth {
                return lhs.depth > rhs.depth
            }
            return lhs.ranges[0].lowerBound > rhs.ranges[0].lowerBound
        }

        return .numericReorder(NumericReorderScope(groups: sorted))
    }

    // MARK: - Private Helpers

    private static func collectBindInnerRanges(graph: ChoiceGraph) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            if let innerRange = graph.nodes[innerChildID].positionRange {
                result.append(innerRange)
            }
        }
        return result
    }

    /// Returns `true` when no sibling range is entirely contained within any bind-inner range.
    ///
    /// Uses containment rather than overlap. A bind block that contains its own length chooseBits overlaps the bind-inner range of that chooseBits, but the block is not contained by it. Reordering the block moves inner and bound together, which is safe. Only a sibling whose range is entirely within a bind-inner range (that is, the sibling IS the bind-inner child) must be excluded.
    private static func noBindInnerContainment(
        _ childRanges: [ClosedRange<Int>],
        bindInnerRanges: [ClosedRange<Int>]
    ) -> Bool {
        for siblingRange in childRanges {
            for innerRange in bindInnerRanges {
                if innerRange.lowerBound <= siblingRange.lowerBound,
                   siblingRange.upperBound <= innerRange.upperBound {
                    return false
                }
            }
        }
        return true
    }

    /// Maps a ``ChoiceGraphNodeKind`` to a category integer for same-kind sibling comparison.
    ///
    /// `chooseBits` nodes are split by type family (unsigned/signed/floating) so that only siblings with comparable ``ChoiceValue`` types are grouped. `just` nodes are constant leaves with no value contribution and form their own category. Structural nodes (`bind`, `zip`, `sequence`, `pick`) each occupy a distinct category.
    private static func kindCategory(_ kind: ChoiceGraphNodeKind) -> Int {
        switch kind {
        case let .chooseBits(metadata):
            if metadata.typeTag.isFloatingPoint { return 2 }
            if metadata.typeTag.isSigned { return 1 }
            return 0
        case .just: return 3
        case .bind: return 4
        case .zip: return 5
        case .sequence: return 6
        case .pick: return 7
        }
    }

    private static func nodeDepth(nodeID: Int, graph: ChoiceGraph) -> Int {
        var depth = 0
        var current = graph.nodes[nodeID].parent
        while let parentID = current {
            depth += 1
            current = graph.nodes[parentID].parent
        }
        return depth
    }
}
