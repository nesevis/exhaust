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
