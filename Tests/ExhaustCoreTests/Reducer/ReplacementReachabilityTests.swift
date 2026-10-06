import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Replacement reachability indexing and caching")
struct ReplacementReachabilityTests {
    @Test("Containment intervals match parent walks across reordered and inactive forest nodes")
    func containmentMatchesParentWalks() {
        let parents: [Int?] = [4, 0, nil, 4, 2, nil, 5, 1]
        let index = ContainmentIndex(parentNodeIDs: parents)
        for ancestor in parents.indices {
            for nodeID in parents.indices {
                #expect(index.isDescendant(nodeID, of: ancestor) == parentWalk(nodeID, ancestor: ancestor, parents: parents))
            }
        }
        #expect(index.isDescendant(-1, of: 0) == false)
        #expect(index.isDescendant(0, of: -1) == false)
        #expect(index.isDescendant(parents.count, of: 0) == false)
        #expect(index.isDescendant(0, of: parents.count) == false)
        #expect(ContainmentIndex(parentNodeIDs: []).isDescendant(0, of: 0) == false)
    }

    @Test("Deep containment preparation is iterative and descendant queries are strict")
    func deepContainment() {
        let count = 20000
        let parents: [Int?] = [nil] + (0 ..< count - 1).map { Optional($0) }
        let index = ContainmentIndex(parentNodeIDs: parents)
        for ancestor in parents.indices {
            #expect(index.isDescendant(count - 1, of: ancestor) == (ancestor < count - 1))
            #expect(index.isDescendant(ancestor, of: ancestor) == false)
            #expect(index.isDescendant(0, of: ancestor) == false)
        }
    }

    @Test("Restricted dependency caching preserves directed multihop and cycle reachability")
    func dependencyMatchesPointSearches() {
        let adjacency = [[1, 2], [3], [4], [0, 5], [5], [], [7], []]
        let candidates: Set = [0, 3, 5, 7]
        var cache = DependencyReachabilityCache(adjacency: adjacency, candidates: candidates)
        for _ in 0 ..< 3 {
            for source in adjacency.indices {
                for target in adjacency.indices {
                    let expected = source != target && candidates.contains(target)
                        && DependencyReachability.isReachable(from: source, to: target, adjacency: adjacency)
                    #expect(cache.isReachable(from: source, to: target) == expected)
                }
            }
        }
        #expect(cache.traversalCount == 6)
        #expect(cache.cachedSourceCount == 6)
        #expect(cache.cachedNodeCount == 10)
        #expect(cache.isReachable(from: -1, to: 3) == false)
        #expect(cache.isReachable(from: 0, to: -1) == false)
        #expect(cache.isReachable(from: adjacency.count, to: 3) == false)
        #expect(cache.isReachable(from: 0, to: adjacency.count) == false)
        #expect(cache.traversalCount == 6)
    }

    @Test("Leaf sources and complete negative results avoid repeated searches")
    func negativeResultsAreReused() {
        var cache = DependencyReachabilityCache(adjacency: [[1], [2], [], []], candidates: [0, 3])
        for _ in 0 ..< 100 {
            #expect(cache.isReachable(from: 0, to: 3) == false)
            #expect(cache.isReachable(from: 2, to: 3) == false)
            #expect(cache.isReachable(from: 3, to: 0) == false)
        }
        #expect(cache.traversalCount == 1)
        #expect(cache.cachedSourceCount == 0)
        #expect(cache.cachedNodeCount == 0)
    }

    @Test("The default node budget fits a complete result even for large candidate domains")
    func defaultBudgetScalesWithCandidates() {
        let count = 5000
        let candidates = Set(1 ... count)
        let adjacency = [Array(1 ... count)] + Array(repeating: [Int](), count: count)
        var cache = DependencyReachabilityCache(adjacency: adjacency, candidates: candidates)
        #expect(cache.isReachable(from: 0, to: 1) == true)
        #expect(cache.isReachable(from: 0, to: count) == true)
        #expect(cache.traversalCount == 1)
        #expect(cache.cachedSourceCount == 1)
        #expect(cache.cachedNodeCount == count)
    }

