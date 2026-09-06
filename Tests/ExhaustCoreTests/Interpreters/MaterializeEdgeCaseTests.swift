//
//  MaterializeEdgeCaseTests.swift
//  Exhaust
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Materialize edge cases")
struct MaterializeEdgeCaseTests {
    // MARK: - Sequences of just elements

    @Test("Array of just values materializes correctly")
    func arrayOfJustValues() throws {
        let gen = Gen.arrayOf(Gen.just("hello"), exactly: 3)
        let results = try roundTripBatch(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Array of just values with variable length materializes correctly")
    func arrayOfJustValuesVariableLength() throws {
        let gen = Gen.arrayOf(Gen.just(42 as UInt), within: 0 ... 5, scaling: .constant)
        let results = try roundTripBatch(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Nested arrays where inner elements are just")
    func nestedArrayOfJust() throws {
        let inner = Gen.arrayOf(Gen.just("x"), within: 0 ... 3, scaling: .constant)
        let gen = Gen.arrayOf(inner, within: 1 ... 3, scaling: .constant)
        let results = try roundTripBatch(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    @Test("Pick between just values inside an array")
    func pickOfJustInArray() throws {
        let pick: Generator<String> = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a")),
            (weight: 1, generator: Gen.just("b")),
            (weight: 1, generator: Gen.just("c")),
        ])
        let gen = Gen.arrayOf(pick, within: 1 ... 5, scaling: .constant)
        let results = try roundTripBatch(gen)
        for result in results {
            #expect(result.original == result.materialized)
        }
    }

    // MARK: - Exact replay of floating-point patterns

    @Test("Exact mode replays a floating-point pattern whose bits fall below the range's minimum bits")
    func exactReplaysFloatPatternBelowMinimumBits() {
        // Floating-point bit patterns are not ordered by value: the bits of a negative bound exceed the bits of a small positive one. Guided materialization passes any float pattern through unclamped, so a prefix carrying bit pattern 0 is emitted as is; exact replay of that emission must accept it the same way rather than comparing raw bits against the bounds' bits. The value the pattern decodes to is beside the point, so the assertions compare patterns.
        let gen = Gen.choose(in: -100.0 ... 0.05) as Generator<Double>
        let prefix: ChoiceSequence = [
            .value(.init(choice: ChoiceValue(0 as UInt64, tag: .double), validRange: 0 ... UInt64.max)),
        ]
        guard case let .success(guidedValue, guidedTree, _) = Materializer.materialize(
            gen, prefix: prefix, mode: .guided(seed: 1, fallbackTree: nil)
        ) else {
            Issue.record("guided materialization rejected the prefix")
            return
        }
        let emitted = ChoiceSequence.flatten(guidedTree)
        guard case let .success(exactValue, exactTree, _) = Materializer.materialize(gen, prefix: emitted, mode: .exact) else {
            Issue.record("exact materialization rejected the sequence guided materialization emitted")
            return
        }
        #expect(exactValue.bitPattern == guidedValue.bitPattern)
        #expect(ChoiceSequence.flatten(exactTree) == emitted)
    }
}
