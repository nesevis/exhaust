//
//  CompositionTests.swift
//  ExhaustTests
//
//  Tests for generator composition patterns including lens operations,
//  array generation, and complex structure composition.
//

import ExhaustCore
import Testing
@testable import Exhaust

// MARK: - Test Structures

struct TestPerson: Equatable {
    let name: String
    let age: Int
    let height: Double
}

struct TestCompany: Equatable {
    let name: String
    let employees: [TestPerson]
    let founded: Int
}

struct TestPoint: Equatable {
    let x: Double
    let y: Double
}

struct TestRectangle: Equatable {
    let topLeft: TestPoint
    let bottomRight: TestPoint
}

@Suite("Generator Composition")
struct CompositionTests {
    @Suite("Array Generation")
    struct ArrayTests {
        @Test("Array generator creates arrays of specified size")
        func arrayOfFixedLength() throws {
            let arrayGen = #gen(.int(in: 1 ... 100)).array(length: 5)

            for _ in 0 ..< 20 {
                var iterator = ValueInterpreter(arrayGen)
                let array = try iterator.next()!
                #expect(array.count == 5)
                for element in array {
                    #expect(1 ... 100 ~= element)
                }
            }
        }

        @Test("Arbitrary .array(length:) creates arrays")
        func arbitraryArray() throws {
            let gen = #gen(.int()).array(length: 3 ... 7)

            for _ in 0 ..< 20 {
                var iterator = ValueInterpreter(gen)
                let array = try iterator.next()!
                #expect(3 ... 7 ~= array.count)
            }
        }

        @Test("Nested .array(length:) creates nested arrays")
        func nestedArray() throws {
            let gen = #gen(.string())
                .array(length: 2 ... 4) // Inner arrays of 2-4 strings
                .array(length: 2 ... 3) // Outer array of 2-3 inner arrays

            for _ in 0 ..< 10 {
                var iterator = ValueInterpreter(gen)
                let nestedArray = try iterator.next()!
                #expect(2 ... 3 ~= nestedArray.count)

                for innerArray in nestedArray {
                    #expect(2 ... 4 ~= innerArray.count)
                }
            }
        }

        @Test("Very large arrays")
        func largeArrays() throws {
            let gen = #gen(.uint8()).array(length: 1000 ... 1000)

            var iterator = ValueInterpreter(gen)
            let largeArray = try iterator.next()!
            #expect(largeArray.count == 1000)

            // Should still support round-trip
            if let recipe = try Interpreters.reflect(gen, with: largeArray) {
                if let replayed = try Interpreters.replay(gen, using: recipe) {
                    #expect(largeArray == replayed)
                } else {
                    #expect(false, "Replay failed for large array")
                }
            } else {
                #expect(false, "Reflection failed for large array")
            }
        }

        @Test("Deeply nested structures")
        func deeplyNestedStructures() throws {
            // Create a generator for arrays of arrays of arrays
            let gen = #gen(.int())
                .array(length: 2 ... 3) // [Int]
                .array(length: 2 ... 3) // [[Int]]
                .array(length: 2 ... 3) // [[[Int]]]

            var iterator = ValueInterpreter(gen)
            let nested = try iterator.next()!

            // Validate structure
            #expect(2 ... 3 ~= nested.count)
            for level1 in nested {
                #expect(2 ... 3 ~= level1.count)
                for level2 in level1 {
                    #expect(2 ... 3 ~= level2.count)
                }
            }

            // Test round-trip
            if let recipe = try Interpreters.reflect(gen, with: nested) {
                if let replayed = try Interpreters.replay(gen, using: recipe) {
                    #expect(nested == replayed)
                } else {
                    #expect(false, "Replay failed for deeply nested structure")
                }
            } else {
                #expect(false, "Reflection failed for deeply nested structure")
            }
        }
    }

