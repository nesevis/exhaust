import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ChoiceGraphDiff")
struct ChoiceGraphDiffTests {
    @Test("Identical graphs allow structural source reuse")
    func identicalGraphsAllowStructuralSourceReuse() {
        let graph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph, new: graph)

        #expect(diff.canReuseStructuralSources == true)
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.preserved.count >= 2, "Both leaf nodes should be preserved")
    }

    @Test("Added nodes appear in diff when new graph has more structure")
    func addedNodesDetected() {
        let graph1 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.canReuseStructuralSources == false)
        #expect(diff.added.count >= 1,
                "Two-leaf zip vs single leaf should have at least one added path")
    }

    @Test("Removed nodes appear in diff when old graph has more structure")
    func removedNodesDetected() {
        let graph1 = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.canReuseStructuralSources == false)
        #expect(diff.removed.count >= 1,
                "Two-leaf zip vs single leaf should have at least one removed path")
    }

    @Test("Preserved nodes map old IDs to new IDs")
    func preservedNodeMapping() {
        let graph = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph, new: graph)

        for (_, mapping) in diff.preserved {
            #expect(mapping.oldNodeID == mapping.newNodeID)
        }
    }

    @Test("Value-only changes allow structural source reuse")
    func valueChangesAllowStructuralSourceReuse() {
        let graph1 = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let graph2 = GraphFixture(.uint64(99, in: 0 ... 100)).graph
        let diff = ChoiceGraphDiff.diff(old: graph1, new: graph2)

        #expect(diff.canReuseStructuralSources == true)
        #expect(diff.kindChangedPaths.isEmpty)
        #expect(diff.onlyLeafKindsChanged == false)
        #expect(diff.canReuseStructuralSourcesExceptPermutation == false)
    }

    @Test("A public bind changing its bound node kind is structural")
    func publicBindBoundKindChangeIsStructural() throws {
        let generator = ReflectiveGenerator<Bool>.bool().bind { condition in
            switch condition {
                case false:
                    ReflectiveGenerator<Int>.just(0)
                case true:
                    ReflectiveGenerator<Bool>.bool().map { _ in 1 }
            }
        }
        var choiceBoundTree: ChoiceTree?
        var constantBoundTree: ChoiceTree?

        for seed in UInt64(0) ..< 100 {
            var interpreter = ValueAndChoiceTreeInterpreter(
                generator.gen,
                materializePicks: false,
                seed: seed,
                maxRuns: 1
            )
            guard let (value, tree) = try interpreter.next() else {
                continue
            }
            switch value {
                case 0:
                    constantBoundTree = tree
                case 1:
                    choiceBoundTree = tree
                default:
                    Issue.record("Expected the public bind to produce zero or one")
            }
            if choiceBoundTree != nil, constantBoundTree != nil {
                break
            }
        }

        let choiceGraph = try ChoiceGraph.build(from: #require(choiceBoundTree))
        let constantGraph = try ChoiceGraph.build(from: #require(constantBoundTree))
        let choiceBoundNode = try #require(
            choiceGraph.nodes.first { $0.choicePath == [.bindBound] }
        )
        let constantBoundNode = try #require(
            constantGraph.nodes.first { $0.choicePath == [.bindBound] }
        )
        guard case .chooseBits = choiceBoundNode.kind else {
            Issue.record("Expected the true bind branch to contain a choice")
            return
        }
        guard case .just = constantBoundNode.kind else {
            Issue.record("Expected the false bind branch to contain a constant")
            return
        }

        let diff = ChoiceGraphDiff.diff(old: choiceGraph, new: constantGraph)

        #expect(diff.canReuseStructuralSources == false)
        #expect(diff.kindChangedPaths == [[.bindBound]])
        #expect(diff.onlyLeafKindsChanged == true)
        #expect(diff.canReuseStructuralSourcesExceptPermutation == true)

        let reverseDiff = ChoiceGraphDiff.diff(old: constantGraph, new: choiceGraph)

        #expect(reverseDiff.canReuseStructuralSources == false)
        #expect(reverseDiff.kindChangedPaths == [[.bindBound]])
        #expect(reverseDiff.onlyLeafKindsChanged == true)
        #expect(reverseDiff.canReuseStructuralSourcesExceptPermutation == true)
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

@Suite("Leaf-kind candidate source reuse")
struct LeafKindCandidateSourceReuseTests {
    @Test("Only non-permutation structural sources are reusable")
    func onlyNonPermutationStructuralSourcesAreReusable() {
        let sequenceGraph = GraphFixture(
            .uint64Sequence([10, 20, 30], in: 0 ... 100)
        ).graph
        let structuralSources = CandidateSourceBuilder.buildStructuralSources(
            from: sequenceGraph
        )

        #expect(structuralSources.isEmpty == false)
        #expect(structuralSources.allSatisfy(\.canReuseAfterLeafKindChange))

        let zipGraph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let permutationSources = CandidateSourceBuilder.buildPermutationSources(
            from: zipGraph
        )

        #expect(permutationSources.count == 1)
        #expect(permutationSources.allSatisfy(\.isPermutationSource))
        #expect(permutationSources.allSatisfy { $0.canReuseAfterLeafKindChange == false })

        let valueSources = CandidateSourceBuilder.buildValueSources(from: zipGraph)

        #expect(valueSources.isEmpty == false)
        #expect(valueSources.allSatisfy(\.isValueDependent))
        #expect(valueSources.allSatisfy { $0.canReuseAfterLeafKindChange == false })
    }
}
