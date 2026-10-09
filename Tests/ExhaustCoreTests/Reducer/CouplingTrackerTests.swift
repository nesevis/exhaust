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

    @Test("Coupling collection follows staged encoder eligibility without research diagnostics", arguments: [false, true], [false, true])
    func normalCollection(stagedEnabled: Bool, budgetEnabled: Bool) throws {
        let generator = Gen.zip(Gen.choose(in: UInt64(0) ... 100), Gen.choose(in: UInt64(0) ... 100))
        let initial: (UInt64, UInt64) = (10, 20)
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        let encoders: Set<EncoderName> = stagedEnabled ? [.stagedJointSearch] : [.valueSearch]
        let tuning = SchedulerTuning(stagedJointProbeBudget: budgetEnabled ? 512 : 0)
        var machine = ReductionMachine(gen: generator, initialTree: tree, initialOutput: initial, config: .init(maxStalls: 2, enabledEncoders: encoders, tuning: tuning), collectStats: true, property: { _ in true })
        let first = machine.graph.leafNodes[0]
        let second = machine.graph.leafNodes[1]
        #expect(machine.collectDiagnostics == false)
        _ = machine.applyPassReport(report(converged: [first: 10]))
        _ = machine.applyPassReport(report(changed: [second]))
        _ = machine.applyPassReport(report(converged: [first: 7]))
        #expect(machine.graph.couplingDependents[second] == (stagedEnabled && budgetEnabled ? [first] : nil))
        #expect(machine.stats.dispatchLog.isEmpty)
        #expect(machine.stats.couplingEdges.isEmpty)
        #expect(machine.stats.valueFloorMotionEvents == 0)
        machine.tree = .group([.uint64(1), .uint64(2), .uint64(3)])
        _ = machine.rebuildAndUpdateGraph()
        #expect(machine.graph.couplingDependents.isEmpty)
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

    /// Exercises the machine's report integration without invoking a property or adding probe counts.
    private func report(converged: [Int: UInt64] = [:], changed: Set<Int> = []) -> PassReport {
        PassReport(
            encoderName: .valueSearch,
            transformation: .init(operation: .minimize(.valueLeaves(.init(leaves: [], batchZeroEligible: false))), priority: .zeroBenefit),
            boundValueFingerprint: nil,
            composedUpstreamLifts: nil,
            liftMaterializations: nil,
            counts: .init(),
            anyAccepted: changed.isEmpty == false,
            anyRequiresRebuild: false,
            latestTreeIsStripped: false,
            convergenceRecords: converged.mapValues { .init(bound: $0, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0) },
            hadUnresolvedReplacement: false,
            acceptedLeafNodeIDs: changed
        )
    }
}