    @Test("Source budget evicts the least recently used complete result")
    func sourceBudgetUsesRecentAccess() {
        var cache = DependencyReachabilityCache(adjacency: [[3], [3], [3], []], candidates: [3], sourceLimit: 2)
        #expect(cache.isReachable(from: 0, to: 3) == true)
        #expect(cache.isReachable(from: 1, to: 3) == true)
        #expect(cache.isReachable(from: 0, to: 3) == true)
        #expect(cache.isReachable(from: 2, to: 3) == true)
        #expect(cache.traversalCount == 3)
        #expect(cache.cachedSourceCount == 2)
        #expect(cache.cachedNodeCount == 2)
        #expect(cache.isReachable(from: 0, to: 3) == true)
        #expect(cache.traversalCount == 3)
        #expect(cache.isReachable(from: 1, to: 3) == true)
        #expect(cache.traversalCount == 4)
        #expect(cache.cachedSourceCount == 2)
    }

    @Test("Node budget evicts whole results and never treats omitted targets as unreachable")
    func nodeBudgetPreservesCompleteAnswers() {
        let adjacency = [[3, 4], [3, 4, 5], [4], [], [], []]
        var cache = DependencyReachabilityCache(adjacency: adjacency, candidates: [3, 4, 5], sourceLimit: 3, nodeLimit: 3)
        #expect(cache.isReachable(from: 0, to: 3) == true)
        #expect(cache.cachedNodeCount == 2)
        #expect(cache.isReachable(from: 1, to: 5) == true)
        #expect(cache.cachedNodeCount == 3)
        #expect(cache.cachedSourceCount == 1)
        #expect(cache.isReachable(from: 1, to: 4) == true)
        #expect(cache.traversalCount == 2)
        #expect(cache.isReachable(from: 2, to: 4) == true)
        #expect(cache.cachedNodeCount == 1)
        #expect(cache.isReachable(from: 0, to: 4) == true)
        #expect(cache.traversalCount == 4)
        #expect(cache.cachedNodeCount == 3)
        #expect(cache.cachedSourceCount == 2)
    }

    @Test("Oversized results and disabled positive retention still answer every target exactly", arguments: [0, 1])
    func uncachedResultsRemainExact(nodeLimit: Int) {
        var cache = DependencyReachabilityCache(adjacency: [[1, 2], [], []], candidates: [1, 2], nodeLimit: nodeLimit)
        #expect(cache.isReachable(from: 0, to: 1) == true)
        #expect(cache.isReachable(from: 0, to: 2) == true)
        #expect(cache.traversalCount == 2)
        #expect(cache.cachedNodeCount == 0)
        #expect(cache.cachedSourceCount == 0)
        var disabled = DependencyReachabilityCache(adjacency: [[1], []], candidates: [1], sourceLimit: 0)
        #expect(disabled.isReachable(from: 0, to: 1) == true)
        #expect(disabled.isReachable(from: 0, to: 1) == true)
        #expect(disabled.traversalCount == 2)
        #expect(disabled.cachedSourceCount == 0)
    }

    @Test("Copied dependency caches advance independently")
    func cacheCopiesAreIndependent() {
        var original = DependencyReachabilityCache(adjacency: [[2], [2], []], candidates: [2], sourceLimit: 1)
        #expect(original.isReachable(from: 0, to: 2) == true)
        var copied = original
        #expect(original.isReachable(from: 1, to: 2) == true)
        #expect(copied.isReachable(from: 0, to: 2) == true)
        #expect(copied.traversalCount == 1)
        #expect(original.isReachable(from: 0, to: 2) == true)
        #expect(original.traversalCount == 3)
        #expect(copied.traversalCount == 1)
    }

    @Test("Depth-bounded replacement families preserve both orders without dependency searches")
    func boundedReplacementMatchesEager() {
        let memberCount = 120
        let maximumDepth = 8
        let graph = ChoiceGraph.build(from: nestedPickFamily(memberCount: memberCount, maximumDepth: maximumDepth))
        let members = graph.selfSimilarityGroups[42] ?? []
        #expect(members.count == memberCount)
        #expect(members.map { pickDepth(of: $0, graph: graph) }.max() == maximumDepth)
        var priority = ReplacementQuery.cursor(graph: graph)
        var discovery = ReplacementQuery.discoveryCursor(graph: graph)
        let expected = EagerScopeReference.replacementScopes(graph: graph)
        let actual = drain(&discovery)
        let actualPriority = drain(&priority)
        let expectedPriority = EagerScopeReference.replacementCandidates(graph: graph)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(actualPriority.map(signature) == expectedPriority.map(signature))
        #expect(actualPriority.map(\.priority) == expectedPriority.map(\.priority))
        #expect(actual.map(signature).count(where: { $0.first == 0 }) == memberCount * (memberCount - 1) / 2)
        #expect(actual.map(signature).count(where: { $0.first == 2 }) == (memberCount / maximumDepth) * maximumDepth * (maximumDepth - 1) / 2)
        #expect(priority.dependencyTraversalCount == 0)
        #expect(discovery.dependencyTraversalCount == 0)
    }

