import Testing
@testable import ExhaustCore

@Suite("Property-pass cache evidence")
struct PropertyPassCacheTests {
    @Test("Only an exclusively prefix-sourced pass crosses incumbents", arguments: [
        MaterializationSources(),
        .prefix,
        .fallbackTree,
        .prng,
        .unknown,
        [.prefix, .fallbackTree],
        [.prefix, .prng],
        [.prefix, .screeningPolicy],
        [.prefix, .unknown],
    ])
    func sourceBoundaries(sources: MaterializationSources) {
        var cache = ProbeCache()
        let decision = ProbeDecision(isGuided: true)
        let lookup = cache.lookup(probeHash: 100, decision: decision, incumbentHash: 200)
        cache.record(lookup, outcome: .propertyPassed(materializationAttempts: 1, sources: sources))

        #expect(cache.lookup(probeHash: 100, decision: decision, incumbentHash: 200).isCached)
        #expect(cache.lookup(probeHash: 100, decision: decision, incumbentHash: 300).isCached == (sources == .prefix))
    }

    @Test("A complete guided prefix reuses a property pass after the incumbent changes")
    func guidedPassCrossesIncumbents() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.zip(leaf, leaf)
        let initialTree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(9))))
        let smallerTree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(3))))
        let candidateTree = try #require(try Interpreters.reflect(generator, with: (UInt64(0), UInt64(0))))
        let candidate = ChoiceSequence(candidateTree)
        let probeHash = ZobristHash.hash(of: candidate)
        let selection = ReductionDecoder.Selection.guided(materializePicks: false)
        var calls = 0
        let decoder = ReductionDecoder(generator: generator.erase(), property: { output in
            calls += 1
            #expect((output as! (UInt64, UInt64)) == (0, 0))
            return true
        }, probeWrapper: nil, hasBind: false)
        var cache = ProbeCache()
        var counts = ReductionProbeCounts()
        for (index, tree) in [initialTree, smallerTree].enumerated() {
            let incumbent = Counterexample(sequence: ChoiceSequence(tree), tree: tree, output: ())
            let cached = cache.lookup(
                probeHash: probeHash,
                decision: ProbeDecision(selection),
                incumbentHash: ZobristHash.hash(of: incumbent.sequence)
            )
            let result = CandidateEvaluator.evaluate(
                candidate,
                against: incumbent,
                using: selection,
                decoder: decoder,
                admits: { incumbent.admits($0, under: .notLarger) },
                lookup: cached,
                cache: &cache,
                counts: &counts
            )
            switch (index, result) {
                case (0, .rejected), (1, .cached):
                    break
                default:
                    Issue.record("The second incumbent should reuse the prefix-only property pass")
            }
        }
        #expect(calls == 1)
        #expect(counts.propertyInvocations == 1)
        #expect(counts.rejectedByCache == 1)
        // Guided clamping and exact validation differ, even for a complete prefix.
        #expect(cache.lookup(probeHash: probeHash, decision: ProbeDecision(isGuided: false), incumbentHash: 0)
            .isCached == false)
        cache.removeAll()
        #expect(cache.lookup(probeHash: probeHash, decision: ProbeDecision(selection), incumbentHash: 0)
            .isCached == false)
    }

    @Test("A property pass is reusable across ordering and numeric admission policies", arguments: [false, true])
    func passesCrossPolicies(numericFirst: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(5)))
        let incumbent = Counterexample(sequence: ChoiceSequence(tree), tree: tree, output: UInt64(5))
        let incumbentHash = ZobristHash.hash(of: incumbent.sequence)
        var candidate = incumbent.sequence
        candidate[0] = candidate[0].withBitPattern(3)
        let probeHash = ZobristHash.hash(of: candidate)
        let leaf = ReductionLeaf(
            nodeID: 0,
            position: 0,
            path: [],
            choice: ChoiceValue(UInt64(5), tag: .uint64),
            range: 0 ... 10,
            bindFingerprints: [],
            mayReshapeOnAcceptance: false
        )
        let standard = ReductionDecoder.Selection.exact(materializePicks: false, admission: .standard)
        let numeric = ReductionDecoder.Selection.exact(materializePicks: false, admission: .numericJoint([leaf]))
        let selections = numericFirst ? [numeric, standard] : [standard, numeric]
        var calls = 0
        let decoder = ReductionDecoder(generator: generator.erase(), property: { _ in
            calls += 1
            return true
        }, probeWrapper: nil, hasBind: false)
        var cache = ProbeCache()
        var counts = ReductionProbeCounts()

        for (index, selection) in selections.enumerated() {
            let order: ReductionOrder = index == 0 ? .strictlySmaller : .notLarger
            let cached = cache.lookup(
                probeHash: probeHash,
                decision: ProbeDecision(selection, order: order),
                incumbentHash: incumbentHash
            )
            let evaluation = CandidateEvaluator.evaluate(
                candidate,
                against: incumbent,
                using: selection,
                decoder: decoder,
                admits: { incumbent.admits($0, under: order) },
                lookup: cached,
                cache: &cache,
                counts: &counts
            )
            switch (index, evaluation) {
                case (0, .rejected), (1, .cached):
                    break
                default:
                    Issue.record("The second policy must reuse the actual property pass")
            }
        }
        #expect(calls == 1)
        #expect(counts.propertyInvocations == 1)
        #expect(counts.rejectedByCache == 1)

        // Exact evidence must not suppress guided replay, which can recover a different value.
        #expect(cache
            .lookup(probeHash: probeHash, decision: ProbeDecision(isGuided: true), incumbentHash: incumbentHash)
            .isCached == false)
        cache.removeAll()
        #expect(cache.lookup(probeHash: probeHash, decision: ProbeDecision(standard), incumbentHash: incumbentHash)
            .isCached == false)
    }

    @Test("A numeric admission rejection is not evidence that the property passed")
    func admissionRejectionDoesNotCrossPolicies() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(5)))
        let incumbent = Counterexample(sequence: ChoiceSequence(tree), tree: tree, output: UInt64(5))
        let hash = ZobristHash.hash(of: incumbent.sequence)
        let leaf = ReductionLeaf(
            nodeID: 0,
            position: 0,
            path: [],
            choice: ChoiceValue(UInt64(5), tag: .uint64),
            range: 0 ... 10,
            bindFingerprints: [],
            mayReshapeOnAcceptance: false
        )
        let selections: [ReductionDecoder.Selection] = [
            .exact(materializePicks: false, admission: .numericJoint([leaf])),
            .exact(materializePicks: false, admission: .standard),
        ]
        var calls = 0
        let decoder = ReductionDecoder(generator: generator.erase(), property: { _ in
            calls += 1
            return false
        }, probeWrapper: nil, hasBind: false)
        var cache = ProbeCache()
        var counts = ReductionProbeCounts()
        for (index, selection) in selections.enumerated() {
            let cached = cache.lookup(probeHash: hash, decision: ProbeDecision(selection), incumbentHash: hash)
            let evaluation = CandidateEvaluator.evaluate(
                incumbent.sequence,
                against: incumbent,
                using: selection,
                decoder: decoder,
                admits: { incumbent.admits($0, under: .notLarger) },
                lookup: cached,
                cache: &cache,
                counts: &counts
            )
            switch (index, evaluation) {
                case (0, .rejected), (1, .admitted):
                    break
                default:
                    Issue.record("Ordinary reduction must still admit an equal failure")
            }
        }
        #expect(calls == 1)
        #expect(counts.rejectedByCache == 0)
    }
}
