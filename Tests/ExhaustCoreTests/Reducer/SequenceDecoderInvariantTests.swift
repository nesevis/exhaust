import Testing
@testable import ExhaustCore

@Suite("SequenceDecoder invariants")
struct SequenceDecoderInvariantTests {
    @Test("Exact decoding leaves shortlex admission to the producer")
    func exactDecodingDefersShortlexToProducer() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let originalTree = try #require(try Interpreters.reflect(generator, with: UInt64(0)))
        let candidateTree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let originalSequence = ChoiceSequence(originalTree)
        let candidateSequence = ChoiceSequence(candidateTree)
        var filterObservations: [UInt64: FilterObservation] = [:]

        let result = try SequenceDecoder.exact().decodeAny(
            candidate: candidateSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in false },
            filterObservations: &filterObservations
        )

        #expect(candidateSequence.shortLexPrecedes(originalSequence) == false)
        let decoded = try #require(result)
        #expect(decoded.sequence.operativeHash == candidateSequence.operativeHash)
        #expect(decoded.output as? UInt64 == 1)
    }
}
