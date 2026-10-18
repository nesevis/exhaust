import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Replacement queries")
struct StructuralReplacementTests {
    // MARK: - Branch Pivot

    @Test("Branch pivot leaf-count gate filters alternatives with more leaves")
    func branchPivotLeafCountGate() {
        let tree = ChoiceTree.pickSite(
            fingerprint: 50,
            selected: 0,
            branches: [
                .uint64(1, in: 0 ... 100),
                .uint64Zip([2, 3, 4], in: 0 ... 100),
            ]
        )
        let fixture = GraphFixture(tree)
        let scopes = replacementScopes(graph: fixture.graph)

        let pivotScopes = scopes.filter {
            if case .branchPivot = $0 { return true }
            return false
        }
        #expect(pivotScopes.isEmpty, "Branch with more leaves should be filtered by leaf-count gate")
    }

    // MARK: - ReplacementQuery

    @Test("ReplacementQuery produces no self-similar scopes for single-element groups")
    func noSelfSimilarForSingleton() {
        let tree = ChoiceTree.pickSite(
            fingerprint: 100,
            selected: 1,
            branches: [
                .uint64(1, in: 0 ... 10),
                .uint64(2, in: 0 ... 10),
            ]
        )
        let fixture = GraphFixture(tree)
        let scopes = replacementScopes(graph: fixture.graph)

        let selfSimilarScopes = scopes.filter {
            if case .selfSimilar = $0 { return true }
            return false
        }
        #expect(selfSimilarScopes.isEmpty, "Single pick site cannot self-similar substitute with itself")
    }

    @Test("ReplacementQuery incremental build skips unchanged fingerprints")
    func incrementalSkipsUnchanged() {
        let fixture = GraphFixture(selfSimilarTree(
            targetLeafValues: [10, 20],
            donorLeafValues: [5]
        ))

        let fullScopes = replacementScopes(graph: fixture.graph)
        let incrementalScopes = replacementScopes(graph: fixture.graph, previousGraph: fixture.graph)

        let fullSelfSimilar = fullScopes.filter {
            if case .selfSimilar = $0 { return true }
            return false
        }
        let incrementalSelfSimilar = incrementalScopes.filter {
            if case .selfSimilar = $0 { return true }
            return false
        }

        #expect(fullSelfSimilar.count > incrementalSelfSimilar.count)
    }

    @Test("ReplacementQuery generates descendant promotion scopes for nested same-fingerprint picks")
    func descendantPromotionScopes() {
        let fixture = GraphFixture(nestedPickTree())
        let scopes = replacementScopes(graph: fixture.graph)

        let promotionScopes = scopes.filter {
            if case .descendantPromotion = $0 { return true }
            return false
        }
        #expect(promotionScopes.isEmpty == false, "Nested same-fingerprint picks should produce descendant promotion scopes")
    }

    @Test("ReplacementQuery orders self-similar pairs with larger target first")
    func selfSimilarLargerTargetFirst() {
        let fixture = GraphFixture(selfSimilarTree(
            targetLeafValues: [10, 20, 30],
            donorLeafValues: [5]
        ))
        let scopes = replacementScopes(graph: fixture.graph)

        for scope in scopes {
            if case let .selfSimilar(targetNodeID: target, donorNodeID: donor, sizeDelta: delta) = scope {
                if delta > 0 {
                    let targetSize = fixture.graph.nodes[target].positionRange?.count ?? 0
                    let donorSize = fixture.graph.nodes[donor].positionRange?.count ?? 0
                    #expect(targetSize >= donorSize, "Target should be at least as large as donor for positive sizeDelta")
                }
            }
        }
    }
}

// MARK: - Helpers

private func selfSimilarTree(
    targetLeafValues: [UInt64],
    donorLeafValues: [UInt64]
) -> ChoiceTree {
    let fingerprint: UInt64 = 999

    func makePickSite(leafValues: [UInt64]) -> ChoiceTree {
        .pickSite(
            fingerprint: fingerprint,
            selected: 1,
            branches: [
                .just,
                .group(leafValues.map { .uint64($0, in: 0 ... 100) }),
            ]
        )
    }

    return ChoiceTree.group([
        makePickSite(leafValues: targetLeafValues),
        makePickSite(leafValues: donorLeafValues),
    ])
}

private func nestedPickTree() -> ChoiceTree {
    let fingerprint: UInt64 = 777

    let innerPick = ChoiceTree.pickSite(
        fingerprint: fingerprint,
        selected: 1,
        branches: [.just, .uint64(5, in: 0 ... 100)]
    )

    return ChoiceTree.pickSite(
        fingerprint: fingerprint,
        selected: 1,
        branches: [
            .just,
            .group([.uint64(10, in: 0 ... 100), innerPick]),
        ]
    )
}
