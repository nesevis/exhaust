import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ChoiceGraphDiff")
struct ChoiceGraphDiffTests {
    @Test("Identical graphs produce structurally identical diff")
    func identicalGraphsIdenticalDiff() {
        let graph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph, new: graph)

        #expect(diff.isStructurallyIdentical == true)
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.preserved.isEmpty == false)
    }

    @Test("Added nodes appear in diff when new graph has more structure")
    func addedNodesDetected() {
        let graph1 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.isStructurallyIdentical == false)
        #expect(diff.added.isEmpty == false)
    }

    @Test("Removed nodes appear in diff when old graph has more structure")
    func removedNodesDetected() {
        let graph1 = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.isStructurallyIdentical == false)
        #expect(diff.removed.isEmpty == false)
    }

    @Test("Preserved nodes map old IDs to new IDs")
    func preservedNodeMapping() {
        let graph = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph, new: graph)

        for (_, mapping) in diff.preserved {
            #expect(mapping.oldNodeID == mapping.newNodeID)
        }
    }

    @Test("Value changes only do not cause structural diff")
    func valueChangesNotStructural() {
        let graph1 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64(99, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.isStructurallyIdentical == true)
    }

    @Test("Added and removed sets are symmetric under reversal")
    func addedRemovedSymmetry() {
        let graph1 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let forward = ChoiceGraphDiff.diff(old: graph1, new: graph2)
        let backward = ChoiceGraphDiff.diff(old: graph2, new: graph1)

        #expect(forward.added == backward.removed)
        #expect(forward.removed == backward.added)
    }
}
