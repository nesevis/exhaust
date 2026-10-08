import Testing
@testable import ExhaustCore

@Suite("Tree traversal deletion selection")
struct TreeDeletionSelectionTests {
    @Test("The first batch reduces outer and retained inner sequences to their minima")
    func retainedDescendantsReachTheirMinima() throws {
        let inner = sequence([1, 2, 3], minimum: 1)
        let tree = ChoiceTree.sequence(elements: [inner, inner, inner], metadata: .init(validRange: 1 ... 3, isRangeExplicit: true))
        let graph = ChoiceGraph.build(from: tree)
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
        #expect(scope.targets.map(\.elementNodeIDs.count).sorted() == [2, 2])
        let candidate = try #require(GraphStructuralEncoder.buildElementCandidate(scope: scope, sequence: ChoiceSequence(tree), graph: graph))
        let expected = ChoiceTree.sequence(elements: [sequence([1], minimum: 1, maximum: 3)], metadata: .init(validRange: 1 ... 3, isRangeExplicit: true))
        #expect(candidate == ChoiceSequence(expected))
    }

    @Test("Emptying an outer sequence prunes its descendants from the batch")
    func removedDescendantsArePruned() throws {
        let inner = sequence([1, 2], minimum: 0)
        let outer = ChoiceTree.sequence(elements: [inner, inner], metadata: .init(validRange: 0 ... 2, isRangeExplicit: true))
        let graph = ChoiceGraph.build(from: .group([outer, sequence([3, 4], minimum: 1)]))
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
        let outerID = try #require(graph.liveNodeIDs.first { graph.nodes[$0].parent == 0 })
        #expect(scope.targets.contains { $0.sequenceNodeID == outerID })
        #expect(scope.targets.allSatisfy { graph.nodes[$0.sequenceNodeID].parent == 0 })
    }

    @Test("A fixed-length outer sequence still exposes deletable inner sequences")
    func fixedAncestorsDoNotHideTargets() throws {
        let inner = sequence([1, 2], minimum: 0)
        let tree = ChoiceTree.sequence(elements: [inner, inner], metadata: .init(validRange: 2 ... 2, isRangeExplicit: true))
        let graph = ChoiceGraph.build(from: tree)
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
        #expect(scope.targets.allSatisfy { graph.nodes[$0.sequenceNodeID].parent == 0 })
        #expect(scope.targets.allSatisfy { $0.elementNodeIDs.count == 2 })
    }

    @Test("Changing a bind inner excludes edits to its current bound output")
    func bindInvalidationSeparatesTargets() throws {
        let tree = ChoiceTree.group([
            .bind(fingerprint: 17, inner: sequence([1, 2], minimum: 0), bound: sequence([3, 4], minimum: 0)),
            sequence([5, 6], minimum: 0),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let dependency = try #require(graph.reductionEdges.first)
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
        #expect(scope.targets.contains { $0.sequenceNodeID == dependency.upstreamNodeID })
        #expect(scope.targets.contains { $0.sequenceNodeID == dependency.downstreamNodeID } == false)
    }

    @Test("Two sequences under the same unchanged bind can be reduced together")
    func sharedBoundContextAllowsBatching() throws {
        let tree = ChoiceTree.bind(fingerprint: 17, inner: leaf(2), bound: .group([
            sequence([1, 2], minimum: 0), sequence([3, 4], minimum: 1),
        ]))
        let graph = ChoiceGraph.build(from: tree)
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
    }

    @Test("Bind invalidation covers every root inside transparent resize wrappers")
    func transparentBindRegionsAreComplete() throws {
        let tree = ChoiceTree.group([
            .bind(
                fingerprint: 17,
                inner: .resize(newSize: 10, choices: [leaf(2), sequence([1, 2], minimum: 0)]),
                bound: .resize(newSize: 10, choices: [sequence([3, 4], minimum: 0), sequence([5, 6], minimum: 0)])
            ),
            sequence([7, 8], minimum: 0),
        ])
        let graph = ChoiceGraph.build(from: tree)
        var source = BatchedCrossSequenceRemovalSource(graph: graph)
        let scope = try firstScope(&source)
        #expect(scope.targets.count == 2)
        let paths = scope.targets.map { graph.nodes[$0.sequenceNodeID].choicePath }
        #expect(paths.contains([.groupChild(0), .bindInner, .groupChild(1)]))
        #expect(paths.contains([.groupChild(1)]))
        #expect(paths.allSatisfy { $0.starts(with: [.groupChild(0), .bindBound]) == false })
    }

    @Test("The minimum batch is dispatched before a higher-yield source, then normal ordering resumes")
    func minimumBatchRunsFirst() throws {
        let graph = ChoiceGraph.build(from: .group([sequence([1, 2], minimum: 1), sequence([3, 4], minimum: 1)]))
        let highYield = GraphTransformation(operation: .remove(.subtree(nodeID: 0, yield: 1000)), priority: .init(structuralBenefit: 1000, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1))
        var sources: [AnyCandidateSource] = [
            .sorted(SortedCandidateSource([highYield])),
            .batchedCrossSequence(BatchedCrossSequenceRemovalSource(graph: graph)),
        ]
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(sources) == 1)
        let initial = sources[1].next()
        _ = try #require(initial)
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(sources) == 0)
        let nextHalf = sources[1].next()
        let half = try #require(nextHalf)
        guard case let .remove(.elements(scope)) = half.operation else {
            Issue.record("Expected a bisected deletion scope")
            return
        }
        #expect(scope.targets.count == 1)
    }

    @Test("The default reducer probes both sequence minima first and rebuilds after acceptance")
    func reducerStartsWithMinima() throws {
        let generator = Gen.zip(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 1 ... 4),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 2 ... 5)
        )
        let output: ([UInt64], [UInt64]) = ([1, 2, 3, 4], [5, 6, 7, 8])
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        var observed: [([UInt64], [UInt64])] = []
        var machine = ReductionMachine(gen: generator, initialTree: tree, initialOutput: output, config: .init(maxStalls: 2), collectStats: true) { candidate in
            observed.append(candidate)
            return false
        }
        var rebuilt = false
        for _ in 0 ..< 100 {
            if case .rebuilt = machine.next() {
                rebuilt = true
                break
            }
        }
        #expect(rebuilt)
        #expect(observed.count == 1)
        let first = try #require(observed.first)
        #expect(first.0 == [1])
        #expect(first.1 == [5, 6])
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
    }

    private func firstScope(_ source: inout BatchedCrossSequenceRemovalSource) throws -> ElementRemovalScope {
        let next = source.next()
        let transformation = try #require(next)
        guard case let .remove(.elements(scope)) = transformation.operation else {
            throw TestFailure.unexpectedOperation
        }
        return scope
    }

    private func sequence(_ values: [UInt64], minimum: UInt64, maximum: UInt64? = nil) -> ChoiceTree {
        .sequence(elements: values.map(leaf), metadata: .init(validRange: minimum ... (maximum ?? UInt64(values.count)), isRangeExplicit: true))
    }

    private func leaf(_ value: UInt64) -> ChoiceTree {
        .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 10))
    }

    private enum TestFailure: Error {
        case unexpectedOperation
    }
}
