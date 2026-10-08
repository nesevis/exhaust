import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Streaming tree deletion")
struct TreeDeletionStreamingTests {
    @Test("Streaming plans preserve eager selection, target order, and yields over generated graphs")
    func plansMatchEagerSelection() throws {
        var nonemptyStreams = 0
        try exhaustCheck(ChoiceTreeGenerators.scopeTrees, maxIterations: 2000) { tree in
            let graph = ChoiceGraph.build(from: tree)
            let targets = eagerTargets(graph: graph)
            let selected = EagerTreeDeletionReference.select(targets: targets, graph: graph)
            let expected = targets.filter { selected.contains($0.sequenceNodeID) }
            var cursor = TreeDeletionSelection.Cursor(graph: graph)
            var plans: [TreeDeletionSelection.Plan] = []
            while let plan = cursor.next() {
                plans.append(plan)
            }
            nonemptyStreams += expected.isEmpty ? 0 : 1
            guard plans.count == expected.count else { return false }
            return zip(plans, expected).allSatisfy { plan, target in
                let expanded = plan.target
                guard case let .sequence(metadata) = graph.nodes[target.sequenceNodeID].kind else { return false }
                let yield = target.elementNodeIDs.reduce(0) { $0 + (graph.nodes[$1].positionRange?.count ?? 0) }
                return expanded.sequenceNodeID == target.sequenceNodeID
                    && expanded.elementNodeIDs == target.elementNodeIDs
                    && plan.yield == yield
                    && plan.deletableCount == metadata.elementCount - Int(metadata.lengthConstraint?.lowerBound ?? 0)
            }
        }
        #expect(nonemptyStreams >= 100)
    }

    @Test("A wide graph can return its first plan without inspecting the remaining siblings")
    func firstPlanDoesNotScanRemainingSiblings() throws {
        let sequence = ChoiceTree.sequence(
            elements: (0 ..< 100).map { .choice(ChoiceValue(UInt64($0), tag: .uint64), .init(validRange: 0 ... 100)) },
            metadata: .init(validRange: 3 ... 100, isRangeExplicit: true)
        )
        let graph = ChoiceGraph.build(from: .group(Array(repeating: sequence, count: 1000)))
        var cursor = TreeDeletionSelection.Cursor(graph: graph)
        let next = cursor.next()
        let plan = try #require(next)
        #expect(cursor.examinedNodeCount == 2)
        #expect(plan.children.count == 100)
        #expect(plan.firstRemovedChildIndex == 3)
        #expect(plan.target.elementNodeIDs == Array(graph.nodes[plan.sequenceNodeID].children.dropFirst(3)))
    }

    /// Retains the eager parent expansion and position sorting used before streaming.
    private func eagerTargets(graph: ChoiceGraph) -> [SequenceRemovalTarget] {
        let parentIDs = Set(graph.liveNodeIDs.compactMap { nodeID -> Int? in
            guard let parentID = graph.nodes[nodeID].parent,
                  case .sequence = graph.nodes[parentID].kind
            else { return nil }
            return parentID
        })
        return parentIDs.sorted().compactMap { parentID in
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { return nil }
            let deletable = metadata.elementCount - Int(metadata.lengthConstraint?.lowerBound ?? 0)
            guard deletable > 0 else { return nil }
            let children = graph.nodes[parentID].children.compactMap { childID -> (nodeID: Int, lowerBound: Int)? in
                guard let extent = graph.nodes[childID].positionRange else { return nil }
                return (childID, extent.lowerBound)
            }.sorted { $0.lowerBound < $1.lowerBound }
            return SequenceRemovalTarget(sequenceNodeID: parentID, elementNodeIDs: children.suffix(deletable).map(\.nodeID))
        }
    }
}

private enum EagerTreeDeletionReference {
    private struct Edit {
        let sequenceNodeID: Int
        let removedRanges: [ClosedRange<Int>]
        let invalidatedRanges: [ClosedRange<Int>]
    }

    /// Builds a greedy compatible batch against one graph snapshot. Node IDs follow the builder's preorder, so ancestors are considered before their descendants.
    static func select(targets: [SequenceRemovalTarget], graph: ChoiceGraph) -> Set<Int> {
        let bindRegions = graph.liveNodeIDs.compactMap { nodeID -> (inner: ClosedRange<Int>, bound: ClosedRange<Int>)? in
            let node = graph.nodes[nodeID]
            guard case let .bind(metadata) = node.kind,
                  let extent = node.positionRange,
                  node.children.indices.contains(metadata.boundChildIndex),
                  let boundStart = graph.nodes[node.children[metadata.boundChildIndex]].positionRange?.lowerBound,
                  extent.lowerBound + 1 < boundStart
            else { return nil }
            // Transparent resize wrappers can emit several roots. Enclosing bind boundaries cover all of them, whereas the first inner/bound child spans cover only one root.
            return (extent.lowerBound + 1 ... boundStart - 1, boundStart ... extent.upperBound - 1)
        }
        var selected: [Edit] = []
        for target in targets.sorted(by: { $0.sequenceNodeID < $1.sequenceNodeID }) {
            guard case let .sequence(metadata) = graph.nodes[target.sequenceNodeID].kind else { continue }
            let removedRanges = target.elementNodeIDs.compactMap { nodeID -> ClosedRange<Int>? in
                guard let childIndex = metadata.childIndexByNodeID[nodeID],
                      childIndex < metadata.childPositionRanges.count
                else { return graph.nodes[nodeID].positionRange }
                return metadata.childPositionRanges[childIndex]
            }
            guard removedRanges.isEmpty == false else { continue }
            let invalidatedRanges = bindRegions.compactMap { regions -> ClosedRange<Int>? in
                guard removedRanges.contains(where: { $0.overlaps(regions.inner) }),
                      removedRanges.contains(where: { $0.lowerBound <= regions.bound.lowerBound && $0.upperBound >= regions.bound.upperBound }) == false
                else { return nil }
                return regions.bound
            }
            let edit = Edit(sequenceNodeID: target.sequenceNodeID, removedRanges: removedRanges, invalidatedRanges: invalidatedRanges)
            guard selected.allSatisfy({ existing in
                overlaps(edit.removedRanges, existing.removedRanges) == false
                    && overlaps(edit.removedRanges, existing.invalidatedRanges) == false
                    && overlaps(edit.invalidatedRanges, existing.removedRanges) == false
            }) else { continue }
            selected.append(edit)
        }
        return Set(selected.map(\.sequenceNodeID))
    }

    private static func overlaps(_ first: [ClosedRange<Int>], _ second: [ClosedRange<Int>]) -> Bool {
        first.contains { range in second.contains { range.overlaps($0) } }
    }
}
