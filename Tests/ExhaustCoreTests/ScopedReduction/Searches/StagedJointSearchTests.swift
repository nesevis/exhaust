import Testing
@testable import ExhaustCore

@Suite("Staged joint numeric search")
struct StagedJointSearchTests {
    @Test("A long character sequence cannot consume the numeric leaf or frontier caps")
    func separateFrontierCaps() throws {
        let character = try #require(try Interpreters.reflect(Gen.character(in: "a" ... "z").gen, with: "z"))
        let count = ScopedReductionTuning().numericPairMaximumLeaves + 44
        let text = ChoiceTree.sequence(elements: Array(repeating: character, count: count), metadata: .init(validRange: UInt64(count) ... UInt64(count), isRangeExplicit: true))
        let numbers = ChoiceTree.group([6, 8, 10].map { .choice(ChoiceValue(UInt64($0), tag: .uint64), .init(validRange: 1 ... 1000, isRangeExplicit: true)) })
        var graph = ChoiceGraph.build(from: .group([text, numbers]))
        markConverged(&graph)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(ScopedStagedJointQuery.eligibleLeaves(graph: graph, tuning: .init()).count == 3)
        #expect(ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).count == 3)
    }

    @Test("Pair-only float scopes skip the joint frontier without suppressing pair search", arguments: [TypeTag.float16, .float, .double], [1, 2])
    func pairOnlyFloatingFrontier(tag: TypeTag, count: Int) {
        let range = tag.floatingBitPattern(from: -16) ... tag.floatingBitPattern(from: 16)
        let values: [ChoiceTree] = (0 ..< count).map { _ in
            .choice(ChoiceValue(tag.floatingBitPattern(from: 8), tag: tag), .init(validRange: range, isRangeExplicit: true))
        }
        // Fixed domains, booleans, and nonfinite floats cannot supply a third coordinate.
        let excluded: [ChoiceTree] = [
            .choice(ChoiceValue(UInt64(8), tag: .uint64), .init(validRange: 8 ... 8, isRangeExplicit: true)),
            .choice(ChoiceValue(UInt8(1), tag: .uint8), .init(validRange: 0 ... 1, isRangeExplicit: true)),
            .choice(ChoiceValue(tag.floatingBitPattern(from: .infinity), tag: tag), .init(validRange: tag.bitPatternRange, isRangeExplicit: true)),
        ]
        var graph = ChoiceGraph.build(from: .group(values + excluded))
        markConverged(&graph)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(ScopedStagedJointQuery.eligibleLeaves(graph: graph, tuning: .init()).count == count + 1)
        #expect(ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
        if count == 2 {
            #expect(ScopedStagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).contains {
                $0.source.choice.tag == tag && $0.sink.choice.tag == tag
            })
        }
    }

    @Test("Floating palettes use semantic halves and admit only finite domain values", arguments: [TypeTag.float16, .float, .double])
    func floatingFrontier(tag: TypeTag) {
        let range = tag.floatingBitPattern(from: -16) ... tag.floatingBitPattern(from: 16)
        let tree = ChoiceTree.group([8.0, -8.0, 0.0].map { value in
            .choice(ChoiceValue(tag.floatingBitPattern(from: value), tag: tag), .init(validRange: range, isRangeExplicit: true))
        })
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        #expect(frontier.count == 3)
        for entry in frontier {
            let current = entry.leaf.choice.decodedDoubleValue
            if current != 0 {
                let values = entry.simplifyingSamples.map { ChoiceValue($0, tag: tag).decodedDoubleValue }
                #expect(values.prefix(2).elementsEqual([0, current / 2]))
            }
            for pattern in entry.simplifyingSamples + entry.compensatingSamples {
                #expect(range.contains(pattern))
                #expect(ChoiceValue(pattern, tag: tag).decodedDoubleValue.isFinite)
            }
        }
        let nonfiniteTree = ChoiceTree.group([Double.infinity, -Double.infinity, Double.nan].map { value in
            .choice(ChoiceValue(tag.floatingBitPattern(from: value), tag: tag), .init(validRange: tag.bitPatternRange, isRangeExplicit: true))
        })
        #expect(ScopedStagedJointQuery.candidatePool(graph: ChoiceGraph.build(from: nonfiniteTree), isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init()).isEmpty)
    }

    @Test("Higher-order grids enumerate unique improving tuples", arguments: [3, 4])
    func uniqueGrid(arity: Int) {
        let tree = unsignedTree(values: Array(repeating: 3, count: arity), range: 0 ... 3)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let scope = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 1)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        var observed: Set<[UInt64]> = []
        for _ in 0 ..< 100 {
            var candidate = base
            guard let proposal = cursor.next(into: &candidate) else { break }
            #expect(proposal.leaves.count == arity)
            #expect(candidate.shortLexPrecedes(base))
            #expect(observed.insert(proposal.patterns).inserted)
        }
        #expect(observed.count == (arity == 3 ? 27 : 81))
        var candidate = base
        #expect(cursor.next(into: &candidate) == nil)
    }

    @Test("Discovery and retention have independent bounds; coupling hints influence ranking")
    func boundedRanking() {
        var graph = ChoiceGraph.build(from: unsignedTree(values: Array(repeating: 2, count: 12), range: 0 ... UInt64.max))
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let preferred = Array(frontier.suffix(3).map(\.leaf.nodeID))
        graph.couplingDependents[preferred[0]] = Set(preferred.dropFirst())
        let ranked = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 1)
        #expect(ranked.calculations == 220)
        #expect(ranked.groups.count == 1)
        #expect(ranked.groups.first?.leaves.map(\.nodeID) == preferred)
        let bounded = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 7, scopeLimit: 3)
        #expect(bounded.calculations == 7)
        #expect(bounded.groups.count == 3)
    }

    @Test("Full-width residual volumes saturate for ranking while sampled work gates eligibility")
    func fullWidthGate() throws {
        let tree = unsignedTree(values: [UInt64.max, UInt64.max - 1, UInt64.max - 2, UInt64.max - 3], range: 0 ... UInt64.max)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        #expect(ScopedStagedJointQuery.canWiden(to: 3, candidatePool: frontier, workLimit: 215) == false)
        #expect(ScopedStagedJointQuery.canWiden(to: 3, candidatePool: frontier, workLimit: 216))
        #expect(ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 4, workLimit: 1295, calculationLimit: 512, scopeLimit: 30).groups.isEmpty)
        let scope = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 4, workLimit: 1296, calculationLimit: 512, scopeLimit: 30)
        let group = try #require(scope.groups.first)
        #expect(scope.groups.count == 1)
        #expect(scope.estimatedWork == 1296)
        #expect(group.residualVolume == UInt64.max)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        var candidate = base
        #expect(cursor.next(into: &candidate) != nil)
        #expect(candidate.shortLexPrecedes(base))
    }

    @Test("Early discovery rejections still consume the bounded combination prefix", arguments: [3, 4])
    func rejectedCombinationPrefix(arity: Int) {
        var graph = ChoiceGraph.build(from: unsignedTree(values: [0, 3, 3, 3, 3, 3], range: 0 ... 3))
        markConverged(&graph)
        var frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let rejected = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 10, scopeLimit: 30)
        #expect(rejected.calculations == 10)
        #expect(rejected.groups.isEmpty)
        let firstEligible = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 11, scopeLimit: 30)
        #expect(firstEligible.calculations == 11)
        #expect(firstEligible.groups.count == 1)
        #expect(firstEligible.groups.first?.leaves.map(\.nodeID) == Array(frontier[1 ... arity].map(\.leaf.nodeID)))
        let source = frontier[1]
        frontier[1] = .init(leaf: source.leaf, stalled: source.stalled, span: source.span, simplifyingSamples: [], compensatingSamples: source.compensatingSamples)
        let emptyPalette = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 11, scopeLimit: 30)
        #expect(emptyPalette.calculations == 11)
        #expect(emptyPalette.groups.isEmpty)
    }

    @Test("Retained grids fit the total work limit rather than only a per-group limit", arguments: [3, 4])
    func totalScopeWork(arity: Int) {
        let tree = unsignedTree(values: Array(repeating: 3, count: 6), range: 0 ... 3)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let perGroup = arity == 3 ? 27 : 81
        let allGroups = arity == 3 ? 20 : 15
        let complete = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: Int.max, calculationLimit: 512, scopeLimit: 30)
        #expect(complete.groups.count == allGroups)
        #expect(complete.estimatedWork == allGroups * perGroup)
        let bounded = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: 2 * perGroup, calculationLimit: 512, scopeLimit: 30)
        #expect(bounded.groups.count == 2)
        #expect(bounded.estimatedWork == 2 * perGroup)
        #expect(bounded.calculations == allGroups)
        var cursor = NumericJointSearchCursor(groups: bounded.groups)
        let base = ChoiceSequence(tree)
        var emitted = 0
        for _ in 0 ... bounded.estimatedWork {
            var candidate = base
            guard cursor.next(into: &candidate) != nil else { break }
            #expect(candidate.shortLexPrecedes(base))
            emitted += 1
        }
        #expect(emitted == bounded.estimatedWork)
        let belowOne = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: arity, workLimit: perGroup - 1, calculationLimit: 512, scopeLimit: 30)
        #expect(belowOne.calculations == allGroups)
        #expect(belowOne.groups.isEmpty)
        #expect(belowOne.estimatedWork == 0)
    }

    @Test("Residual magnitude ranks affordable groups without excluding larger ones")
    func residualRanking() {
        var graph = ChoiceGraph.build(from: unsignedTree(values: [300, 6, 8, 10], range: 1 ... 1_000_000))
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let scope = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 4)
        #expect(scope.groups.first?.leaves.map(\.choice.bitPattern64) == [6, 8, 10])
        #expect(scope.groups.first?.residualVolume == 480)
        #expect(scope.groups.contains { $0.leaves.first?.choice.bitPattern64 == 300 })
        #expect(scope.estimatedWork == scope.groups.reduce(0) { $0 + $1.estimatedWork })
    }

    @Test("Joint admission checks the final edited leaf's bind identity and rejects clamping")
    func jointAdmission() throws {
        func tree(fingerprint: UInt64) -> ChoiceTree {
            .group([.uint64(6), .uint64(8), .bind(fingerprint: fingerprint, inner: .uint64(10), bound: .uint64(0))])
        }
        let originalTree = tree(fingerprint: 42)
        var graph = ChoiceGraph.build(from: originalTree)
        markConverged(&graph)
        let frontier = ScopedStagedJointQuery.candidatePool(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
        let scope = ScopedStagedJointQuery.groups(candidatePool: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 1)
        let group = try #require(scope.groups.first)
        #expect(group.leaves.map(\.choice.bitPattern64) == [6, 8, 10])
        let admission = DecoderAdmission.numericJoint(group.leaves)
        #expect(admission.admits(tree: originalTree))
        #expect(admission.admits(tree: tree(fingerprint: 43)) == false)
        var candidate = ChoiceSequence(originalTree)
        candidate[group.leaves[0].position] = candidate[group.leaves[0].position].withBitPattern(3)
        candidate[group.leaves[1].position] = candidate[group.leaves[1].position].withBitPattern(4)
        candidate[group.leaves[2].position] = candidate[group.leaves[2].position].withBitPattern(5)
        #expect(admission.admits(decoded: candidate, candidate: candidate, original: ChoiceSequence(originalTree)))
        var clamped = candidate
        clamped[group.leaves[2].position] = clamped[group.leaves[2].position].withBitPattern(4)
        #expect(admission.admits(decoded: clamped, candidate: candidate, original: ChoiceSequence(originalTree)) == false)
    }

    private func markConverged(_ graph: inout ChoiceGraph) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
    }

    private func unsignedTree(values: [UInt64], range: ClosedRange<UInt64>) -> ChoiceTree {
        .group(values.map { .choice(ChoiceValue($0, tag: .uint64), .init(validRange: range, isRangeExplicit: true)) })
    }
}
