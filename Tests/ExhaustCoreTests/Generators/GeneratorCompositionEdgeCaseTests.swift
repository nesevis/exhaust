//
//  GeneratorCompositionEdgeCaseTests.swift
//  ExhaustTests
//
//  Tests for edge cases in generator composition including empty generators,
//  single-value generators, and complex composition scenarios.
//

import Testing
@testable import ExhaustCore

@Suite("Generator Composition Edge Cases")
struct GeneratorCompositionEdgeCaseTests {
    @Test("Single value generator composition")
    func singleValueGeneratorComposition() throws {
        let constantGen = Gen.just(42)
        let normalGen = stringGen()

        let composed = Gen.zip(constantGen, normalGen)

        // Generate multiple values
        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (constant, string) = try iterator.next()!
            #expect(constant == 42) // Constant should always be the same
            // String can be anything
        }
    }

    @Test("Zipping many generators maintains correctness")
    func largeZipComposition() throws {
        let gen = Gen.zip(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            stringGen(),
            Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling),
            Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: Double.defaultScaling),
            Gen.choose(in: 1 ... 100) as ReflectiveGenerator<Int>
        )

        // Verify all components are generated correctly
        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(gen)
            let (int, string, uint, double, ranged) = try iterator.next()!

            // Type checking ensures correctness, but verify range constraint
            #expect(ranged >= 1)
            #expect(ranged <= 100)
        }
    }

    @Test("Nested composition with multiple levels")
    func nestedCompositionLevels() throws {
        let innerGen = Gen.zip(
            Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling),
            stringGen()
        )
        let middleGen = Gen.zip(innerGen, boolGen())
        let outerGen = Gen.zip(middleGen, Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling))

        var iterator = ValueInterpreter(outerGen)
        let nestedTuple = try iterator.next()!
        // TOOD: write #expects

        // All values should be generated successfully
        // Type system ensures correctness
    }

    @Test("Empty array generator in composition")
    func emptyArrayGeneratorComposition() throws {
        let emptyArrayGen = Gen.just([Int]())
        let normalGen = stringGen()

        let composed = Gen.zip(emptyArrayGen, normalGen)

        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (emptyArray, _) = try iterator.next()!
            #expect(emptyArray.isEmpty)
        }
    }

    @Test("Composition with bound generators")
    func boundGeneratorComposition() throws {
        let dependentGen = (Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling) as ReflectiveGenerator<Int>).bind { first in
            Gen.choose(in: first ... (first + 10)).map { second in
                (first, second)
            }
        }

        let independentGen = stringGen()
        let composed = Gen.zip(dependentGen, independentGen)

        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(composed)
            let ((first, second), _) = try iterator.next()!
            #expect(second >= first)
            #expect(second <= first + 10)
        }
    }

    @Test("Composition preserves replay behavior")
    func compositionReplayBehavior() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1 ... 100) as ReflectiveGenerator<Int>,
            stringGen(),
            boolGen()
        )

        var iterator = ValueInterpreter(gen)
        let generated = try iterator.next()!
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

        for _ in 0 ..< 20 {
            var iterator = ValueInterpreter(composed)
            let (array, string) = try iterator.next()!
            #expect(array.count >= 0) // swiftlint:disable:this empty_count
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

        for _ in 0 ..< 10 {
            var iterator = ValueInterpreter(composed)
            let (nested, string) = try iterator.next()!

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
