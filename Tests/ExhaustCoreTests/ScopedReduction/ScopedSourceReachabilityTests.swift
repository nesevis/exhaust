import Testing
@testable import ExhaustCore

@Suite("Scoped source dependency caching")
struct ScopedSourceReachabilityTests {
    // MARK: - Migration

    @Test("Scoped migration shares positive searches across receivers")
    func migrationPositiveResultsAreReused() {
        let controllerCount = 8
        let graph = bindGraph(controllerCount: controllerCount, boundElementCount: 12)
        var source = ScopedMigrationSource(graph: graph)
        let scopes = drain(&source)
        #expect(scopes.count > 1000)
        #expect(source.dependencyTraversalCount == controllerCount)
        #expect(source.dependencyCachedSourceCount == controllerCount)
        #expect(source.dependencyCachedNodeCount == controllerCount)
    }

    @Test("Scoped migration shares negative results for dependencies ending outside the sequence domain")
    func migrationNegativeResultsAreReused() {
        let controllerCount = 8
        let graph = bindGraph(controllerCount: controllerCount, boundElementCount: 0)
        var source = ScopedMigrationSource(graph: graph)
        let scopes = drain(&source)
        #expect(scopes.isEmpty == false)
        #expect(source.dependencyTraversalCount == controllerCount)
        #expect(source.dependencyCachedSourceCount == 0)
        #expect(source.dependencyCachedNodeCount == 0)
    }

    @Test("Scoped migration over independent sequences runs no dependency search")
    func migrationIndependentSequencesNeedNoSearch() {
        let graph = ChoiceGraph.build(from: .group((0 ..< 40).map { _ in .uint64Sequence([1]) }))
        var source = ScopedMigrationSource(graph: graph)
        let scopes = drain(&source)
        #expect(scopes.count == 40 * 39 / 2)
        #expect(source.dependencyTraversalCount == 0)
        #expect(source.dependencyCachedSourceCount == 0)
        #expect(source.dependencyCachedNodeCount == 0)
    }

    // MARK: - Replacement

    @Test("Scoped replacement over a family without binds runs no dependency search", arguments: [
        ScopedReplacementSource.EnumerationOrder.priority,
        .discovery,
    ])
    func replacementWithoutBindsNeedsNoSearch(order: ScopedReplacementSource.EnumerationOrder) {
        let graph = ChoiceGraph.build(from: nestedPickFamily(memberCount: 120, maximumDepth: 8))
        var source = ScopedReplacementSource(graph: graph, order: order)
        let scopes = drain(&source)
        #expect(scopes.isEmpty == false)
        #expect(source.dependencyTraversalCount == 0)
    }

    @Test("Scoped replacement searches each bind's dependencies once across its promotions", arguments: [
        ScopedReplacementSource.EnumerationOrder.priority,
        .discovery,
    ])
    func replacementBindSearchesAreReused(order: ScopedReplacementSource.EnumerationOrder) {
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
        var source = ScopedReplacementSource(graph: graph, order: order)
        let scopes = drain(&source)
        let promotionCount = scopes.count(where: { priced in
            guard case .substitution(.descendantPromotion) = priced.encoderScope else {
                return false
            }
            return true
        })
        #expect(promotionCount == sourceCount * donorsPerSource)
        #expect(source.dependencyTraversalCount == sourceCount)
    }
}

// MARK: - Helpers

/// Drains `source`, checking that peeking its priority never runs a dependency search.
private func drain(_ source: inout ScopedMigrationSource) -> [PricedEncoderScope] {
    var scopes: [PricedEncoderScope] = []
    while let priority = source.dispatchPriority {
        let searches = source.dependencyTraversalCount
        #expect(source.dispatchPriority == priority)
        #expect(source.dependencyTraversalCount == searches)
        guard let scope = source.nextScope() else {
            Issue.record("An advertised migration priority must have a scope")
            break
        }
        scopes.append(scope)
    }
    #expect(source.nextScope() == nil)
    return scopes
}

/// Drains `source`, checking that peeking its priority never runs a dependency search.
private func drain(_ source: inout ScopedReplacementSource) -> [PricedEncoderScope] {
    var scopes: [PricedEncoderScope] = []
    while let priority = source.dispatchPriority {
        let searches = source.dependencyTraversalCount
        #expect(source.dispatchPriority == priority)
        #expect(source.dependencyTraversalCount == searches)
        guard let scope = source.nextScope() else {
            Issue.record("An advertised replacement priority must have a scope")
            break
        }
        scopes.append(scope)
    }
    #expect(source.nextScope() == nil)
    return scopes
}

/// Bind controllers whose bound content is a sequence (positive reachability results) or a scalar (negative results), followed by unrelated receivers.
private func bindGraph(controllerCount: Int, boundElementCount: Int) -> ChoiceGraph {
    let tree = ChoiceTree.group((0 ..< controllerCount).map { index in
        let bound: ChoiceTree = boundElementCount == 0
            ? .uint64(1)
            : .uint64Sequence(Array(repeating: 1, count: boundElementCount))
        return .bind(fingerprint: UInt64(100 + index), inner: .uint64Sequence([1, 2]), bound: bound)
    } + Array(repeating: .uint64Sequence([1]), count: 64) + [.uint64Sequence([])])
    return ChoiceGraph.build(from: tree)
}

private func pick(_ content: ChoiceTree) -> ChoiceTree {
    .pickSite(fingerprint: 42, selected: 1, branches: [.just, content])
}

/// Chains of nested picks from one family, so a large pair domain stays at bounded depth.
private func nestedPickFamily(memberCount: Int, maximumDepth: Int) -> ChoiceTree {
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
