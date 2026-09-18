import Testing
@testable import ExhaustCore

@Suite("Generation purpose")
struct GenerationPurposeTests {
    @Test("Preparing an analysis interpreter does not change independent sampling contexts")
    func independentPurposes() throws {
        let generator = Gen.chooseDepth(in: UInt64(0) ... 5, scaling: .constant)
        var reference = ValueAndChoiceTreeInterpreter(generator, seed: 42)
        let (expected, _) = try #require(try reference.next())
        let expectedState = reference.randomNumberGeneratorSnapshot.state
        var analysis = ValueAndChoiceTreeInterpreter(generator, seed: 42)
        var sampling = ValueAndChoiceTreeInterpreter(generator, seed: 42)
        analysis.prepareForScreeningAnalysis()
        _ = try #require(try analysis.next())
        let (actual, _) = try #require(try sampling.next())
        #expect(actual == expected)
        #expect(sampling.randomNumberGeneratorSnapshot.state == expectedState)
    }

    @Test("Speculative branches inherit their parent's purpose", arguments: [GenerationContext.Purpose.sampling, .screeningAnalysis])
    func speculativePurpose(purpose: GenerationContext.Purpose) {
        let context = GenerationContext(
            maxRuns: 1,
            baseSeed: 42,
            isFixed: false,
            size: 100,
            prng: Xoshiro256(seed: 42),
            purpose: purpose
        )
        let speculative = context.jump(seed: 1337)
        #expect(speculative.purpose == purpose)
        #expect(speculative.isSpeculative == true)
        #expect(context.purpose == purpose)
    }

    @Test("Analysis pins depth without a PRNG draw while sampling retains its ordinary draw")
    func depthResolution() throws {
        let generator = Gen.chooseDepth(in: UInt64(0) ... 5, scaling: .constant)
        var analysis = ValueAndChoiceTreeInterpreter(generator, seed: 42, maxRuns: 1, sizeOverride: 100)
        var sampling = ValueAndChoiceTreeInterpreter(generator, seed: 42, maxRuns: 1, sizeOverride: 100)
        analysis.prepareForScreeningAnalysis()
        let (analyzed, _) = try #require(try analysis.next())
        let (sampled, _) = try #require(try sampling.next())
        var expected = Xoshiro256.derive(from: 42, at: 0)
        #expect(analyzed == 5)
        #expect(analysis.randomNumberGeneratorSnapshot.state == expected.currentState)
        #expect(sampled == expected.next(in: UInt64(0) ... 5))
        #expect(sampling.randomNumberGeneratorSnapshot.state == expected.currentState)
    }
}
