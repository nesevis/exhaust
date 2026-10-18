import Testing
@testable import ExhaustCore

@Suite("Bounded coupling evidence")
struct CouplingTrackerTests {
    @Test("Character changes neither create coupling edges nor evict numeric history")
    func characterChangesDoNotDisplaceNumericEvidence() throws {
        let character = try #require(try Interpreters.reflect(Gen.character(in: "a" ... "z").gen, with: "z"))
        var graph = ChoiceGraph.build(from: .group(Array(repeating: character, count: CouplingTracker.maximumNodes + 1) + [.uint64(10), .uint64(20)]))
        let leaves = graph.leafNodes
        let source = leaves[leaves.count - 2]
        let partner = leaves[leaves.count - 1]
        var tracker = CouplingTracker()
        tracker.observe(motionNodes: [], convergedNodes: leaves, changedNodes: [], pass: 1, graph: &graph)
        tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: Set(leaves), pass: 2, graph: &graph)
        for pass in 3 ..< 3 + CouplingTracker.maximumHistory {
            tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: [leaves[0]], pass: pass, graph: &graph)
        }
        tracker.observe(motionNodes: Set(leaves.dropLast()), convergedNodes: [], changedNodes: [], pass: 100, graph: &graph)
        #expect(graph.couplingDependents[partner] == [source])
        #expect(graph.couplingDependents.count == 1)
    }

    @Test("No prior convergence or accepted movement supplies no evidence")
    func absentEvidence() {
        var graph = numericGraph(count: 3)
        let first = graph.leafNodes[0]
        var tracker = CouplingTracker()
        tracker.observe(motionNodes: [first], convergedNodes: [first], changedNodes: [], pass: 1, graph: &graph)
        tracker.observe(motionNodes: [first], convergedNodes: [first], changedNodes: [], pass: 2, graph: &graph)
        #expect(graph.couplingDependents.isEmpty)
    }

    @Test("An ambiguous window keeps both partners without asserting joint causality")
    func ambiguousWindow() {
        var graph = numericGraph(count: 3)
        let nodes = graph.leafNodes
        var tracker = CouplingTracker()
        tracker.observe(motionNodes: [], convergedNodes: [nodes[0]], changedNodes: [], pass: 1, graph: &graph)
        tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: [nodes[1]], pass: 2, graph: &graph)
        tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: [nodes[2]], pass: 3, graph: &graph)
        tracker.observe(motionNodes: [nodes[0]], convergedNodes: [nodes[0]], changedNodes: [], pass: 4, graph: &graph)
        #expect(graph.couplingDependents[nodes[1]] == [nodes[0]])
        #expect(graph.couplingDependents[nodes[2]] == [nodes[0]])
    }

    @Test("History expiry discards old attribution candidates")
    func boundedHistory() {
        var graph = numericGraph(count: 3)
        let nodes = graph.leafNodes
        var tracker = CouplingTracker()
        tracker.observe(motionNodes: [], convergedNodes: [nodes[0]], changedNodes: [], pass: 1, graph: &graph)
        tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: [nodes[1]], pass: 2, graph: &graph)
        for pass in 3 ..< 3 + CouplingTracker.maximumHistory {
            tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: [nodes[2]], pass: pass, graph: &graph)
        }
        tracker.observe(motionNodes: [nodes[0]], convergedNodes: [nodes[0]], changedNodes: [], pass: 100, graph: &graph)
        #expect(graph.couplingDependents[nodes[1]] == nil)
        #expect(graph.couplingDependents[nodes[2]] == [nodes[0]])
    }

    @Test("Coupling edges stop at the memory cap")
    func boundedEdges() {
        var graph = numericGraph(count: 300)
        let nodes = graph.leafNodes
        var tracker = CouplingTracker()
        tracker.observe(motionNodes: [], convergedNodes: nodes, changedNodes: [], pass: 1, graph: &graph)
        tracker.observe(motionNodes: [], convergedNodes: [], changedNodes: Set(nodes), pass: 2, graph: &graph)
        tracker.observe(motionNodes: Set(nodes), convergedNodes: nodes, changedNodes: [], pass: 3, graph: &graph)
        #expect(graph.couplingDependents.values.reduce(0) { $0 + $1.count } == CouplingTracker.maximumEdges)
    }

    private func numericGraph(count: Int) -> ChoiceGraph {
        ChoiceGraph.build(from: .group(Array(repeating: .uint64(10), count: count)))
    }
}
