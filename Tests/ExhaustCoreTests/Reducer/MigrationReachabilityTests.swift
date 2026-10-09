import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Migration dependency caching")
struct MigrationReachabilityTests {
    @Test("Cached migrations preserve eager ordering through directed paths, cycles, and full donors")
    func directedDependenciesMatchEager() throws {
        let tree = ChoiceTree.group([
            .sequence(elements: [.uint64(1)], metadata: .init(validRange: 1 ... 1, isRangeExplicit: true)),
            .uint64Sequence([2, 3]),
            .uint64Sequence([4]),
            .uint64Sequence([5]),
            .uint64Sequence([6]),
            .uint64Sequence([]),
        ])
        let base = ChoiceGraph.build(from: tree)
        let sequences = sequenceNodeIDs(in: base)
        #expect(sequences.count == 6)
        let bridge = try #require(base.leafNodes.first)
        let reverseBridge = try #require(base.leafNodes.last)
        let graph = graphWithDependencies(base, edges: [
            .init(source: sequences[1], target: bridge),
            .init(source: bridge, target: sequences[2]),
            .init(source: sequences[3], target: reverseBridge),
            .init(source: reverseBridge, target: sequences[0]),
            .init(source: sequences[2], target: sequences[4]),
            .init(source: sequences[4], target: sequences[2]),
            .init(source: sequences[5], target: sequences[1]),
        ])
        var source = MigrationCandidateSource(graph: graph)
        let actual = drain(&source)
        let expected = EagerScopeReference.migrationCandidates(graph: graph)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(actual.map(\.priority) == expected.map(\.priority))
        #expect(actual.isEmpty == false)
        let pairs = actual.compactMap { transformation -> [Int]? in
            guard case let .migrate(scope) = transformation.operation else {
                return nil
            }
            return [scope.sourceSequenceNodeID, scope.receiverSequenceNodeID]
        }
        #expect(pairs.contains([sequences[0], sequences[3]]) == false)
        #expect(pairs.contains([sequences[1], sequences[2]]) == false)
        #expect(pairs.contains([sequences[2], sequences[4]]) == false)
        #expect(pairs.contains([sequences[1], sequences[5]]) == false)
    }

    @Test("Bind controllers share positive searches across receivers while preserving complete scopes")
    func positiveResultsAreReused() {
        let controllerCount = 8
        let graph = bindGraph(controllerCount: controllerCount, boundElementCount: 12)
        var source = MigrationCandidateSource(graph: graph)
        let actual = drain(&source)
        let expected = EagerScopeReference.migrationCandidates(graph: graph)
        #expect(actual.count > 1000)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(actual.map(\.priority) == expected.map(\.priority))
        #expect(source.dependencyTraversalCount == controllerCount)
        #expect(source.dependencyCachedSourceCount == controllerCount)
        #expect(source.dependencyCachedNodeCount == controllerCount)
    }

    @Test("Dependencies ending outside the sequence domain share complete negative results")
    func negativeResultsAreReused() {
        let controllerCount = 8
        let graph = bindGraph(controllerCount: controllerCount, boundElementCount: 0)
        var source = MigrationCandidateSource(graph: graph)
        let actual = drain(&source)
        let expected = EagerScopeReference.migrationCandidates(graph: graph)
        #expect(actual.isEmpty == false)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(actual.map(\.priority) == expected.map(\.priority))
        #expect(source.dependencyTraversalCount == controllerCount)
        #expect(source.dependencyCachedSourceCount == 0)
        #expect(source.dependencyCachedNodeCount == 0)
    }

    @Test("Shared dependency fanout respects both positive cache budgets", arguments: [false, true])
    func cacheBudgetsStayBounded(nodeBudgetBinds: Bool) {
        let controllerCount = 40
        let targetCount = nodeBudgetBinds ? 200 : 1
        let base = ChoiceGraph.build(from: .group(
            Array(repeating: .uint64Sequence([1, 2]), count: controllerCount)
                + Array(repeating: .uint64Sequence([]), count: targetCount)
        ))
        let sequences = sequenceNodeIDs(in: base)
        let edges = sequences.prefix(controllerCount).flatMap { controller in
            sequences.suffix(targetCount).map { target in DependencyEdge(source: controller, target: target) }
        }
        let graph = graphWithDependencies(base, edges: edges)
        var source = MigrationCandidateSource(graph: graph)
        var maximumSources = 0
        var maximumNodes = 0
        var actual: [GraphTransformation] = []
        while let transformation = source.next() {
            actual.append(transformation)
            maximumSources = max(maximumSources, source.dependencyCachedSourceCount)
            maximumNodes = max(maximumNodes, source.dependencyCachedNodeCount)
            #expect(source.dependencyCachedSourceCount <= 32)
            #expect(source.dependencyCachedNodeCount <= 4096)
        }
        let expected = EagerScopeReference.migrationCandidates(graph: graph)
        #expect(actual.count == controllerCount * (controllerCount - 1) / 2)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(actual.map(\.priority) == expected.map(\.priority))
        #expect(maximumSources == (nodeBudgetBinds ? 20 : 32))
        #expect(maximumNodes == (nodeBudgetBinds ? 4000 : 32))
    }

