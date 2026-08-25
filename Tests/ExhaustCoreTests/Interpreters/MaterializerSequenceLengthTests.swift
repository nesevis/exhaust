//
//  MaterializerSequenceLengthTests.swift
//  Exhaust
//
//  The generation interpreters refuse a drawn sequence length above `SharedInterpreterHelpers.maximumSequenceLength`. The materializer resolves lengths through four paths, three of which derive the count from structure already present (prefix element count, or fallback element count, both clamped to the generator's declared range) and one of which draws a fresh length from the length generator itself. These tests pin the bounds that hold in production: generation refuses an oversize draw, the fallback path takes its count from the fallback, and corrupting a real parent stays within the maximum. The fresh-draw path is deliberately not pinned; see `project_materializer_sequence_length_uncapped` in project memory for why it is unreachable and why no guard was added.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Materializer sequence length bound")
struct MaterializerSequenceLengthTests {
    // MARK: - Baseline: the interpreters refuse

    @Test("Generation refuses a drawn length above the maximum")
    func generationRefusesOversizeLength() throws {
        var interpreter = ValueAndChoiceTreeInterpreter(oversizeLengthGen(), seed: 0xA11CE5, maxRuns: 1)
        #expect(throws: GeneratorError.self) {
            _ = try interpreter.next()
        }
    }

    // MARK: - The structure-derived paths

    @Test("Guided materialization with an element fallback takes its count from the fallback")
    func guidedFallbackLengthComesFromFallbackElements() throws {
        let gen = Gen.arrayOf(Gen.just(UInt8(7)), within: 0 ... 200_000, scaling: .constant)
        let fallback = ChoiceTree.sequence(
            elements: [.just, .just, .just],
            metadata: ChoiceMetadata(validRange: nil, isRangeExplicit: false)
        )
        let result = Materializer.materializeAnyFlat(
            gen.erase(),
            prefix: ChoiceSequence(),
            mode: .guided(seed: 0xF00D, fallbackTree: fallback)
        )
        guard case let .success(value, _, _) = result else {
            Issue.record("expected the fallback element count to resolve the length")
            return
        }
        let array = try #require(value as? [UInt8])
        #expect(array.count == 3)
    }

    @Test(
        "Corrupting a real parent never produces a sequence above the maximum",
        arguments: [7, 99, 1234] as [UInt64]
    )
    func corruptedParentStaysWithinMaximum(seed: UInt64) throws {
        // The fuzz loop's actual shape: a parent generated through the interpreter, mutated at high
        // intensity, then materialized in guided mode against that parent's own tree.
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 255), within: 0 ... 40, scaling: .constant)
        let erased = gen.erase()
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 8)
        var prng = Xoshiro256(seed: seed ^ 0x5EED)

        while let (_, tree) = try interpreter.next() {
            let parentSequence = ChoiceSequence.flatten(tree)
            for _ in 0 ..< 16 {
                let candidate = FuzzMutator.mutate(parentSequence, intensity: .high, prng: &prng)
                let result = Materializer.materializeAnyFlat(
                    erased,
                    prefix: candidate,
                    mode: .guided(seed: prng.next(), fallbackTree: tree)
                )
                guard case let .success(value, _, _) = result else {
                    continue
                }
                let array = try #require(value as? [UInt64])
                #expect(array.count <= SharedInterpreterHelpers.maximumSequenceLength)
            }
        }
    }
}

// MARK: - Helpers

/// An array generator whose declared length range reaches well above ``SharedInterpreterHelpers/maximumSequenceLength``, with constant scaling so the full range is live at every size. `.just` elements keep a successful oversize materialization cheap enough to observe rather than fatal.
private func oversizeLengthGen() -> Generator<[UInt8]> {
    Gen.arrayOf(Gen.just(UInt8(0)), within: 100_000 ... 200_000, scaling: .constant)
}
