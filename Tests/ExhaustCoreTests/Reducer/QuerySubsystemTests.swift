import ExhaustTestSupport
import Testing
@testable import ExhaustCore

// MARK: - MinimizationQuery Tests

@Suite("MinimizationQuery")
struct MinimizationQueryTests {
    @Test("Produces integer scope for non-zero integer leaves")
    func integerScopeForNonZeroLeaves() {
        let graph = GraphFixture(.uint64Zip([42, 0], in: 0 ... 100)).graph
        let scopes = MinimizationQuery.build(graph: graph)

        let valueLeafScopes = scopes.compactMap { scope -> ValueMinimizationScope? in
            if case let .valueLeaves(innerScope) = scope { return innerScope }
            return nil
        }
        #expect(valueLeafScopes.count == 1)
        #expect(valueLeafScopes[0].leaves.count == 1, "Only the non-zero leaf should be included")
    }

    @Test("Excludes leaves already at target")
    func excludesLeavesAtTarget() {
        let graph = GraphFixture(.uint64(0, in: 0 ... 100)).graph
        let scopes = MinimizationQuery.build(graph: graph)

        let valueLeafScopes = scopes.compactMap { scope -> ValueMinimizationScope? in
            if case let .valueLeaves(innerScope) = scope { return innerScope }
            return nil
        }
        #expect(valueLeafScopes.isEmpty, "Leaf at target should not produce a scope")
    }

    @Test("Produces float scope for float leaves")
    func floatScopeForFloatLeaves() {
        let graph = GraphFixture(.double(3.14)).graph
        let scopes = MinimizationQuery.build(graph: graph)

        let floatScopes = scopes.compactMap { scope -> FloatMinimizationScope? in
            if case let .floatLeaves(innerScope) = scope { return innerScope }
            return nil
        }
        #expect(floatScopes.count == 1)
    }

    @Test("deferBindInner excludes bind-inner leaves")
    func deferBindInnerExclusion() {
        let tree = ChoiceTree.bind(
            fingerprint: 0,
            inner: .uint64(10, in: 0 ... 100),
            bound: .uint64(20, in: 0 ... 100)
        )
        let graph = GraphFixture(tree).graph

        let withDefer = MinimizationQuery.build(graph: graph, deferBindInner: true)
        let withoutDefer = MinimizationQuery.build(graph: graph, deferBindInner: false)

        let deferredLeafCount = withDefer.compactMap { scope -> Int? in
            if case let .valueLeaves(innerScope) = scope { return innerScope.leaves.count }
            return nil
        }.reduce(0, +)
        let fullLeafCount = withoutDefer.compactMap { scope -> Int? in
            if case let .valueLeaves(innerScope) = scope { return innerScope.leaves.count }
            return nil
        }.reduce(0, +)

        #expect(deferredLeafCount < fullLeafCount)
    }

    @Test("batchZeroEligible is true when multiple leaves exist")
    func batchZeroEligibleForMultipleLeaves() {
        let graph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let scopes = MinimizationQuery.build(graph: graph)

        let valueLeafScopes = scopes.compactMap { scope -> ValueMinimizationScope? in
            if case let .valueLeaves(innerScope) = scope { return innerScope }
            return nil
        }
        guard let scope = valueLeafScopes.first else {
            Issue.record("Expected at least one value scope")
            return
        }
        #expect(scope.batchZeroEligible == true)
    }
}

// MARK: - ExchangeQuery Tests

@Suite("ExchangeQuery")
struct ExchangeQueryTests {
    @Test("Produces redistribution scope for same-type leaves in a sequence")
    func redistributionForSequenceElements() {
        let graph = GraphFixture(.uint64Sequence([10, 20, 30], in: 0 ... 100)).graph
        let scopes = ExchangeQuery.build(graph: graph)

        let redistScopes = scopes.filter {
            if case .redistribution = $0 { return true }
            return false
        }
        #expect(redistScopes.count >= 1, "Three same-type sequence elements should produce at least one redistribution pair")
    }

    @Test("Produces tandem scope for same-type leaves")
    func tandemForSameTypeLeaves() {
        let graph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let scopes = ExchangeQuery.build(graph: graph)

        let tandemScopes = scopes.filter {
            if case .tandem = $0 { return true }
            return false
        }
        #expect(tandemScopes.count == 1, "A pair of same-type leaves should produce exactly one tandem scope")
    }