    @Test("Interleaved bind promotions reuse searches while preserving eager priorities and discovery order")
    func bindReplacementMatchesEager() {
        let sourceCount = 12
        let donorsPerSource = 12
        let graph = ChoiceGraph.build(from: .group((0 ..< sourceCount).map { index in
            .bind(
                fingerprint: UInt64(100 + index),
                inner: pick(.uint64Zip(Array(repeating: 1, count: 6 + index % 3))),
                bound: .group((0 ..< donorsPerSource).map { donorIndex in
                    pick(.uint64Zip(Array(repeating: 1, count: 1 + donorIndex % 3)))
                })
            )
        }))
        var priority = ReplacementQuery.cursor(graph: graph)
        var discovery = ReplacementQuery.discoveryCursor(graph: graph)
        let actual = drain(&discovery)
        let actualPriority = drain(&priority)
        let expectedPriority = EagerScopeReference.replacementCandidates(graph: graph)
        #expect(actual.map(signature) == EagerScopeReference.replacementScopes(graph: graph).map(signature))
        #expect(actualPriority.map(signature) == expectedPriority.map(signature))
        #expect(actualPriority.map(\.priority) == expectedPriority.map(\.priority))
        #expect(actual.map(signature).count(where: { $0.first == 2 }) == sourceCount * donorsPerSource)
        #expect(priority.dependencyTraversalCount == sourceCount)
        #expect(discovery.dependencyTraversalCount == sourceCount)
    }
}

/// Keeps the pre-index parent-chain predicate independent of preorder construction.
private func parentWalk(_ nodeID: Int, ancestor: Int, parents: [Int?]) -> Bool {
    var current = nodeID
    while let parent = parents[current] {
        if parent == ancestor {
            return true
        }
        current = parent
    }
    return false
}

private func pick(_ content: ChoiceTree) -> ChoiceTree {
    .pickSite(fingerprint: 42, selected: 1, branches: [.just, content])
}

/// Keeps family size independent of recursive depth so large pair domains exercise the real graph builder at bounded nesting.
private func nestedPickFamily(memberCount: Int, maximumDepth: Int) -> ChoiceTree {
    precondition(memberCount >= 0 && maximumDepth > 0)
    var chains: [ChoiceTree] = []
    var remaining = memberCount
    while remaining > 0 {
        let depth = min(remaining, maximumDepth)
        var tree = pick(.uint64(1))
        for _ in 1 ..< depth {
            tree = pick(.group([.uint64(1), tree]))
        }
        chains.append(tree)
        remaining -= depth
    }
    return .group(chains)
}

/// Measures pick nesting independently of the fixture's construction loop, ignoring intervening zip and branch wrappers.
private func pickDepth(of nodeID: Int, graph: ChoiceGraph) -> Int {
    var depth = 1
    var current = graph.nodes[nodeID].parent
    while let ancestor = current {
        if case .pick = graph.nodes[ancestor].kind {
            depth += 1
        }
        current = graph.nodes[ancestor].parent
    }
    return depth
}

/// Includes case identity and every payload field so order comparisons cannot hide orientation or size changes.
private func signature(_ scope: ReplacementScope) -> [Int] {
    switch scope {
        case let .selfSimilar(target, donor, sizeDelta):
            [0, target, donor, sizeDelta]
        case let .branchPivot(nodeID, branchID):
            [1, nodeID, Int(branchID)]
        case let .descendantPromotion(ancestor, descendant, sizeDelta):
            [2, ancestor, descendant, sizeDelta]
    }
}

private func signature(_ transformation: GraphTransformation) -> [Int] {
    guard case let .replace(scope) = transformation.operation else {
        Issue.record("Expected a replacement transformation")
        return []
    }
    return signature(scope)
}

/// Verifies each advertised priority before advancing, in addition to comparing the complete stream with the eager reference.
private func drain(_ source: inout ReplacementCandidateSource) -> [GraphTransformation] {
    var results: [GraphTransformation] = []
    while let expectedPriority = source.peekPriority {
        guard let transformation = source.next() else {
            Issue.record("An advertised priority must have a transformation")
            break
        }
        #expect(transformation.priority == expectedPriority)
        results.append(transformation)
    }
    #expect(source.next() == nil)
    return results
}
