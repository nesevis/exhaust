import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("GraphStructuralEncoder Replacement")
struct StructuralReplacementTests {
    // MARK: - Self-Similar Substitution

    @Test("Self-similar replacement with much smaller donor produces shorter candidate")
    func selfSimilarSmallerDonor() {
        let fixture = GraphFixture(selfSimilarTree(
            targetLeafValues: [10, 20, 30, 40, 50, 60, 70, 80],
            donorLeafValues: [1]
        ))
        let scopes = ReplacementQuery.build(graph: fixture.graph)

        let selfSimilarScopes = scopes.filter {
            if case .selfSimilar = $0 { return true }
            return false
        }
        guard selfSimilarScopes.isEmpty == false else {
            Issue.record("Expected at least one self-similar scope")
            return
        }

        var encoder = GraphStructuralEncoder()
        var emittedCount = 0
        for scope in selfSimilarScopes {
            let input = replacementInput(scope: scope, fixture: fixture)
            encoder.start(scope: input)
            var buffer = fixture.sequence
            if encoder.nextProbe(into: &buffer, lastAccepted: false) != nil {
                #expect(buffer.count < fixture.sequence.count)
                emittedCount += 1
            }
        }
        #expect(emittedCount > 0, "At least one self-similar scope should produce a candidate")
    }

    @Test("Self-similar replacement is single-shot")
    func selfSimilarSingleShot() {
        let fixture = GraphFixture(selfSimilarTree(
            targetLeafValues: [10, 20, 30, 40, 50, 60],
            donorLeafValues: [1]
        ))
        let scopes = ReplacementQuery.build(graph: fixture.graph)

        guard let selfSimilarScope = scopes.first(where: {
            if case .selfSimilar = $0 { return true }
            return false
        }) else {
            Issue.record("No self-similar scope found")
            return
        }

        let input = replacementInput(scope: selfSimilarScope, fixture: fixture)
        var encoder = GraphStructuralEncoder()
        encoder.start(scope: input)
        var buffer = fixture.sequence
        _ = encoder.nextProbe(into: &buffer, lastAccepted: false)
        let secondProbe = encoder.nextProbe(into: &buffer, lastAccepted: false)
        #expect(secondProbe == nil)
    }

    // MARK: - Branch Pivot

    @Test("Branch pivot to simpler alternative produces candidate")
    func branchPivotToSimplerAlternative() {
        let tree = ChoiceTree.pickSite(
            fingerprint: 42,
            selected: 1,
            branches: [
                .just,
                .uint64Zip([99, 88], in: 0 ... 100),
            ]
        )
        let fixture = GraphFixture(tree)
        let scopes = ReplacementQuery.build(graph: fixture.graph)

        let pivotScopes = scopes.filter {
            if case .branchPivot = $0 { return true }
            return false
        }
        guard pivotScopes.isEmpty == false else {
            Issue.record("Expected at least one branch pivot scope")
            return
        }

        var encoder = GraphStructuralEncoder()
        var emittedCount = 0
        for scope in pivotScopes {
            let input = replacementInput(scope: scope, fixture: fixture)
            encoder.start(scope: input)
            var buffer = fixture.sequence
            if encoder.nextProbe(into: &buffer, lastAccepted: false) != nil {
                #expect(buffer.count <= fixture.sequence.count)
                let branchFingerprints = buffer.compactMap { entry -> UInt64? in
                    guard case let .branch(branch) = entry else { return nil }
                    return branch.fingerprint
                }
                #expect(branchFingerprints == [42])
                emittedCount += 1
            }
        }
        #expect(emittedCount > 0, "At least one branch pivot should produce a candidate")
    }

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
        let scopes = ReplacementQuery.build(graph: fixture.graph)

        let pivotScopes = scopes.filter {
            if case .branchPivot = $0 { return true }
            return false
        }
        #expect(pivotScopes.isEmpty, "Branch with more leaves should be filtered by leaf-count gate")
    }

    // MARK: - Shortlex Rejection Flag

    @Test("Self-similar replacement with same-size larger-valued donor sets shortlex rejection flag")
    func shortlexRejectionFlag() {
        let fixture = GraphFixture(selfSimilarTree(
            targetLeafValues: [1, 2],
            donorLeafValues: [99, 88]
        ))
        let scopes = ReplacementQuery.build(graph: fixture.graph)

        let sameSizeScopes = scopes.filter {
            if case let .selfSimilar(targetNodeID: target, donorNodeID: donor, sizeDelta: _) = $0 {
                return fixture.graph.nodes[target].positionRange?.count == fixture.graph.nodes[donor].positionRange?.count
            }
            return false
        }
        guard sameSizeScopes.isEmpty == false else {
            Issue.record("Expected at least one same-size self-similar scope")
            return
        }

        var encoder = GraphStructuralEncoder()
        for scope in sameSizeScopes {
            let input = replacementInput(scope: scope, fixture: fixture)
            encoder.start(scope: input)
            var buffer = fixture.sequence
            _ = encoder.nextProbe(into: &buffer, lastAccepted: false)
        }

        #expect(encoder.hadReplacementShortlexRejection == true)
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
        let scopes = ReplacementQuery.build(graph: fixture.graph)

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

        let fullScopes = ReplacementQuery.build(graph: fixture.graph)
        let incrementalScopes = ReplacementQuery.build(graph: fixture.graph, previousGraph: fixture.graph)

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
        let scopes = ReplacementQuery.build(graph: fixture.graph)

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
        let scopes = ReplacementQuery.build(graph: fixture.graph)

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

private func replacementInput(
    scope: ReplacementScope,
    fixture: GraphFixture
) -> EncoderInput {
    let transformation = GraphTransformation(
        operation: .replace(scope),
        priority: DispatchPriority(
            structuralBenefit: 1,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    )
    return EncoderInput(
        transformation: transformation,
        baseSequence: fixture.sequence,
        tree: fixture.tree,
        graph: fixture.graph,
        warmStartRecords: [:]
    )
}
