//
//  CoreGeneratorTests.swift
//  ExhaustTests
//
//  Core generator functionality tests including Gen factory methods,
//  basic composition, and interpreter consistency.
//

import Testing
@testable import Exhaust

@Suite("Core Generator Functionality")
struct CoreGeneratorTests {
    
    @Suite("Gen Factory Methods")
    struct GenFactoryTests {
        
        @Test("Gen.choose produces values within specified range")
        func testGenChooseRange() {
            let gen = Gen.choose(in: 10...20, input: Any.self)
            
            for _ in 0..<50 {
                let value = Interpreters.generate(gen)!
                #expect(10...20 ~= value)
            }
        }
        
        @Test("Gen.choose with type produces valid values")
        func testGenChooseType() {
            let gen = Gen.choose(type: UInt32.self, input: Any.self)
            
            for _ in 0..<20 {
                let value = Interpreters.generate(gen)!
                #expect(value is UInt32)
            }
        }
        
        @Test("Gen.exact produces exact value and reflects correctly")
        func testGenExact() throws {
            let value = 42
            let gen = Gen.exact(value)
            
            // Test reflection works with exact value
            let recipe = try Interpreters.reflect(gen, with: value)
            #expect(recipe != nil)
            
            // Test reflection fails with different value
            let badRecipe = try Interpreters.reflect(gen, with: 43)
            #expect(badRecipe == nil)
            
            // Test replay
            guard let recipe = recipe else {
                #expect(false, "Reflection failed for Gen.exact test")
                return
            }
            guard let replayed = try Interpreters.replay(gen, using: recipe) else {
                #expect(false, "Replay failed for Gen.exact test")
                return
            }
            #expect(replayed == value)
        }
        
        @Test("Gen.just produces constant value")
        func testGenJust() {
            let value = "constant"
            let gen = Gen.just(value)
            
            for _ in 0..<10 {
                let generated = Interpreters.generate(gen)!
                #expect(generated == value)
            }
        }
        
//        @Test("Empty range handling")
//        func testEmptyRangeHandling() throws {
//            // Single value range
//            let gen = Gen.choose(in: Int(42)...42)
//            
//            for _ in 0..<10 {
//                let value: Int = #require(Interpreters.generate(gen))
//                #expect(value == 42)
//            }
//        }
    }
    
    @Suite("ReflectiveGenerator Tests")
    struct ReflectiveGeneratorTests {
        
        @Test("ReflectiveGenerator.isLens works as intended")
        func testIsLens() {
            let gen = Gen.lens(extract: \String.description, String.arbitrary)
            #expect(gen.isLens == true)
            
            let gen2 = String.arbitrary
            #expect(gen2.isLens == false)
        }
    }
    
    @Suite("Interpreter Consistency")
    struct InterpreterTests {
        
        @Test("Generate-Reflect-Replay cycle consistency")
        func testGenerateReflectReplayConsistency() throws {
            let generators: [ReflectiveGenerator<Any, String>] = [
                String.arbitrary,
                Gen.just("constant")
            ]
            
            for (index, gen) in generators.enumerated() {
                for iteration in 0..<10 {
                    let generated = Interpreters.generate(gen)!
                    if let recipe = try Interpreters.reflect(gen, with: generated) {
                        if let replayed = try Interpreters.replay(gen, using: recipe) {
                            #expect(generated == replayed, "Generator \(index), iteration \(iteration): \(generated) != \(replayed)")
                        } else {
                            #expect(false, "Replay failed for generator \(index), iteration \(iteration)")
                        }
                    } else {
                        #expect(false, "Reflection failed for generator \(index), iteration \(iteration)")
                    }
                }
            }
        }
        
        @Test("Multiple generation consistency")
        func testMultipleGenerationConsistency() throws {
            let gen = Gen.choose(in: 1...100, input: Any.self)
            guard let recipe = try Interpreters.reflect(gen, with: 42) else {
                #expect(false, "Reflection failed for value 42")
                return
            }
            
            // Multiple replays should produce the same result
            for _ in 0..<20 {
                if let replayed = try Interpreters.replay(gen, using: recipe) {
                    #expect(replayed == 42)
                } else {
                    #expect(false, "Replay failed for value 42")
                }
            }
        }
        
        @Test("Expect failure")
        func testOpaqueMapReplayFailure() throws {
            let gen = String.arbitrary
                .proliferate(with: 1...5)
                .map { $0.joined() }
            
            let generated = try #require(Interpreters.generate(gen))
            let reflect = try Interpreters.reflect(gen, with: generated)
            #expect(reflect == nil)
        }
    }
    
    @Suite("Performance Tests")
    struct PerformanceTests {
        
        @Test("High-frequency generation performance")
        func testHighFrequencyGeneration() {
            let gen = Gen.choose(in: 1...1000, input: Any.self)
            
            // Should be able to generate many values quickly
            for _ in 0..<10000 {
                let _ = Interpreters.generate(gen)!
            }
            
            // If we get here without timeout, performance is acceptable
            #expect(true)
        }
    }
}
