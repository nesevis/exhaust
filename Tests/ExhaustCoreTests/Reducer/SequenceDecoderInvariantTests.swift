import Testing
@testable import ExhaustCore

@Suite("SequenceDecoder invariants")
struct SequenceDecoderInvariantTests {
    @Test("Exact decoding rejects candidates that do not improve shortlex")
    func exactDecodingEnforcesShortlex() throws {
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
        #expect(result == nil)
    }

    @Test("Reduction preserves the original failure class")
    func reductionPreservesFailureClass() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let initialValue: UInt64 = 10
        let initialTree = try #require(try Interpreters.reflect(generator, with: initialValue))

        let result = try Interpreters.choiceGraphReduce(
            gen: generator,
            tree: initialTree,
            output: initialValue,
            config: .init(maxStalls: 2),
            property: { value in
                value != 0 && value < 5
            }
        )
        let (_, reducedValue) = try #require(result.counterexample)

        #expect(initialValue >= 5)
        #expect(reducedValue >= 5)
    }

    @Test("Reduction rejects an output that does not match its choice tree")
    func reductionValidatesInitialOutputAgainstTree() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let suppliedOutput: UInt64 = 10
        let treeOutput: UInt64 = 1
        let initialTree = try #require(try Interpreters.reflect(generator, with: treeOutput))

        let result = try Interpreters.choiceGraphReduce(
            gen: generator,
            tree: initialTree,
            output: suppliedOutput,
            config: .init(maxStalls: 1, enabledEncoders: []),
            property: { value in
                value != suppliedOutput
            }
        )

        guard case .failure = result else {
            Issue.record("Expected reduction to reject the inconsistent output and tree")
            return
        }
    }
}
