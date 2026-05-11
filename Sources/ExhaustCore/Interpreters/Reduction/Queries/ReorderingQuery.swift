//
//  ReorderingQuery.swift
//  Exhaust
//

// MARK: - Reordering Scope Query

/// Static scope builder for the numeric reordering pass.
///
/// Derives pre-filtered sibling groups from graph ``SequenceMetadata/childPositionRanges`` and bind node metadata.
enum ReorderingQuery {
    /// Builds a reordering scope from the graph's sequence and zip nodes, or `nil` if no eligible groups exist.
    ///
    /// For each sequence and zip node the builder groups direct children by ``siblingGroupKey(_:)`` and emits one ``ReorderableGroup`` per bucket that has two or more members and passes the bind-inner containment check.
    ///
    /// The bind-inner exclusion uses a containment test (sibling ⊆ bind-inner range), not overlap. A bind block whose own length chooseBits sits inside it overlaps the bind-inner range but is not contained by it — moving the complete block carries inner and bound together, which is safe. Only a sibling whose range is entirely within a bind-inner range (that is, the sibling IS the bind-inner child) must be excluded.
    ///
    /// Returned groups are sorted deepest-first, rightmost-first so inner groups settle before outer groups compare them.
    static func build(graph: some ReadOnlyChoiceGraph) -> ReorderingScope? {
        let bindInnerRanges = collectBindInnerRanges(graph: graph)
        var groups: [ReorderableGroup] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]

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

            let depth = nodeDepth(nodeID: nodeID, graph: graph)

            var byCategory: [SiblingGroupKey: [ClosedRange<Int>]] = [:]
            for (range, kind) in zip(childRanges, childKinds) {
                byCategory[siblingGroupKey(kind), default: []].append(range)
            }

            for (_, ranges) in byCategory where ranges.count >= 2 {
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

    private static func collectBindInnerRanges(graph: some ReadOnlyChoiceGraph) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for node in graph.nodes {
            guard graph.isTombstoned(node.id) == false else { continue }
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
        guard bindInnerRanges.isEmpty == false else { return true }
        let sorted = bindInnerRanges.sorted { $0.lowerBound < $1.lowerBound }
        for siblingRange in childRanges {
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = low + (high - low) / 2
                if sorted[mid].lowerBound <= siblingRange.lowerBound {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            // Check all candidates at indices 0..<low whose lowerBound <= siblingRange.lowerBound.
            // Only the last few can contain the sibling — scan backward until lowerBound is too small
            // to possibly contain siblingRange (optimization: break early when upperBound < siblingRange.lowerBound).
            var candidate = low - 1
            while candidate >= 0 {
                let innerRange = sorted[candidate]
                if innerRange.upperBound < siblingRange.lowerBound { break }
                if siblingRange.upperBound <= innerRange.upperBound {
                    return false
                }
                candidate -= 1
            }
        }
        return true
    }

    private enum SiblingGroupKey: Hashable {
        case chooseBits(typeTag: TypeTag, constraintRange: ClosedRange<UInt64>?)
        case just
        case bind
        case zip
        case sequence(lengthConstraint: ClosedRange<UInt64>?)
        case pick
    }

    /// Maps a ``ChoiceGraphNodeKind`` to a grouping key for same-kind sibling comparison.
    ///
    /// `chooseBits` nodes are split by ``TypeTag`` so that only siblings with the same type are grouped. Constraint ranges ensure siblings with different valid ranges are not grouped — reordering between different ranges would produce out-of-range values.
    private static func siblingGroupKey(_ kind: ChoiceGraphNodeKind) -> SiblingGroupKey {
        switch kind {
        case let .chooseBits(metadata):
            .chooseBits(typeTag: metadata.typeTag, constraintRange: metadata.validRange)
        case .just: .just
        case .bind: .bind
        case .zip: .zip
        case let .sequence(metadata):
            .sequence(lengthConstraint: metadata.lengthConstraint)
        case .pick: .pick
        }
    }

    private static func nodeDepth(nodeID: Int, graph: some ReadOnlyChoiceGraph) -> Int {
        var depth = 0
        var current = graph.nodes[nodeID].parent
        while let parentID = current {
            depth += 1
            current = graph.nodes[parentID].parent
        }
        return depth
    }
}
