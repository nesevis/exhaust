import Testing
@testable import ExhaustCore

@Suite("Improving pivots")
struct ImprovingPivotCursorTests {
    private static let cacheKeyings: [ProbeCacheKeying] = [.sequence, .decision, .decisionAndIncumbent]

    @Test("A non-improving recorded fill still permits an improving transplant")
    func transplantAfterNonImprovingRecordedFill() throws {
        let target = ChoiceTree.group([leaf(2, range: 0 ... 3), leaf(2, range: 0 ... 3)], isZip: true)
        let selected = ChoiceTree.group([leaf(1, range: 0 ... 10), leaf(8, range: 0 ... 10)], isZip: true)
        let tree = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [target, selected])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let pickNodeID = try #require(graph.liveNodeIDs.first { nodeID in
            if case .pick = graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        let recorded = try #require(PivotCandidates.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: 0, fill: .recorded, sequence: sequence, graph: graph))
        let transplanted = try #require(PivotCandidates.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: 0, fill: .transplanted, sequence: sequence, graph: graph))
        #expect(recorded.shortLexPrecedes(sequence) == false)
        #expect(transplanted.shortLexPrecedes(sequence))

        var cursor = makeCursor(tree: tree)

        #expect(cursor.next()?.sequence == transplanted)
        #expect(cursor.next() == nil)
    }

    @Test("Identical fills are emitted once and cached under the configured decision", arguments: cacheKeyings)
    func duplicateFillsAndCache(keying: ProbeCacheKeying) throws {
        let tree = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [leaf(100, range: 0 ... 100), leaf(250, range: 200 ... 300)])
        var cache = ProbeCache(keying: keying)
        var cursor = makeCursor(tree: tree, cache: cache)
        let next = cursor.next()
        let first = try #require(next)
        let incumbentHash = ZobristHash.hash(of: ChoiceSequence(tree))

        #expect(first.sequence.compactMap { $0.value?.choice.bitPattern64 } == [100])
        #expect(first.cacheKey == cache.key(probeHash: first.probeHash, decision: ImprovingPivotCursor.decision, incumbentHash: incumbentHash))
        #expect(cursor.next() == nil)
        #expect(cursor.next() == nil)

        cache.insert(first.cacheKey)
        var cached = makeCursor(tree: tree, cache: cache)
        #expect(cached.next() == nil)
    }

    @Test("Cached fills leave the improving probe budget for an uncached fill", arguments: cacheKeyings)
    func cachedFillDoesNotSpendBudget(keying: ProbeCacheKeying) throws {
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(250)))
        var tuning = ReductionTuning()
        tuning.relaxImprovingProbeBudget = 1
        tuning.probeCacheKeying = keying
        var propertyCalls = 0
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: UInt64(250),
            configuration: .init(maxStalls: 2, enabledEncoders: [.branchPivot], tuning: tuning),
            collectStats: true,
            property: { _ in
                propertyCalls += 1
                return true
            }
        )
        var cursor = makeCursor(tree: runner.incumbent.tree, cache: runner.rejectCache)
        let next = cursor.next()
        let first = try #require(next)
        let farthest = cursor.next()
        try #require(farthest != nil, "The uncached farthest fill must exercise the remaining budget")
        runner.rejectCache.insert(first.cacheKey)
        #expect(runner.hasUnprobedImprovingPivot)

        let accepted = runner.runImprovingPivotPass()

        #expect(accepted == false)
        #expect(propertyCalls == 1)
        #expect(runner.stats.relaxImprovingProbes == 1)
        #expect(runner.stats.reductionProbes == 1)
        #expect(runner.hasUnprobedImprovingPivot == false)
        #expect(runner.incumbent.output as? UInt64 == 250)
    }

    @Test("An expired preparation deadline yields no pivot")
    func expiredPreparation() {
        let tree = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [leaf(10, range: 0 ... 100), leaf(250, range: 200 ... 300)])
        var cursor = makeCursor(tree: tree, deadline: ReductionDeadline(start: 0, budget: 1, clock: { 1 }))

        #expect(cursor.next() == nil)
        #expect(cursor.next() == nil)
    }
}

// MARK: - Test helpers

private func leaf(_ value: UInt64, range: ClosedRange<UInt64>) -> ChoiceTree {
    .choice(ChoiceValue(value, tag: .uint64), .init(validRange: range, isRangeExplicit: true))
}

private func makeCursor(tree: ChoiceTree, cache: ProbeCache = [], deadline: ReductionDeadline = .none) -> ImprovingPivotCursor {
    let sequence = ChoiceSequence(tree)
    return ImprovingPivotCursor(sequence: sequence, incumbentHash: ZobristHash.hash(of: sequence), graph: ChoiceGraph.build(from: tree), rejectCache: cache, deadline: deadline)
}
