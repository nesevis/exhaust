//
//  CompositionTests.swift
//  ExhaustTests
//
//  Tests for generator composition patterns including lens operations,
//  array generation, and complex structure composition.
//

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
            let arrays = #example(arrayGen, count: 20, seed: 42)

            for array in arrays {
                #expect(array.count == 5)
                for element in array {
                    #expect(1 ... 100 ~= element)
                }
            }
        }

        @Test("Arbitrary .array(length:) creates arrays")
        func arbitraryArray() throws {
            let gen = #gen(.int()).array(length: 3 ... 7)
            let arrays = #example(gen, count: 20, seed: 42)

            for array in arrays {
                #expect(3 ... 7 ~= array.count)
            }
        }

        @Test("Nested .array(length:) creates nested arrays")
        func nestedArray() throws {
            let gen = #gen(.string())
                .array(length: 2 ... 4) // Inner arrays of 2-4 strings
                .array(length: 2 ... 3) // Outer array of 2-3 inner arrays

            let nestedArrays = #example(gen, count: 10, seed: 42)

            for nestedArray in nestedArrays {
                #expect(2 ... 3 ~= nestedArray.count)

                for innerArray in nestedArray {
                    #expect(2 ... 4 ~= innerArray.count)
                }
            }
        }

        @Test("Very large arrays round-trip correctly")
        func largeArrays() {
            let gen = #gen(.uint8()).array(length: 1000 ... 1000)
            #examine(gen, samples: 5, seed: 42)
        }

        @Test("Deeply nested structures round-trip correctly")
        func deeplyNestedStructures() {
            // Create a generator for arrays of arrays of arrays
            let gen = #gen(.int())
                .array(length: 2 ... 3) // [Int]
                .array(length: 2 ... 3) // [[Int]]
                .array(length: 2 ... 3) // [[[Int]]]

            #examine(gen, samples: 10, seed: 42)
        }
    }

    @Suite("Choice Generation")
    struct ChoiceTests {
        @Test("oneOf chooses between alternatives")
        func oneOfChoosesBetweenAlternatives() throws {
            let intAsStringGen = #gen(.int(in: 1 ... 10)).map { "\($0)" }

            let choiceGen = #gen(.oneOf(weighted: (1, intAsStringGen), (1, .string())))
            let results = #example(choiceGen, count: 100, seed: 42)

            let sawNumeric = results.contains { Int($0) != nil }
            let sawNonNumeric = results.contains { Int($0) == nil }

            #expect(sawNumeric && sawNonNumeric)
        }

        @Test("oneOf with weighted choices")
        func oneOfWeighted() throws {
            let gen = #gen(.oneOf(weighted: (9, .just("common")), (1, .just("rare"))))
            let results = #example(gen, count: 1000, seed: 42)

            let commonCount = results.count(where: { $0 == "common" })
            let rareCount = results.count(where: { $0 == "rare" })

            // Should be roughly 9:1 ratio
            #expect(commonCount > rareCount * 5) // Allow some variance
        }
    }

    @Suite("Complex Composition")
    struct ComplexCompositionTests {
        @Test("Complex company structure round-trips correctly")
        func complexComposition() {
            let personGen = #gen(.just("Bill Gates"), .int(in: 18 ... 65), .double(in: 150.0 ... 200.0)) { name, age, height in
                TestPerson(name: name, age: age, height: height)
            }

            let companyGen = #gen(.just("Microsoft"), personGen.array(length: 5 ... 20), .int(in: 1900 ... 2023)) { name, employees, founded in
                TestCompany(name: name, employees: employees, founded: founded)
            }

            #examine(companyGen, samples: 20, seed: 42)
        }

        @Test("Complex generator composition stability", .disabled("This is weird. Check why this fails"))
        func complexGeneratorStability() {
            // Build a very complex generator with multiple composition patterns
            let nestedGen = #gen(.int(in: 1 ... 100)).array(length: 1 ... 10).array(length: 1 ... 5)
            let pickedGen = #gen(.oneOf(weighted:
                (1, nestedGen),
                (1, nestedGen.mapped(forward: { $0.reversed() }, backward: { $0.reversed() }))))

            #examine(pickedGen, samples: 100, seed: 42)
        }
    }

    @Suite("Bound tests")
    struct BoundTests {
        @Test("bound generates correct values in forward direction")
        func boundForwardGeneration() throws {
            // Generate an int n, then use it to produce an array of n zeros
            let gen = #gen(.int(in: 1 ... 5))
                .bound(
                    forward: { n in .just(Array(repeating: 0, count: n)) },
                    backward: { (arr: [Int]) in arr.count }
                )

            let values = #example(gen, count: 20, seed: 42)
            for value in values {
                #expect((1 ... 5).contains(value.count))
                #expect(value.allSatisfy { $0 == 0 })
            }
        }

        @Test("bound validates successfully")
        func boundValidates() {
            let gen = #gen(.int(in: 1 ... 5))
                .bound(
                    forward: { n in .just(Array(repeating: 0, count: n)) },
                    backward: { (arr: [Int]) in arr.count }
                )

            #examine(gen, samples: 50, seed: 42)
        }

        @Test("bound with dependent generator works in forward direction")
        func boundDependentGenerator() throws {
            // Generate a max value, then generate an int within that range
            let gen = #gen(.int(in: 10 ... 20)).bound(
                forward: { max in #gen(.int(in: 0 ... max)) },
                backward: { (_: Int) in 15 } // conservative: always claim max was 15
            )

            // Forward generation should work
            let values = #example(gen, count: 20, seed: 42)
            for value in values {
                #expect(value >= 0)
            }
        }
    }

    @Suite("Zip tests")
    struct ZipTests {
        @Test("Test zip implicit lensing composes with mapped")
        func bizipIsReplayable2() {
            struct Thing: Equatable {
                let a: Int
                let b: String
                let c: Bool
            }

            let gen = #gen(.int(), .string(), .bool()) { a, b, c in
                Thing(a: a, b: b, c: c)
            }
            #examine(gen, samples: 20, seed: 42)
        }

        @Test("Test bimap is replayable")
        func bimapIsReplayable() {
            let gen = #gen(.int()).mapped(
                forward: { $0.bitPattern64 },
                backward: { Int(bitPattern64: $0) }
            )

            #examine(gen, samples: 20, seed: 42)
        }
    }
}