    @Test("Copied migration cursors advance dependency caches independently")
    func copiedCursorsAreIndependent() throws {
        let graph = bindGraph(controllerCount: 8, boundElementCount: 12)
        var original = MigrationCandidateSource(graph: graph)
        for _ in 0 ..< 3 {
            let next = original.next()
            _ = try #require(next)
        }
        var copied = original
        let copiedSearches = copied.dependencyTraversalCount
        let copiedPriority = copied.peekPriority
        let remainingOriginal = drain(&original)
        #expect(original.dependencyTraversalCount > copiedSearches)
        #expect(copied.dependencyTraversalCount == copiedSearches)
        #expect(copied.peekPriority == copiedPriority)
        let remainingCopy = drain(&copied)
        #expect(remainingCopy.map(signature) == remainingOriginal.map(signature))
        #expect(copied.dependencyTraversalCount == original.dependencyTraversalCount)
    }

    @Test("Independent sequence sources take the no-outgoing-edge fast path")
    func independentSequencesNeedNoSearch() {
        let graph = ChoiceGraph.build(from: .group((0 ..< 40).map { _ in .uint64Sequence([1]) }))
        var source = MigrationCandidateSource(graph: graph)
        let actual = drain(&source)
        #expect(actual.count == 40 * 39 / 2)
        #expect(source.dependencyTraversalCount == 0)
        #expect(source.dependencyCachedSourceCount == 0)
        #expect(source.dependencyCachedNodeCount == 0)
    }

    // MARK: - Helpers

    /// Produces positive sequence results or dependencies ending at scalar nodes, with unrelated receivers after every controller.
    private func bindGraph(controllerCount: Int, boundElementCount: Int) -> ChoiceGraph {
        let tree = ChoiceTree.group((0 ..< controllerCount).map { index in
            let bound: ChoiceTree = boundElementCount == 0
                ? .uint64(1)
                : .uint64Sequence(Array(repeating: 1, count: boundElementCount))
            return .bind(fingerprint: UInt64(100 + index), inner: .uint64Sequence([1, 2]), bound: bound)
        } + Array(repeating: .uint64Sequence([1]), count: 64) + [.uint64Sequence([])])
        return ChoiceGraph.build(from: tree)
    }

    private func sequenceNodeIDs(in graph: ChoiceGraph) -> [Int] {
        graph.liveNodeIDs.filter { nodeID in
            if case .sequence = graph.nodes[nodeID].kind {
                return true
            }
            return false
        }
    }

    /// Keeps valid sequence topology while exercising dependency paths and cycles the graph builder's acyclic binds do not produce.
    private func graphWithDependencies(_ base: ChoiceGraph, edges: [DependencyEdge]) -> ChoiceGraph {
        var adjacency = Array(repeating: [Int](), count: base.nodes.count)
        for edge in edges {
            adjacency[edge.source].append(edge.target)
        }
        return ChoiceGraph(
            nodes: base.nodes,
            containmentEdges: base.containmentEdges,
            dependencyEdges: edges,
            selfSimilarityGroups: base.selfSimilarityGroups,
            liveNodeIDs: base.liveNodeIDs,
            leafNodes: base.leafNodes,
            characterLeafNodes: base.characterLeafNodes,
            topologicalOrder: base.topologicalOrder,
            dependencyAdjacency: adjacency
        )
    }

    /// Includes every migration payload field; separate assertions compare scheduling priorities.
    private func signature(_ transformation: GraphTransformation) -> MigrationSignature? {
        guard case let .migrate(scope) = transformation.operation else {
            Issue.record("Expected a migration transformation")
            return nil
        }
        return MigrationSignature(source: scope.sourceSequenceNodeID, receiver: scope.receiverSequenceNodeID, elements: scope.elementNodeIDs, extents: scope.elementPositionRanges, receiverRange: scope.receiverPositionRange, parent: scope.sourceParentSequenceNodeID)
    }

    /// Repeated peeks must leave both enumeration and actual dependency search work unchanged.
    private func drain(_ source: inout MigrationCandidateSource) -> [GraphTransformation] {
        var transformations: [GraphTransformation] = []
        while let priority = source.peekPriority {
            let searches = source.dependencyTraversalCount
            #expect(source.peekPriority == priority)
            #expect(source.dependencyTraversalCount == searches)
            guard let transformation = source.next() else {
                Issue.record("An advertised migration priority must have a scope")
                break
            }
            #expect(transformation.priority == priority)
            transformations.append(transformation)
        }
        #expect(source.next() == nil)
        return transformations
    }
}

/// Preserves payload equality without adding test-only conformances to production scopes.
private struct MigrationSignature: Equatable {
    let source: Int
    let receiver: Int
    let elements: [Int]
    let extents: [ClosedRange<Int>]
    let receiverRange: ClosedRange<Int>
    let parent: Int?
}
