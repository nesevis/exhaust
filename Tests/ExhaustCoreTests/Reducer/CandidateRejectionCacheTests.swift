import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("CandidateRejectionCache")
struct CandidateRejectionCacheTests {
    // MARK: - Coarse Cache (Structural Operations)

    @Test("Rejected removal is detected on subsequent query")
    func rejectedRemovalDetected() {
        let fixture = GraphFixture(.uint64Sequence([1, 2, 3], in: 0 ... 10))
        let removalScopes = RemovalQuery.elementRemovalScopes(graph: fixture.graph)
        guard let scope = removalScopes.first else {
            Issue.record("No removal scope")
            return
        }

        let operation = GraphOperation.remove(.elements(scope))
        var cache = CandidateRejectionCache()

        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == false)
        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)
        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == true)
    }

    @Test("Rejected replacement is detected via coarse cache")
    func rejectedReplacementDetected() {
        let tree = ChoiceTree.pickSite(
            fingerprint: 42,
            selected: 1,
            branches: [.just, .uint64(10, in: 0 ... 100)]
        )
        let fixture = GraphFixture(tree)
        let scopes = ReplacementQuery.build(graph: fixture.graph)
        guard let pivotScope = scopes.first(where: {
            if case .branchPivot = $0 { return true }
            return false
        }) else {
            Issue.record("No branch pivot scope")
            return
        }

        let operation = GraphOperation.replace(pivotScope)
        var cache = CandidateRejectionCache()

        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)
        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == true)
    }

    // MARK: - Coarse Cache Is Value-Independent

    @Test("Coarse cache hit persists even when leaf values change")
    func coarseCacheIsValueIndependent() {
        let fixture1 = GraphFixture(.uint64Sequence([10, 20], in: 0 ... 100))
        let fixture2 = GraphFixture(.uint64Sequence([5, 3], in: 0 ... 100))
        let removalScopes = RemovalQuery.elementRemovalScopes(graph: fixture1.graph)
        guard let scope = removalScopes.first else {
            Issue.record("No removal scope")
            return
        }

        let operation = GraphOperation.remove(.elements(scope))
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: operation, sequence: fixture1.sequence, graph: fixture1.graph)

        #expect(
            cache.isRejected(operation: operation, sequence: fixture2.sequence, graph: fixture1.graph) == true,
            "Coarse cache uses node IDs, not values — same operation on same graph should still be rejected"
        )
    }

    // MARK: - clearCoarse

    @Test("clearCoarse removes structural rejections")
    func clearCoarseRemovesStructural() {
        let fixture = GraphFixture(.uint64Sequence([10, 20], in: 0 ... 100))
        let removalScopes = RemovalQuery.elementRemovalScopes(graph: fixture.graph)
        guard let scope = removalScopes.first else {
            Issue.record("No removal scope")
            return
        }

        let operation = GraphOperation.remove(.elements(scope))
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)
        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == true)

        cache.clearCoarse()
        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == false)
    }

    // MARK: - Full Clear

    @Test("clear removes all cached rejections")
    func clearRemovesAll() {
        let fixture = GraphFixture(.uint64Sequence([10, 20], in: 0 ... 100))
        let removalScopes = RemovalQuery.elementRemovalScopes(graph: fixture.graph)
        guard let scope = removalScopes.first else {
            Issue.record("No removal scope")
            return
        }

        let operation = GraphOperation.remove(.elements(scope))
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)
        cache.clear()
        #expect(cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == false)
    }

    // MARK: - Search-Based Operations Are Not Cached

    // MARK: - Fine-Grained (Value-Dependent) Cache

    @Test("Permutation rejection uses the fine-grained value-dependent cache")
    func permutationUsesFinegrainedCache() {
        let fixture = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100))
        let scopes = PermutationQuery.build(graph: fixture.graph)
        guard let scope = scopes.first else {
            Issue.record("No permutation scope")
            return
        }

        let operation = GraphOperation.permute(scope)
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)

        #expect(
            cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == true,
            "Permutation should be cached in the fine-grained cache"
        )

        let fixture2 = GraphFixture(.uint64Zip([99, 88], in: 0 ... 100))
        #expect(
            cache.isRejected(operation: operation, sequence: fixture2.sequence, graph: fixture.graph) == false,
            "Fine-grained cache is value-dependent — different values should not hit"
        )

        cache.clearCoarse()
        #expect(
            cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == true,
            "clearCoarse should not affect fine-grained cache"
        )
    }

    // MARK: - Search-Based Operations Are Not Cached

    @Test("Minimize operations are never cached because their outcomes are nondeterministic")
    func minimizeNotCached() {
        let fixture = GraphFixture(.uint64(42, in: 0 ... 100))
        let scopes = MinimizationQuery.build(graph: fixture.graph)
        guard let scope = scopes.first else {
            Issue.record("No minimization scope")
            return
        }

        let operation = GraphOperation.minimize(scope)
        var cache = CandidateRejectionCache()
        cache.recordRejection(operation: operation, sequence: fixture.sequence, graph: fixture.graph)

        #expect(
            cache.isRejected(operation: operation, sequence: fixture.sequence, graph: fixture.graph) == false,
            "Search-based operations should never register in the cache"
        )
    }
}
