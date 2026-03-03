//
//  GeneratorCompositionEdgeCaseTests.swift
//  ExhaustTests
//
//  Tests for edge cases in generator composition including empty generators,
//  single-value generators, and complex composition scenarios.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Generator Composition Edge Cases")
struct GeneratorCompositionEdgeCaseTests {
    @Test("Single value generator composition")
    func singleValueGeneratorComposition() {
        let constantGen = #gen(.just(42))
        let normalGen = #gen(.string())

        let composed = #gen(constantGen, normalGen)

        // Generate multiple values
        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (constant, string) = iterator.next()!
            #expect(constant == 42) // Constant should always be the same
            // String can be anything
        }
    }

    @Test("Zipping many generators maintains correctness")
    func largeZipComposition() {
        let gen = #gen(
            Int.arbitrary,
            .string(),
            UInt.arbitrary,
            Double.arbitrary,
            .int(in: 1 ... 100),
        )

        // Verify all components are generated correctly
        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(gen)
            let (int, string, uint, double, ranged) = iterator.next()!

            // Type checking ensures correctness, but verify range constraint
            #expect(ranged >= 1)
            #expect(ranged <= 100)
        }
    }

    @Test("Nested composition with multiple levels")
    func nestedCompositionLevels() {
        let innerGen = #gen(Int.arbitrary, .string())
        let middleGen = #gen(innerGen, Bool.arbitrary)
        let outerGen = #gen(middleGen, UInt.arbitrary)

        var iterator = ValueInterpreter(outerGen)
        let nestedTuple = iterator.next()!
        // TOOD: write #expects

        // All values should be generated successfully
        // Type system ensures correctness
    }

    @Test("Empty array generator in composition")
    func emptyArrayGeneratorComposition() {
        let emptyArrayGen = #gen(.just([Int]()))
        let normalGen = #gen(.string())

        let composed = #gen(emptyArrayGen, normalGen)

        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (emptyArray, _) = iterator.next()!
            #expect(emptyArray.isEmpty)
        }
    }

    @Test("Composition with bound generators")
    func boundGeneratorComposition() {
        let dependentGen = Int.arbitrary.bind { first in
            Gen.choose(in: first ... (first + 10)).map { second in
                (first, second)
            }
        }

        let independentGen = #gen(.string())
        let composed = #gen(dependentGen, independentGen)

        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(composed)
            let ((first, second), _) = iterator.next()!
            #expect(second >= first)
            #expect(second <= first + 10)
        }
    }

    @Test("Composition preserves replay behavior")
    func compositionReplayBehavior() throws {
        let gen = #gen(
            .int(in: 1 ... 100),
            .string(),
            Bool.arbitrary,
        )

        var iterator = ValueInterpreter(gen)
        let generated = iterator.next()!
        let recipe = try #require(try Interpreters.reflect(gen, with: generated))
        let replayed = try #require(try Interpreters.replay(gen, using: recipe))

        #expect(generated == replayed)
    }

    @Test("Composition with array generation")
    func arrayComposition() {
        let arrayGen = Int.arbitrary.array(length: 0 ... 5)
        let scalarGen = #gen(.string())

        let composed = #gen(arrayGen, scalarGen)

        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(composed)
            let (array, string) = iterator.next()!
            #expect(array.count >= 0) // swiftlint:disable:this empty_count
            #expect(array.count <= 5)
        }
    }

    @Test("Deeply nested array composition")
    func deeplyNestedArrayComposition() {
        let nestedGen = Int.arbitrary
            .array(length: 1 ... 3)
            .array(length: 1 ... 2)
            .array(length: 1 ... 2)

        let composed = #gen(nestedGen, .string())

        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (nested, string) = iterator.next()!

            // Verify structure depth
            #expect(nested.count >= 1)
            #expect(nested.count <= 2)

            for level2 in nested {
                #expect(level2.count >= 1)
                #expect(level2.count <= 2)

                for level3 in level2 {
                    #expect(level3.count >= 1)
                    #expect(level3.count <= 3)
                }
            }
        }
    }
}
