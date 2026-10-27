import Testing
@testable import ExhaustCore

@Suite("Probe cache admission boundaries")
struct ProbeCacheAdmissionTests {
    @Test("A guided rejection cannot suppress a failure recovered from a different incumbent")
    func guidedFallbackChangesWithIncumbent() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.zip(leaf, leaf)
        let initialTree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(9))))
        let smallerTree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(3))))
        let initial = Counterexample(
            sequence: ChoiceSequence(initialTree),
            tree: initialTree,
            output: (UInt64(5), UInt64(9))
        )
        let smaller = Counterexample(
            sequence: ChoiceSequence(smallerTree),
            tree: smallerTree,
            output: (UInt64(5), UInt64(3))
        )
        // A missing second value is supplied from the current fallback tree.
        var candidate = initial.sequence
        let positions = candidate.indices.filter { candidate[$0].value != nil }
        candidate[positions[0]] = candidate[positions[0]].withBitPattern(0)
        candidate.removeSubrange(positions[1]...)
        let selection = ReductionDecoder.Selection.guided(materializePicks: false)
        var outputs: [(UInt64, UInt64)] = []
        let decoder = ReductionDecoder(generator: generator.erase(), property: { output in
            let value = output as! (UInt64, UInt64)
            outputs.append(value)
            return value.1 > 3
        }, probeWrapper: nil, hasBind: false)
        var cache = ProbeCache()
        var counts = ReductionProbeCounts()
        let probeHash = ZobristHash.hash(of: candidate)

        for incumbent in [initial, smaller] {
            let cached = cache.lookup(
                probeHash: probeHash,
                decision: ProbeDecision(selection),
                incumbentHash: ZobristHash.hash(of: incumbent.sequence)
            )
            let evaluation = CandidateEvaluator.evaluate(
                candidate,
                against: incumbent,
                using: selection,
                decoder: decoder,
                admits: { incumbent.admits($0, under: .notLarger) },
                lookup: cached,
                cache: &cache,
                counts: &counts
            )
            if incumbent.sequence == smaller.sequence {
                guard case let .admitted(recovered, _) = evaluation else {
                    Issue.record("The smaller fallback must recover a failing candidate")
                    return
                }
                let output = try #require(recovered.output as? (UInt64, UInt64))
                #expect(output == (0, 3))
            } else {
                guard case .rejected = evaluation else {
                    Issue.record("The original fallback must pass the property")
                    return
                }
            }
        }
        #expect(outputs.count == 2)
        #expect(outputs.first?.0 == 0)
        #expect(outputs.first?.1 == 9)
        #expect(counts.rejectedByCache == 0)
    }

    @Test("Strict recovery rejection does not suppress an ordinary lateral failure")
    func orderingPoliciesAreIndependent() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(5)))
        let incumbent = Counterexample(sequence: ChoiceSequence(tree), tree: tree, output: UInt64(5))
        let incumbentHash = ZobristHash.hash(of: incumbent.sequence)
        let selection = ReductionDecoder.Selection.exact(materializePicks: false, admission: .standard)
        var calls = 0
        let decoder = ReductionDecoder(generator: generator.erase(), property: { _ in
            calls += 1
            return false
        }, probeWrapper: nil, hasBind: false)
        var cache = ProbeCache()
        var counts = ReductionProbeCounts()

        for order in [ReductionOrder.strictlySmaller, .notLarger] {
            let cached = cache.lookup(
                probeHash: incumbentHash,
                decision: ProbeDecision(selection, order: order),
                incumbentHash: incumbentHash
            )
            let evaluation = CandidateEvaluator.evaluate(
                incumbent.sequence,
                against: incumbent,
                using: selection,
                decoder: decoder,
                admits: { incumbent.admits($0, under: order) },
                lookup: cached,
                cache: &cache,
                counts: &counts
            )
            switch (order, evaluation) {
                case (.strictlySmaller, .rejected), (.notLarger, .admitted):
                    break
                default:
                    Issue.record("Each ordering must decide the recovered failure independently")
            }
        }
        #expect(calls == 2)
        #expect(counts.rejectedByCache == 0)
    }
}
