//
//  GeneratorCompositionEdgeCaseTests.swift
//  ExhaustTests
//
//  Tests for edge cases in generator composition including empty generators,
//  single-value generators, and complex composition scenarios.
//

import Testing
@testable import Exhaust

@Suite("Generator Composition Edge Cases")
struct GeneratorCompositionEdgeCaseTests {
    
    @Test("Single value generator composition")
    func testSingleValueGeneratorComposition() throws {
        let constantGen = Gen.just(42)
        let normalGen = String.arbitrary
        
        let composed = Gen.zip(constantGen, normalGen)
        
        // Generate multiple values
        for _ in 0..<10 {
            let (constant, string) = try #require(Interpreters.generate(composed))
            #expect(constant == 42) // Constant should always be the same
            // String can be anything
        }
    }
    
    @Test("Zipping many generators maintains correctness")
    func testLargeZipComposition() throws {
        let gen = Gen.zip(
            Int.arbitrary,
            String.arbitrary,
            UInt.arbitrary,
            Double.arbitrary,
            Gen.choose(in: 1...100, input: Any.self)
        )
        
        // Verify all components are generated correctly
        for _ in 0..<20 {
            let (int, string, uint, double, ranged) = try #require(Interpreters.generate(gen))
            
            // Type checking ensures correctness, but verify range constraint
            #expect(ranged >= 1)
            #expect(ranged <= 100)
        }
    }
    
    @Test("Nested composition with multiple levels")
    func testNestedCompositionLevels() throws {
        let innerGen = Gen.zip(Int.arbitrary, String.arbitrary)
        let middleGen = Gen.zip(innerGen, Bool.arbitrary)
        let outerGen = Gen.zip(middleGen, UInt.arbitrary)
        
        let nestedTuple = try #require(Interpreters.generate(outerGen))
        // TOOD: write #expects
        
        // All values should be generated successfully
        // Type system ensures correctness
    }
    
    @Test("Empty array generator in composition")
    func testEmptyArrayGeneratorComposition() throws {
        let emptyArrayGen = Gen.just([Int]())
        let normalGen = String.arbitrary
        
        let composed = Gen.zip(emptyArrayGen, normalGen)
        
        for _ in 0..<10 {
            let (emptyArray, _) = try #require(Interpreters.generate(composed))
            #expect(emptyArray.isEmpty)
        }
    }
    
    @Test("Composition with bound generators")
    func testBoundGeneratorComposition() throws {
        let dependentGen = Int.arbitrary.bind { first in
            Gen.choose(in: first...(first + 10), input: Any.self).map { second in
                (first, second)
            }
        }
        
        let independentGen = String.arbitrary
        let composed = Gen.zip(dependentGen, independentGen)
        
        for _ in 0..<20 {
            let ((first, second), _) = try #require(Interpreters.generate(composed))
            #expect(second >= first)
            #expect(second <= first + 10)
        }
    }
    
    @Test("Composition preserves replay behavior")
    func testCompositionReplayBehavior() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1...100, input: Any.self),
            String.arbitrary,
            Bool.arbitrary
        )
        
        let generated = try #require(Interpreters.generate(gen))
        let recipe = try #require(Interpreters.reflect(gen, with: generated))
        let replayed = try #require(Interpreters.replay(gen, using: recipe))
        
        #expect(generated == replayed)
    }
    
    @Test("Composition with array proliferation")
    func testArrayProlifirationComposition() throws {
        let arrayGen = Int.arbitrary.proliferate(with: 0...5)
        let scalarGen = String.arbitrary
        
        let composed = Gen.zip(arrayGen, scalarGen)
        
        for _ in 0..<20 {
            let (array, string) = try #require(Interpreters.generate(composed))
            #expect(array.count >= 0)
            #expect(array.count <= 5)
        }
    }
    
    @Test("Deeply nested array composition")
    func testDeeplyNestedArrayComposition() throws {
        let nestedGen = Int.arbitrary
            .proliferate(with: 1...3)
            .proliferate(with: 1...2)
            .proliferate(with: 1...2)
        
        let composed = Gen.zip(nestedGen, String.arbitrary)
        
        for _ in 0..<10 {
            let (nested, string) = try #require(Interpreters.generate(composed))
            
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
