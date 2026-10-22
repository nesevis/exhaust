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

        let first = CandidateEvaluator.evaluate(candidate, against: fixture.incumbent, using: selection, decoder: decoder, admits: { _ in
            Issue.record("Rejected decoding must not invoke admission")
            return true
        }, probeHash: probeHash, cacheHit: cache.contains(cacheKey), cacheKey: cacheKey, cache: &cache, counts: &counts)
        guard case let .rejected(decoding) = first else {
            Issue.record("Expected a decoded rejection")
            return
        }
        #expect(decoding.recovered == nil)
        #expect(cache.contains(cacheKey))
        switch (rejection, decoding.outcome) {
            case (.propertyPassed, .propertyPassed), (.materializationRejected, .materializationRejected), (.noRecoveredFailure, .propertyFailed(nil, _)):
                break
            default:
                Issue.record("The fixture must exercise the requested rejection")
        }
        let attempts = counts.materializationAttempts

        // Lazy searches may leave the candidate buffer unwritten on a hit. This empty buffer must never reach decoding.
        let cached = CandidateEvaluator.evaluate([], against: fixture.incumbent, using: selection, decoder: decoder, admits: { _ in
            Issue.record("A cache hit must not invoke admission")
            return true
        }, probeHash: probeHash, cacheHit: cache.contains(cacheKey), cacheKey: cacheKey, cache: &cache, counts: &counts)

        guard case .cached = cached else {
            Issue.record("Expected a cached rejection")
            return
        }
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

        let evaluation = CandidateEvaluator.evaluate(candidate, against: fixture.incumbent, using: selection, decoder: fixture.decoder { _ in false }, admits: { _ in true }, probeHash: probeHash, cacheHit: cache.contains(cacheKey), cacheKey: cacheKey, cache: &cache, counts: &counts)
        guard case let .admitted(recovered, decoding) = evaluation else {
            Issue.record("Confirmation must admit every recovered failure")
            return
        }
        #expect(decoding.recovered?.sequence == recovered.sequence)

        #expect(recovered.output as? UInt64 == value)
        #expect(fixture.incumbent.output as? UInt64 == 5)
        #expect(fixture.incumbent.admits(recovered, under: .notLarger) == (value < 5))
        #expect(cache.contains(cacheKey) == false)
        #expect(counts.propertyFailed == 1)
        #expect(counts.accepted == 0)
    }

    @Test(
        "Caller ordering determines admission and caches recovered rejections",
        arguments: [UInt64(3), 5, 7], [false, true]
    )
    func recoveredAdmission(value: UInt64, requiresStrictImprovement: Bool) throws {
        let fixture = try EvaluationFixture()
        var cache = ProbeCache(keying: .decisionAndIncumbent)
        var counts = ReductionProbeCounts()
        var propertyCalls = 0
        var admissionCalls = 0
        let decoder = fixture.decoder { _ in
            propertyCalls += 1
            return false
        }
        let selection = ReductionDecoder.Selection.exact(materializePicks: false, admission: .standard)
        let candidate = fixture.candidate(value)
        let probeHash = ZobristHash.hash(of: candidate)
        let cacheKey = cache.key(probeHash: probeHash, decision: ProbeDecision(selection), incumbentHash: fixture.incumbentHash)
        let shouldAdmit = requiresStrictImprovement ? value < 5 : value <= 5
        for _ in 0 ..< 2 {
            let evaluation = CandidateEvaluator.evaluate(
                candidate,
                against: fixture.incumbent,
                using: selection,
                decoder: decoder,
                admits: { recovered in
                    admissionCalls += 1
                    return requiresStrictImprovement
                        ? recovered.sequence.shortLexPrecedes(fixture.incumbent.sequence)
                        : fixture.incumbent.admits(recovered, under: .notLarger)
                },
                probeHash: probeHash,
                cacheHit: cache.contains(cacheKey),
                cacheKey: cacheKey,
                cache: &cache,
                counts: &counts
            )
            switch evaluation {
                case .cached:
                    #expect(shouldAdmit == false)
                case let .rejected(decoding):
                    #expect(shouldAdmit == false)
                    #expect(decoding.recovered?.output as? UInt64 == value)
                case let .admitted(recovered, decoding):
                    #expect(shouldAdmit)
                    #expect(recovered.output as? UInt64 == value)
                    #expect(decoding.recovered?.sequence == recovered.sequence)
            }
        }
        #expect(cache.contains(cacheKey) == (shouldAdmit == false))
        #expect(propertyCalls == (shouldAdmit ? 2 : 1))
        #expect(admissionCalls == propertyCalls)
        #expect(counts.propertyFailed == propertyCalls)
        #expect(counts.rejectedByCache == (shouldAdmit ? 0 : 1))
        #expect(counts.terminalOutcomes == 2)
        #expect(counts.accepted == 0)
        #expect(fixture.incumbent.output as? UInt64 == 5)
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

        let first = CandidateEvaluator.evaluate(cachedCandidate, against: fixture.incumbent, using: selection, decoder: decoder, admits: { _ in true }, cacheHit: false, cacheKey: nil, cache: &cache, counts: &counts)
        let freshCandidate = fixture.candidate(8)
        let second = CandidateEvaluator.evaluate(freshCandidate, against: fixture.incumbent, using: selection, decoder: decoder, admits: { _ in true }, cacheHit: false, cacheKey: nil, cache: &cache, counts: &counts)

        for result in [first, second] {
            switch result {
                case .cached:
                    Issue.record("Bypassed cache must never reject a candidate")
                case let .rejected(decoding):
                    #expect(propertyPasses)
                    #expect(decoding.recovered == nil)
                case let .admitted(_, decoding):
                    #expect(propertyPasses == false)
                    #expect(decoding.recovered != nil)
            }
        }
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