    @Test("No scopes for single leaf")
    func noScopesForSingleLeaf() {
        let graph = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let scopes = ExchangeQuery.build(graph: graph)

        #expect(scopes.isEmpty, "Single leaf cannot form tandem or redistribution pair")
    }

    @Test("No redistribution pairs when all leaves are at target")
    func noRedistributionAtTarget() {
        let graph = GraphFixture(.uint64Sequence([0, 0], in: 0 ... 100)).graph
        let scopes = ExchangeQuery.build(graph: graph)

        let redistScopes = scopes.filter {
            if case .redistribution = $0 { return true }
            return false
        }
        #expect(redistScopes.isEmpty, "Leaves at target should not produce redistribution pairs")
    }
}

// MARK: - PermutationQuery Tests

@Suite("PermutationQuery")
struct PermutationQueryTests {
    @Test("Produces scope for zip with same-shaped siblings")
    func scopeForZipWithSameShapedSiblings() {
        let graph = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).graph
        let scopes = PermutationQuery.build(graph: graph)

        #expect(scopes.count == 1, "Zip with two same-type chooseBits children should produce one permutation scope")
        if let scope = scopes.first {
            #expect(scope.swappableGroups.count == 1)
            #expect(scope.swappableGroups[0].count == 2)
        }
    }

    @Test("No scope for zip with differently-shaped siblings")
    func noScopeForDifferentShapes() {
        let tree = ChoiceTree.group([
            .uint64(10, in: 0 ... 100),
            .uint64Sequence([5], in: 0 ... 100),
        ])
        let graph = GraphFixture(tree).graph
        let scopes = PermutationQuery.build(graph: graph)

        #expect(scopes.isEmpty, "Different-shaped siblings should not produce permutation scopes")
    }

    @Test("No scope for single child zip")
    func noScopeForSingleChild() {
        let graph = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let scopes = PermutationQuery.build(graph: graph)

        #expect(scopes.isEmpty, "Single child cannot be permuted")
    }
}

// MARK: - ReorderingQuery Tests

@Suite("ReorderingQuery")
struct ReorderingQueryTests {
    @Test("Produces scope for sequence with multiple same-kind elements")
    func scopeForSequenceElements() {
        let graph = GraphFixture(.uint64Sequence([30, 10, 20], in: 0 ... 100)).graph
        let scope = ReorderingQuery.build(graph: graph)

        #expect(scope != nil, "Sequence with same-type elements should produce reordering scope")
        if let scope {
            #expect(scope.groups.isEmpty == false)
            #expect(scope.groups[0].ranges.count == 3)
        }
    }

    @Test("Groups sorted deepest-first rightmost-first")
    func groupsSortedDeepestFirst() {
        let tree = ChoiceTree.sequence(
            elements: [
                .uint64Sequence([5, 3], in: 0 ... 100),
                .uint64Sequence([7, 1], in: 0 ... 100),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = GraphFixture(tree).graph
        let scope = ReorderingQuery.build(graph: graph)

        guard let scope else {
            Issue.record("Expected reordering scope for nested sequences")
            return
        }
        guard scope.groups.count >= 2 else {
            Issue.record("Expected at least 2 groups for depth ordering test")
            return
        }
        #expect(scope.groups[0].depth >= scope.groups[1].depth, "Deeper groups should come first")
    }

    @Test("No scope for sequence with single element")
    func noScopeForSingleElement() {
        let graph = GraphFixture(.uint64Sequence([10], in: 0 ... 100)).graph
        let scope = ReorderingQuery.build(graph: graph)

        #expect(scope == nil, "Single-element sequence cannot be reordered")
    }

    @Test("Elements with different type tags are not grouped together")
    func differentTagsNotGrouped() {
        let tree = ChoiceTree.group([
            .uint64(10, in: 0 ... 100),
            .int64(20),
        ])
        let graph = GraphFixture(tree).graph
        let scope = ReorderingQuery.build(graph: graph)

        #expect(scope == nil, "Different-type leaves should not form reorderable groups")
    }
}

// MARK: - LaneCollapseQuery Tests

@Suite("LaneCollapseQuery")
struct LaneCollapseQueryTests {
    @Test("No scope when no lane-control leaves exist")
    func noScopeWithoutLaneControl() {
        let graph = GraphFixture(.uint64(10, in: 0 ... 100)).graph
        let scope = LaneCollapseQuery.build(graph: graph)

        #expect(scope == nil, "No lane-control leaves means no lane collapse scope")
    }
}
