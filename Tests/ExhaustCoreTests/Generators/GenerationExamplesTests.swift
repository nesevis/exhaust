//
//  GenerationExamplesTests.swift
//  ExhaustTests
//
//  Example tests demonstrating basic generation patterns and edge cases.
//

import ExhaustCore
import Testing

@Suite("Generation Examples")
struct GenerationExamplesTests {
    @Suite("Basic Examples")
    struct BasicExampleTests {
        @Test("Profile memory allocations")
        func profileMemAlloc() throws {
            let generator = stringGen()
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
            let innerGen = Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling)
            let filteredGen: ReflectiveGenerator<UInt> = .impure(
                operation: .filter(
                    gen: innerGen.erase(),
                    fingerprint: 0,
                    filterType: .auto,
                    predicate: { ($0 as! UInt).isMultiple(of: 3) },
                    sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
                ),
                continuation: { .pure($0 as! UInt) }
            )
            let generator = Gen.classify(
                filteredGen,
                ("even", { n in n % 2 == 0 }),
                ("odd", { n in n % 2 != 0 })
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
            let gen = Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling)._map { $0 }._map { second in
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
            let gen = Gen.choose(in: 1 ... 5) as ReflectiveGenerator<Int>
            var iterator = ValueInterpreter(gen)
            let results = try iterator.next()
            let nonNilResults = try #require(results)
            let choices = try Interpreters.reflect(gen, with: nonNilResults, where: { _ in true })
            #expect(choices != nil)
        }

        @Test("Test Gen.dictionaryof")
        func genDictionaryOf() throws {
            let gen = Gen.dictionaryOf(stringGen(), Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling))
            var iterator = ValueInterpreter(gen)
            let result = try #require(iterator.prefix(2).last) // Skip the first length=0 response
            let reflection = try #require(try Interpreters.reflect(gen, with: result))
            let replay = try #require(try Interpreters.replay(gen, using: reflection))
            #expect(result == replay)
        }
    }

    @Suite("Debug Tests")
    struct DebugTests {
        @Test("Debug array step by step")
        func debugArrayStepByStep() throws {
            // 1. Test #gen(.string()) alone
            let singleStringGen = stringGen()
            for i in 0 ..< 3 {
                var iterator = ValueInterpreter(singleStringGen)
                let generated = try iterator.next()!
                if let recipe = try Interpreters.reflect(singleStringGen, with: generated) {
                    if let replayed = try Interpreters.replay(singleStringGen, using: recipe) {
                        // Round-trip successful
                    } else {
                        #expect(false, "Replay failed")
                    }
                } else {
                    #expect(false, "Reflection failed")
                }
            }

            // 2. Test array alone (without map)
            let arrayGen = Gen.arrayOf(stringGen(), within: UInt64(1) ... 3)
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
