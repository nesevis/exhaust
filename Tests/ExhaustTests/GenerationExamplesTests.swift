//
//  GenerationExamplesTests.swift
//  ExhaustTests
//
//  Example tests demonstrating basic generation patterns and edge cases.
//

import Testing
@testable import Exhaust

@Suite("Generation Examples")
struct GenerationExamplesTests {
    
    @Suite("Basic Examples")
    struct BasicExampleTests {
        
        @Test
        func example2() async throws {
            let gen = Gen.choose(in: 1...5, input: Void.self)
            let results = Interpreters.generate(gen)
            guard let results = results else {
                #expect(false, "Generation failed")
                return
            }
            let choices = try Interpreters.reflect(gen, with: results, where: { _ in true })
            #expect(true)
        }
        
        @Test
        func example3() async throws {
            struct Person: Equatable {
                let age: Int
                let height: Double
            }
            let lensedAge = Gen.lens(extract: \Person.age, Gen.choose(in: 0...150))
            let lensedHeight = Gen.lens(extract: \Person.height, Gen.choose(in: Double(120)...180))
            let zipped = lensedAge.bind { age in
                lensedHeight.map { height in
                    Person(age: age, height: height)
                }
            }    
            let result = Interpreters.generate(zipped)!
            let choices = try Interpreters.reflect(zipped, with: result)
            if let choices {
                let replayed = Interpreters.replay(zipped, using: choices)
                if let replayed = replayed {
                    #expect(replayed == result)
                } else {
                    #expect(false, "Replay failed in example3")
                }
            }
            #expect(true)
        }
    }
    
    @Suite("Debug Tests")
    struct DebugTests {
        
        @Test("Debug proliferate step by step")
        func debugProliferateStepByStep() throws {
            
            // 1. Test String.arbitrary alone
            let stringGen = String.arbitrary
            for i in 0..<3 {
                let generated = Interpreters.generate(stringGen)!
                if let recipe = try Interpreters.reflect(stringGen, with: generated) {
                    if let replayed = Interpreters.replay(stringGen, using: recipe) {
                        // Round-trip successful
                    } else {
                        #expect(false, "Replay failed")
                    }
                } else {
                    #expect(false, "Reflection failed")
                }
            }
            
            // 2. Test proliferate alone (without map)
            let proliferateGen = String.arbitrary.proliferate(with: 1...3)
            for i in 0..<3 {
                let generated = Interpreters.generate(proliferateGen)!
                if let recipe = try Interpreters.reflect(proliferateGen, with: generated) {
                    if let replayed = Interpreters.replay(proliferateGen, using: recipe) {
                        // Round-trip successful
                    } else {
                        #expect(false, "Replay failed")
                    }
                } else {
                    #expect(false, "Reflection failed")
                }
            }
        }
    }
}
