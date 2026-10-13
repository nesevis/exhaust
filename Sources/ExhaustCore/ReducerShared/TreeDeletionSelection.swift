/// Streams actual removal plans in tree order, retaining nested plans only when their containing elements survive.
///
/// The selection compares complete element extents, including transparent wrappers. Removing any part of a bind inner conservatively invalidates its bound region unless that region is also removed. Plans share the graph's child arrays and defer element-ID expansion until a scope is emitted.
enum TreeDeletionSelection {
    private struct Edit {
        let removedRanges: [ClosedRange<Int>]
        let invalidatedRanges: [ClosedRange<Int>]
    }

    /// Keeps a tail slice of the graph's existing child storage instead of allocating a target array during selection.
    struct Plan {
        let sequenceNodeID: Int
        let children: [Int]
        let firstRemovedChildIndex: Int
        let deletableCount: Int
        let yield: Int

        var target: SequenceRemovalTarget {
            SequenceRemovalTarget(sequenceNodeID: sequenceNodeID, elementNodeIDs: Array(children[firstRemovedChildIndex...]))
        }
    }

    /// Stops after each compatible plan; callers requesting an all-sequence probe must drain the cursor before dispatch.
    ///
    /// Node IDs follow builder preorder, and sequence children follow element order. Enclosing binds are encountered before their inner sequences, so bind regions are registered during traversal. A later bind inside a removed element disappears entirely and needs no invalidation record. Conflict state retains coalesced removal intervals and invalidated bind regions, so rejected plans do not retain per-element arrays. The immutable graph snapshot is needed only while discovering plans.
    struct Cursor: ScopeCursor {
        private let graph: ChoiceGraph
        private var bindRegions: [(inner: ClosedRange<Int>, bound: ClosedRange<Int>)] = []
        private(set) var examinedNodeCount = 0
        private var selected: [Edit] = []

        init(graph: ChoiceGraph) {
            self.graph = graph
        }

        mutating func next() -> Plan? {
            while examinedNodeCount < graph.nodes.count {
                let nodeID = examinedNodeCount
                examinedNodeCount += 1
                let node = graph.nodes[nodeID]
                guard let extent = node.positionRange else { continue }
                if case let .bind(metadata) = node.kind {
                    if node.children.indices.contains(metadata.boundChildIndex),
                       let boundStart = graph.nodes[node.children[metadata.boundChildIndex]].positionRange?.lowerBound,
                       extent.lowerBound + 1 < boundStart
                    {
                        // Enclosing boundaries cover every root emitted by transparent resize wrappers.
                        bindRegions.append((extent.lowerBound + 1 ... boundStart - 1, boundStart ... extent.upperBound - 1))
                    }
                    continue
                }
                guard case let .sequence(metadata) = node.kind,
                      node.children.isEmpty == false,
                      selected.contains(where: { edit in edit.removedRanges.contains { $0.lowerBound <= extent.lowerBound && $0.upperBound >= extent.upperBound } }) == false
                else { continue }

                let deletable = metadata.elementCount - Int(metadata.lengthConstraint?.lowerBound ?? 0)
                guard deletable > 0 else { continue }
                let firstRemovedChildIndex = max(0, node.children.count - deletable)
                let removedRanges = removalRanges(children: node.children, startingAt: firstRemovedChildIndex, metadata: metadata)
                guard removedRanges.isEmpty == false else { continue }
                let invalidatedRanges = bindRegions.compactMap { regions -> ClosedRange<Int>? in
                    guard removedRanges.contains(where: { $0.overlaps(regions.inner) }),
                          removedRanges.contains(where: { $0.lowerBound <= regions.bound.lowerBound && $0.upperBound >= regions.bound.upperBound }) == false
                    else { return nil }
                    return regions.bound
                }
                let edit = Edit(removedRanges: removedRanges, invalidatedRanges: invalidatedRanges)
                guard selected.allSatisfy({ existing in
                    Self.overlaps(edit.removedRanges, existing.removedRanges) == false
                        && Self.overlaps(edit.removedRanges, existing.invalidatedRanges) == false
                        && Self.overlaps(edit.invalidatedRanges, existing.removedRanges) == false
                }) else { continue }
                selected.append(edit)

                let yield = node.children[firstRemovedChildIndex...].reduce(0) { total, childID in
                    total + (graph.nodes[childID].positionRange?.count ?? 0)
                }
                return Plan(sequenceNodeID: nodeID, children: node.children, firstRemovedChildIndex: firstRemovedChildIndex, deletableCount: deletable, yield: yield)
            }
            return nil
        }

        /// Coalesces adjacent complete element extents without allocating individual removal targets.
        private func removalRanges(children: [Int], startingAt firstIndex: Int, metadata: SequenceMetadata) -> [ClosedRange<Int>] {
            var ranges: [ClosedRange<Int>] = []
            for nodeID in children[firstIndex...] {
                let extent: ClosedRange<Int>? = switch metadata.childIndexByNodeID[nodeID] {
                    case let childIndex? where childIndex < metadata.childPositionRanges.count:
                        metadata.childPositionRanges[childIndex]
                    default:
                        graph.nodes[nodeID].positionRange
                }
                guard let extent else { continue }
                if let previous = ranges.last, extent.lowerBound <= previous.upperBound + 1 {
                    ranges[ranges.count - 1] = previous.lowerBound ... max(previous.upperBound, extent.upperBound)
                } else {
                    ranges.append(extent)
                }
            }
            return ranges
        }

        private static func overlaps(_ first: [ClosedRange<Int>], _ second: [ClosedRange<Int>]) -> Bool {
            first.contains { range in second.contains { range.overlaps($0) } }
        }
    }
}