    @Suite("Choice Generation")
    struct ChoiceTests {
        @Test("oneOf chooses between alternatives")
        func oneOfChoosesBetweenAlternatives() throws {
            let intAsStringGen = #gen(.int(in: 1 ... 10)).map { "\($0)" }

            let choiceGen = #gen(.oneOf(weighted: (1, intAsStringGen), (1, .string())))

            var sawNumeric = false
            var sawNonNumeric = false

            for _ in 0 ..< 100 {
                var iterator = ValueInterpreter(choiceGen)
                let result = try iterator.next()!

                if Int(result) != nil {
                    sawNumeric = true
                } else {
                    sawNonNumeric = true
                }

                if sawNumeric, sawNonNumeric { break }
            }

            #expect(sawNumeric && sawNonNumeric)
        }

        @Test("oneOf with weighted choices")
        func oneOfWeighted() throws {
            let gen = #gen(.oneOf(weighted: (9, .just("common")), (1, .just("rare"))))

            var commonCount = 0
            var rareCount = 0

            for _ in 0 ..< 1000 {
                var iterator = ValueInterpreter(gen)
                let result = try iterator.next()!
                if result == "common" {
                    commonCount += 1
                } else {
                    rareCount += 1
                }
            }

            // Should be roughly 9:1 ratio
            #expect(commonCount > rareCount * 5) // Allow some variance
        }
    }

    @Suite("Complex Composition")
    struct ComplexCompositionTests {
        @Test("Complex company structure with nested generators")
        func complexComposition() throws {
            let personGen = #gen(.just("Bill Gates"), .int(in: 18 ... 65), .double(in: 150.0 ... 200.0)) { name, age, height in
                TestPerson(name: name, age: age, height: height)
            }

            let companyGen = #gen(.just("Microsoft"), personGen.array(length: 5 ... 20), .int(in: 1900 ... 2023)) { name, employees, founded in
                TestCompany(name: name, employees: employees, founded: founded)
            }

            var iterator = ValueInterpreter(companyGen)
            let company = try iterator.next()!

            // Test round-trip
            if let recipe = try Interpreters.reflect(companyGen, with: company) {
                if let replayed = try Interpreters.replay(companyGen, using: recipe) {
                    #expect(company == replayed)
                } else {
                    #expect(false, "Replay failed for company")
                }
            } else {
                #expect(false, "Reflection failed for company")
            }
        }

        @Test("Complex generator composition stability")
        func complexGeneratorStability() throws {
            // Build a very complex generator with multiple composition patterns
            let nestedGen = #gen(.int(in: 1 ... 100)).array(length: 1 ... 10).array(length: 1 ... 5)
            let pickedGen = #gen(.oneOf(weighted:
                (1, nestedGen),
                (1, nestedGen.mapped(forward: { $0.reversed() }, backward: { $0.reversed() }))))

            // Generate many values to test stability
            for iteration in 0 ..< 100 {
                var iterator = ValueInterpreter(pickedGen)
                let generated = try iterator.next()!
                if let recipe = try Interpreters.reflect(pickedGen, with: generated) {
                    if let replayed = try Interpreters.replay(pickedGen, using: recipe) {
                        #expect(generated == replayed, "Failed at iteration \(iteration)")
                    } else {
                        #expect(false, "Replay failed at iteration \(iteration)")
                    }
                } else {
                    #expect(false, "Reflection failed at iteration \(iteration)")
                }
            }
        }
    }

    @Suite("Zip tests")
    struct ZipTests {
        @Test("Test zip implicit lensing composes with mapped")
        func bizipIsReplayable2() throws {
            struct Thing: Equatable {
                let a: Int
                let b: String
                let c: Bool
            }

            let gen = #gen(.int(), .string(), .bool()) { a, b, c in
                Thing(a: a, b: b, c: c)
            }
            _ = try validateGenerator(gen)
        }

        @Test("Test bimap is replayable")
        func bimapIsReplayable() throws {
            let gen = #gen(.int()).mapped(
                forward: { $0.bitPattern64 },
                backward: { Int(bitPattern64: $0) },
            )

            var iterator = ValueInterpreter(gen)
            let instance = try iterator.next()!
            let recipe = try #require(try Interpreters.reflect(gen, with: instance))
            let replay = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(instance == replay)
        }
    }
}
