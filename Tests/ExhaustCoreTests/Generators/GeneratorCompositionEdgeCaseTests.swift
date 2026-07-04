//
//  GeneratorCompositionEdgeCaseTests.swift
//  ExhaustTests
//
//  Tests for edge cases in generator composition including empty generators,
//  single-value generators, and complex composition scenarios.
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Generator Composition Edge Cases")
struct GeneratorCompositionEdgeCaseTests {
    @Test("Single value generator composition")
    func singleValueGeneratorComposition() throws {
        let constantGen = Gen.just(42)
        let normalGen = stringGen()

        let composed = Gen.zip(constantGen, normalGen)

        var iterator = ValueInterpreter(composed, seed: 42, maxRuns: 10)
        var drawn = 0
        while let (constant, _) = try iterator.next() {
            drawn += 1
            #expect(constant == 42) // Constant should always be the same
            // String can be anything
        }
        #expect(drawn == 10)
    }

    @Test("Zipping many generators maintains correctness")
    func largeZipComposition() throws {
        let gen = Gen.zip(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            stringGen(),
            Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling),
            Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling),
            Gen.choose(in: 1 ... 100) as Generator<Int>
        )

        // Verify all components are generated correctly
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)
        var drawn = 0
        while let (_, _, _, _, ranged) = try iterator.next() {
            drawn += 1
            // Type checking ensures correctness, but verify range constraint
            #expect(ranged >= 1)
            #expect(ranged <= 100)
        }
        #expect(drawn == 20)
    }

    @Test("Nested composition with multiple levels")
    func nestedCompositionLevels() throws {
        let innerGen = Gen.zip(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            stringGen()
        )
        let middleGen = Gen.zip(innerGen, Gen.choose(from: [true, false]))
        let outerGen = Gen.zip(middleGen, Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling))

        var iterator = ValueInterpreter(outerGen, seed: 42)
        let value = try #require(try iterator.next())
        let ((_, _), _) = value.0
        _ = value.1
    }

    @Test("Empty array generator in composition")
    func emptyArrayGeneratorComposition() throws {
        let emptyArrayGen = Gen.just([Int]())
        let normalGen = stringGen()

        let composed = Gen.zip(emptyArrayGen, normalGen)

        var iterator = ValueInterpreter(composed, seed: 42, maxRuns: 10)
        while let (emptyArray, _) = try iterator.next() {
            #expect(emptyArray.isEmpty)
        }
    }

    @Test("Composition with bound generators")
    func boundGeneratorComposition() throws {
        let dependentGen = (Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling) as Generator<Int>).bind { first in
            Gen.choose(in: first ... (first + 10)).map { second in
                (first, second)
            }
        }

        let independentGen = stringGen()
        let composed = Gen.zip(dependentGen, independentGen)

        var iterator = ValueInterpreter(composed, seed: 42, maxRuns: 20)
        var drawn = 0
        while let ((first, second), _) = try iterator.next() {
            drawn += 1
            #expect(second >= first)
            #expect(second <= first + 10)
        }
        #expect(drawn == 20)
    }

    @Test("Composition preserves replay behavior")
    func compositionReplayBehavior() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 100) as Generator<Int>,
            stringGen(),
            Gen.choose(from: [true, false])
        )

        var iterator = ValueInterpreter(gen, seed: 42)
        let generated = try #require(try iterator.next())
        let recipe = try #require(try Interpreters.reflect(gen, with: generated))
        let replayed = try #require(try Interpreters.replay(gen, using: recipe))

        #expect(generated == replayed)
    }

    @Test("Composition with array generation")
    func arrayComposition() throws {
        let arrayGen = Gen.arrayOf(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            within: 0 ... 5
        )
        let scalarGen = stringGen()

        let composed = Gen.zip(arrayGen, scalarGen)

        var iterator = ValueInterpreter(composed, seed: 42, maxRuns: 20)
        while let (array, _) = try iterator.next() {
            #expect(array.count <= 5)
        }
    }

    @Test("Deeply nested array composition")
    func deeplyNestedArrayComposition() throws {
        let nestedGen = Gen.arrayOf(
            Gen.arrayOf(
                Gen.arrayOf(
                    Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
                    within: 1 ... 3
                ),
                within: 1 ... 2
            ),
            within: 1 ... 2
        )

        let composed = Gen.zip(nestedGen, stringGen())

        var iterator = ValueInterpreter(composed, seed: 42, maxRuns: 10)
        var drawn = 0
        while let (nested, _) = try iterator.next() {
            drawn += 1
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
        #expect(drawn == 10)
    }
}
