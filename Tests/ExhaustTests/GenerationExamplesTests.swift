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
        
        @Test("Profile memory allocations")
        func testProfileMemAlloc() throws {
            let generator = String.arbitrary
            var iterator = ValueAndChoiceTreeGenerator(generator, materializePicks: true, seed: 1, maxRuns: 100)
            while let (value, tree) = iterator.next() {
                let value = value
                let tree = tree
            }
//            for n in 1...200 {
//            }
        }
        
        @Test("Test Gen filtering")
        func testGenFiltering() throws {
            let generator = Gen.classify(
                UInt.arbitrary.filter { $0.isMultiple(of: 3) },
                ("even", { n in n % 2 == 0}),
                ("odd", { n in n % 2 != 0}),
            )
            var iterator = ValueAndChoiceTreeGenerator(generator, seed: 1, maxRuns: 100)
            while let (value, _) = iterator.next() {
                #expect(value.isMultiple(of: 3))
            }
        }
        
        @Test("Test Gen subset")
        func testGenSubset() throws {
            let collection = "What in the devil is the purpose of this?"
//            let stringCollection = String(collection)
            let generator = Gen.subset(of: collection)
            var iterator = ValueAndChoiceTreeGenerator(generator, seed: 2, maxRuns: 100)
            var max: Int = 0
            while let (value, _) = iterator.next() {
                // This is a subset
                max = Swift.max(value.count, max)
                #expect(collection.count > value.count)
                // This is a continuous subset, not a sampling
                #expect(collection.contains(value))
            }
            print("max: \(max)")
        }
        
        @Test("Test Gen element")
        func testGenElement() throws {
            let collection = "What in the devil is the purpose of this?"
//            let stringCollection = String(collection)
            let generator = Gen.element(from: collection)
            var iterator = ValueAndChoiceTreeGenerator(generator, seed: 2, maxRuns: 100)
            while let (value, _) = iterator.next() {
                // This is a subset
                // This is a continuous subset, not a sampling
                #expect(collection.contains(value))
            }
        }
        
        @Test("ValueAndChoiceTreeGeneratorDoesntSwallowMaps")
        func testVACTGdoesntswallomaps() throws {
            let gen = UInt.arbitrary.map {
                print("First map called with \($0)")
                return $0
            }.map { second in
                print("Second map called with \(second)")
                return second.description
            }
//            let filtered = Gen.filter(gen, { $0.contains("@") })
            var iterator = ValueAndChoiceTreeGenerator(gen, maxRuns: 2)
            while let (value, tree) = iterator.next() {
                let value = value
                let tree = tree
            }
        }
        
        @Test
        func example2() async throws {
            let gen = Gen.choose(in: 1...5)
            var iterator = ValueGenerator(gen)
            let results = iterator.next()
            let nonNilResults = try #require(results)
            let choices = try Interpreters.reflect(gen, with: nonNilResults, where: { _ in true })
            #expect(choices != nil)
        }
        
        @Test("Test Gen.dictionaryof")
        func testGenDictionaryOf() throws {
            let gen = Gen.dictionaryOf(String.arbitrary, Int.arbitrary)
            let iterator = ValueGenerator(gen)
            let result = try #require(Array(iterator.prefix(2)).last) // Skip the first length=0 response
            let reflection = try #require(try Interpreters.reflect(gen, with: result))
            let replay = try #require(try Interpreters.replay(gen, using: reflection))
            #expect(result == replay)
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
            var iterator = ValueGenerator(zipped)
            let result = iterator.next()!
            let choices = try Interpreters.reflect(zipped, with: result)
            if let choices {
                let replayed = try Interpreters.replay(zipped, using: choices)
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
                var iterator = ValueGenerator(stringGen)
                let generated = iterator.next()!
                if let recipe = try Interpreters.reflect(stringGen, with: generated) {
                    if let replayed = try Interpreters.replay(stringGen, using: recipe) {
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
                var iterator = ValueGenerator(proliferateGen)
                let generated = iterator.next()!
                if let recipe = try Interpreters.reflect(proliferateGen, with: generated) {
                    if let replayed = try Interpreters.replay(proliferateGen, using: recipe) {
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
