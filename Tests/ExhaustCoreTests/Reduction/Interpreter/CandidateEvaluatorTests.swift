import Testing
@testable import ExhaustCore

@Suite("Candidate evaluation without adoption")
struct CandidateEvaluatorTests {
    enum Rejection: CaseIterable {
        case propertyPassed, materializationRejected, noRecoveredFailure
    }

    @Test("Rejected decoding is counted once and cached before another property call", arguments: Rejection.allCases)
    func rejectedDecoding(rejection: Rejection) throws {
        let fixture = try EvaluationFixture()
        var cache = ProbeCache(keying: .decisionAndIncumbent)
        var counts = ReductionProbeCounts()
        var propertyCalls = 0
        let decoder = fixture.decoder { _ in
            propertyCalls += 1
            return rejection == .propertyPassed
        }
        let selection: ReductionDecoder.Selection = rejection == .noRecoveredFailure
            ? .guided(materializePicks: false)
            : .exact(materializePicks: false, admission: .standard)
        // The unchanged guided candidate fails the property but cannot be recovered as an improvement.
        let candidate = fixture.candidate(rejection == .materializationRejected ? 101 : 5)
        let probeHash = ZobristHash.hash(of: candidate)
        let cacheKey = cache.key(probeHash: probeHash, decision: ProbeDecision(selection), incumbentHash: fixture.incumbentHash)

        let first = CandidateEvaluator.evaluate(candidate, against: fixture.incumbent, using: selection, decoder: decoder, probeHash: probeHash, cacheKey: cacheKey, cache: &cache, counts: &counts)
        let decoding = try #require(first)
        #expect(decoding.recovered == nil)
        #expect(cache.contains(cacheKey))
        switch (rejection, decoding.outcome) {
            case (.propertyPassed, .propertyPassed), (.materializationRejected, .materializationRejected), (.noRecoveredFailure, .propertyFailed(nil, _)):
                break
            default:
                Issue.record("The fixture must exercise the requested rejection")
        }
        let attempts = counts.materializationAttempts

        // Sparse searches may leave the candidate buffer unwritten on a hit. This empty buffer must never reach decoding.
        let cached = CandidateEvaluator.evaluate([], against: fixture.incumbent, using: selection, decoder: decoder, probeHash: probeHash, cacheKey: cacheKey, cache: &cache, counts: &counts)

        #expect(cached == nil)
        #expect(propertyCalls == (rejection == .materializationRejected ? 0 : 1))
        #expect(counts.terminalOutcomes == 2)
        #expect(counts.rejectedByCache == 1)
        #expect(counts.materializationAttempts == attempts)
        #expect(counts.emitted == 0)
        #expect(counts.accepted == 0)
    }

    @Test("Recovered failures remain evidence even when a caller would reject their ordering", arguments: [UInt64(3), 7])
    func recoveryDoesNotAdopt(value: UInt64) throws {
        let fixture = try EvaluationFixture()
        var cache = ProbeCache(keying: .decision)
        var counts = ReductionProbeCounts()
        let selection = ReductionDecoder.Selection.exact(materializePicks: false, admission: .standard)
        let candidate = fixture.candidate(value)
        let probeHash = ZobristHash.hash(of: candidate)
        let cacheKey = cache.key(probeHash: probeHash, decision: ProbeDecision(selection), incumbentHash: fixture.incumbentHash)

        let evaluation = CandidateEvaluator.evaluate(candidate, against: fixture.incumbent, using: selection, decoder: fixture.decoder { _ in false }, probeHash: probeHash, cacheKey: cacheKey, cache: &cache, counts: &counts)
        let recovered = try #require(evaluation?.recovered)

        #expect(recovered.output as? UInt64 == value)
        #expect(fixture.incumbent.output as? UInt64 == 5)
        #expect(fixture.incumbent.admits(recovered, under: .notLarger) == (value < 5))
        #expect(cache.contains(cacheKey) == false)
        #expect(counts.propertyFailed == 1)
        #expect(counts.accepted == 0)
    }

    @Test("Uncached evaluation ignores ordinary rejections and does not add new ones", arguments: [false, true])
    func bypassCache(propertyPasses: Bool) throws {
        let fixture = try EvaluationFixture()
        var cache = ProbeCache(keying: .sequence)
        var counts = ReductionProbeCounts()
        var calls = 0
        let decoder = fixture.decoder { _ in
            calls += 1
            return propertyPasses
        }
        let selection = ReductionDecoder.Selection.exact(materializePicks: true, admission: .standard)
        let cachedCandidate = fixture.candidate(7)
        let existingKey = ZobristHash.hash(of: cachedCandidate)
        cache.insert(existingKey)

        let first = CandidateEvaluator.evaluate(cachedCandidate, against: fixture.incumbent, using: selection, decoder: decoder, cacheKey: nil, cache: &cache, counts: &counts)
        let freshCandidate = fixture.candidate(8)
        let second = CandidateEvaluator.evaluate(freshCandidate, against: fixture.incumbent, using: selection, decoder: decoder, cacheKey: nil, cache: &cache, counts: &counts)

        #expect(first != nil)
        #expect(second != nil)
        #expect((first?.recovered != nil) == !propertyPasses)
        #expect((second?.recovered != nil) == !propertyPasses)
        #expect(calls == 2)
        #expect(cache.contains(existingKey))
        #expect(cache.contains(ZobristHash.hash(of: freshCandidate)) == false)
        #expect(counts.terminalOutcomes == 2)
        #expect(counts.rejectedByCache == 0)
        #expect(counts.accepted == 0)
    }
}

/// Keeps the incumbent fixed while tests inspect evidence returned from different candidate evaluations.
private struct EvaluationFixture {
    let generator = Gen.choose(in: UInt64(0) ... 100)
    let incumbent: Counterexample
    let incumbentHash: UInt64

    init() throws {
        let tree = try #require(try Interpreters.reflect(generator, with: 5))
        let sequence = ChoiceSequence(tree)
        incumbent = Counterexample(sequence: sequence, tree: tree, output: UInt64(5))
        incumbentHash = ZobristHash.hash(of: sequence)
    }

    func candidate(_ value: UInt64) -> ChoiceSequence {
        var sequence = incumbent.sequence
        sequence[0] = sequence[0].withBitPattern(value)
        return sequence
    }

    func decoder(property: @escaping (Any) -> Bool) -> ReductionDecoder {
        ReductionDecoder(generator: generator.erase(), property: property, probeWrapper: nil, hasBind: false)
    }
}
