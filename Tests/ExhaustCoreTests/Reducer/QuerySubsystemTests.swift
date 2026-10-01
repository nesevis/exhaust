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

    @Test("Equal values receive a tandem group that excludes different values of the same type")
    func tandemGroupForEqualValues() throws {
        let graph = GraphFixture(.uint64Zip([12, 12, 0], in: 0 ... 100)).graph
        let scopes = ExchangeQuery.build(graph: graph)

        let tandemScope = try #require(scopes.tandemScope)
        #expect(tandemScope.groups.count == 2)
        #expect(tandemScope.groups[0].leaves.count == 3)

        let matchingLeaves = tandemScope.groups[1].leaves
        #expect(matchingLeaves.count == 2)
        #expect(matchingLeaves.allSatisfy { leaf in
            guard case let .chooseBits(metadata) = graph.nodes[leaf.nodeID].kind else {
                return false
            }
            return metadata.value.bitPattern64 == 12
        })
    }

    @Test("Tandem groups are ordered by first-leaf position, not by type-tag hash order")
    func tandemGroupsOrderedByPosition() throws {
        // Six groups, so an unsorted build has a 1-in-720 chance of landing in position order by luck.
        let tags: [TypeTag] = [.uint64, .uint32, .int64, .int32, .uint16, .int16]
        let tree = ChoiceTree.group(
            (tags + tags).enumerated().map { offset, tag in
                leaf(UInt64(30000 + offset * 1000), tag: tag)
            }
        )
        let graph = ChoiceGraph.build(from: tree)
        let groups = try #require(ExchangeQuery.build(graph: graph).tandemScope).groups
        #expect(groups.count == tags.count, "Each type tag with two leaves should form one group")

        let firstPositions = groups.map { graph.nodes[$0.leaves[0].nodeID].positionRange?.lowerBound ?? -1 }
        #expect(firstPositions == firstPositions.sorted())
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

    @Test("Redistribution pairs leaves controlling the same bind and never pairs across sibling binds")
    func redistributionPairsStayWithinOneBind() {
        // Bind A has two controllers, like a bind over a zipped price and quantity. Bind B has one.
        let tree = ChoiceTree.group([
            .bind(
                fingerprint: 1,
                inner: .uint64Zip([30, 40], in: 0 ... 100),
                bound: .uint64(5, in: 0 ... 100)
            ),
            .bind(
                fingerprint: 2,
                inner: .uint64(50, in: 0 ... 100),
                bound: .uint64(6, in: 0 ... 100)
            ),
        ])
        let graph = GraphFixture(tree).graph

        let pairs = ExchangeQuery.build(graph: graph).flatMap { scope -> [RedistributionPair] in
            if case let .redistribution(redistributionScope) = scope { return redistributionScope.pairs }
            return []
        }
        let controllingBinds = pairs.map { pair in
            (
                source: graph.nodes[pair.source.nodeID].scopeAnnotation.controllingBindNodeID,
                sink: graph.nodes[pair.sink.nodeID].scopeAnnotation.controllingBindNodeID
            )
        }

        #expect(controllingBinds.allSatisfy { $0.source == $0.sink }, "A pair must not move value between leaves of sibling binds")
        #expect(controllingBinds.contains { $0.source != nil }, "The two controllers of bind A should form a pair")
    }

    @Test("Redistribution pairs same-type sequences across the slots of one bind's inner zip")
    func redistributionPairsSequenceSlotsWithinOneBind() {
        let tree = ChoiceTree.bind(
            fingerprint: 1,
            inner: .group([
                .uint64Sequence([30, 40], in: 0 ... 100),
                .uint64Sequence([50, 60], in: 0 ... 100),
            ]),
            bound: .uint64(5, in: 0 ... 100)
        )
        let graph = GraphFixture(tree).graph

        let pairs = ExchangeQuery.build(graph: graph).flatMap { scope -> [RedistributionPair] in
            if case let .redistribution(redistributionScope) = scope { return redistributionScope.pairs }
            return []
        }
        let crossSlotPairs = pairs.filter { pair in
            graph.nodes[pair.source.nodeID].parent != graph.nodes[pair.sink.nodeID].parent
        }

        #expect(crossSlotPairs.isEmpty == false, "Same-type sequences in the slots of one bind's inner zip should exchange value")
        #expect(crossSlotPairs.allSatisfy { $0.source.mayReshapeOnAcceptance && $0.sink.mayReshapeOnAcceptance })
    }

    @Test("Bound exchange moves value down a chain of distinct binds and not down a recursive expansion", arguments: [
        (innerFingerprint: UInt64(2), exchangesAcrossBinds: true),
        (innerFingerprint: UInt64(1), exchangesAcrossBinds: false),
    ])
    func boundExchangeFollowsComposableBindChains(innerFingerprint: UInt64, exchangesAcrossBinds: Bool) {
        // The outer bind's controller draws the inner bind, like the first two factors of a nested flatmap. A repeated fingerprint marks a recursive expansion instead.
        let tree = ChoiceTree.bind(
            fingerprint: 1,
            inner: .uint64(30, in: 0 ... 100),
            bound: .bind(
                fingerprint: innerFingerprint,
                inner: .uint64(20, in: 0 ... 100),
                bound: .uint64(5, in: 0 ... 100)
            )
        )
        let graph = GraphFixture(tree).graph

        let scopes = ExchangeQuery.build(graph: graph)
        let exchanges = scopes.compactMap { scope -> BoundExchangeScope? in
            if case let .boundExchange(exchange) = scope { return exchange }
            return nil
        }
        let crossBindRedistributions = scopes.flatMap { scope -> [RedistributionPair] in
            if case let .redistribution(redistributionScope) = scope { return redistributionScope.pairs }
            return []
        }.filter { pair in
            let source = graph.nodes[pair.source.nodeID].scopeAnnotation.controllingBindNodeID
            let sink = graph.nodes[pair.sink.nodeID].scopeAnnotation.controllingBindNodeID
            return source != nil && sink != nil && source != sink
        }
        let outerBindInner = leafNodeID(holding: 30, in: graph)
        let innerBindInner = leafNodeID(holding: 20, in: graph)
        let terminalLeaf = leafNodeID(holding: 5, in: graph)

        #expect(crossBindRedistributions.isEmpty, "Redistribution assumes independent ranges, so it must not pair a bind inner with a bind inner its bind determines")
        // The inner bind trades with its own bound leaf either way; only the outer bind inner's exchanges cross binds.
        let exchangesFromOuter = exchanges.filter { $0.sourceLeafNodeID == outerBindInner }
        #expect(exchangesFromOuter.isEmpty == (exchangesAcrossBinds == false))
        if exchangesAcrossBinds {
            #expect(exchangesFromOuter.contains {
                guard case .bindInner = $0.sinkLocation else {
                    return false
                }
                return $0.sinkLeafNodeID == innerBindInner
            })
            #expect(exchangesFromOuter.contains {
                guard case .boundLeaf = $0.sinkLocation else {
                    return false
                }
                return $0.sinkLeafNodeID == terminalLeaf
            })
        }
        #expect(exchanges.contains { $0.sourceLeafNodeID == innerBindInner && $0.sinkLeafNodeID == terminalLeaf })
    }

    @Test("Bound exchange dispatches only once its source is stalled")
    func boundExchangeRequiresStalledSource() throws {
        let tree = ChoiceTree.bind(
            fingerprint: 1,
            inner: .uint64(30, in: 0 ... 100),
            bound: .uint64(5, in: 0 ... 100)
        )
        var graph = GraphFixture(tree).graph
        let bindInner = try #require(leafNodeID(holding: 30, in: graph))
        var gate = BoundValueGate(baseBudget: 15)

        #expect(ChoiceGraphScheduler.isStalledBindInner(bindInnerLeafNodeID: bindInner, graph: graph, gate: gate) == false, "A bind inner nothing has tried to lower is not ready to trade magnitude")

        gate.markFruitless(1)
        #expect(ChoiceGraphScheduler.isStalledBindInner(bindInnerLeafNodeID: bindInner, graph: graph, gate: gate), "A fruitless bound value search marks the bind inner as stalled")

        markStallConverged(&graph)
        #expect(ChoiceGraphScheduler.isStalledBindInner(bindInnerLeafNodeID: bindInner, graph: graph, gate: BoundValueGate(baseBudget: 15)), "A convergence record at the current value marks the bind inner as stalled")
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

// MARK: - Helpers

/// A `chooseBits` leaf carrying the given value under the given tag.
private func leaf(_ value: UInt64, tag: TypeTag) -> ChoiceTree {
    .choice(
        ChoiceValue(value, tag: tag),
        .init(validRange: 0 ... 1_000_000, isRangeExplicit: true)
    )
}

/// Records every value leaf as converged at its current value, the state value search leaves when no single-leaf reduction exists.
private func markStallConverged(_ graph: inout ChoiceGraph) {
    for nodeID in graph.leafNodes {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            continue
        }
        graph.convergenceStore[nodeID] = ConvergedOrigin(
            bound: metadata.value.bitPattern64,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }
}

/// The value leaf whose current value is `value`. Fixtures give each leaf a distinct value.
private func leafNodeID(holding value: UInt64, in graph: ChoiceGraph) -> Int? {
    graph.leafNodes.first { nodeID in
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { return false }
        return metadata.value.bitPattern64 == value
    }
}
