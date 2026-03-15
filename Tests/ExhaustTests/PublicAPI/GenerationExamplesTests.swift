//
//  GenerationExamplesTests.swift
//  ExhaustTests
//
//  Example tests demonstrating basic generation patterns and edge cases.
//

import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Generation Examples")
struct GenerationExamplesTests {
    @Suite("Basic Examples")
    struct BasicExampleTests {
        @Test("Profile memory allocations")
        func profileMemAlloc() throws {
            let generator = #gen(.string())
            var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 1, maxRuns: 100)
            while let (value, tree) = try iterator.next() {
                let value = value
                let tree = tree
            }
//            for n in 1...200 {
//            }
        }

        @Test("Test Gen filtering")
        func genFiltering() throws {
            let generator = #gen(.uint())
                .filter { $0.isMultiple(of: 3) }
                .classify(
                    ("even", { n in n % 2 == 0 }),
                    ("odd", { n in n % 2 != 0 }),
                )
            var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 1, maxRuns: 100)
            while let (value, _) = try iterator.next() {
                #expect(value.isMultiple(of: 3))
            }
        }

        @Test("Test Gen slice")
        func genSlice() throws {
            let collection = "What in the devil is the purpose of this?"
//            let stringCollection = String(collection)
            let generator = Gen.slice(of: collection)
            var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 2, maxRuns: 100)
            var max = 0
            while let (value, _) = try iterator.next() {
                // This is a subset
                max = Swift.max(value.count, max)
                #expect(collection.count > value.count)
                // This is a continuous subset, not a sampling
                #expect(collection.contains(value))
            }
        }

        @Test("Test Gen element")
        func genElement() throws {
            let collection = "What in the devil is the purpose of this?"
//            let stringCollection = String(collection)
            let generator = Gen.element(from: collection)
            var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 2, maxRuns: 100)
            while let (value, _) = try iterator.next() {
                // This is a subset
                // This is a continuous subset, not a sampling
                #expect(collection.contains(value))
            }
        }

        @Test("ValueAndChoiceTreeGeneratorDoesntSwallowMaps")
        func vACTGdoesntswallomaps() throws {
            let gen = #gen(.uint()).map(\.self).map { second in
                second.description
            }
//            let filtered = Gen.filter(gen, { $0.contains("@") })
            var iterator = ValueAndChoiceTreeInterpreter(gen, maxRuns: 2)
            while let (value, tree) = try iterator.next() {
                let value = value
                let tree = tree
            }
        }

        @Test
        func example2() throws {
            let gen = #gen(.int(in: 1 ... 5))
            var iterator = ValueInterpreter(gen)
            let results = try iterator.next()
            let nonNilResults = try #require(results)
            let choices = try Interpreters.reflect(gen, with: nonNilResults, where: { _ in true })
            #expect(choices != nil)
        }

        @Test("Test Gen.dictionaryof")
        func genDictionaryOf() throws {
            let gen = #gen(.dictionary(.string(), .int()))
            var iterator = ValueInterpreter(gen)
            let result = try #require(iterator.prefix(2).last) // Skip the first length=0 response
            let reflection = try #require(try Interpreters.reflect(gen, with: result))
            let replay = try #require(try Interpreters.replay(gen, using: reflection))
            #expect(result == replay)
        }

        @Test
        func example3() throws {
            struct Person: Equatable {
                let age: Int
                let height: Double
            }
            let zipped = #gen(.int(in: 0 ... 150), .double(in: 120.0 ... 180.0)) { age, height in
                Person(age: age, height: height)
            }
            var iterator = ValueInterpreter(zipped)
            let result = try iterator.next()!
            let choices = try Interpreters.reflect(zipped, with: result)
            if let choices {
                let replayed = try Interpreters.replay(zipped, using: choices)
                if let replayed {
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
        @Test("Debug array step by step")
        func debugArrayStepByStep() throws {
            // 1. Test #gen(.string()) alone
            let stringGen = #gen(.string())
            for i in 0 ..< 3 {
                var iterator = ValueInterpreter(stringGen)
                let generated = try iterator.next()!
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

            // 2. Test array alone (without map)
            let arrayGen = #gen(.string()).array(length: 1 ... 3)
            for i in 0 ..< 3 {
                var iterator = ValueInterpreter(arrayGen)
                let generated = try iterator.next()!
                if let recipe = try Interpreters.reflect(arrayGen, with: generated) {
                    if let replayed = try Interpreters.replay(arrayGen, using: recipe) {
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
