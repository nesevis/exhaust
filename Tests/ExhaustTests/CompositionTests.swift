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
    
    @Suite("Lens Composition")
    struct LensTests {
        @Test("Simple generator with transform inside bind")
        func testSimpleGeneratorWithOpaqueTransform() throws {
            // We can still reflect this
            let gen = UInt64.arbitrary.bind { int in
                // When reflecting, this will be called again, so the resize parameter will be wrong as
                // First time (generate) 1 (+1 * 11)
                // Second time (reflect) 12 (+ 1 * 11)
                // We can't reverse this transformation, so we should hide the resize parameter?
                Gen.arrayOf(String.arbitrary, exactly: int + 1 * 11)
            }
            
            var iterator = ValueGenerator(gen)
            let generated = iterator.next()!
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with nested structures")
        func testNestedLens() throws {
            let pointGen = Gen.lens(extract: \TestPoint.x, Gen.choose(in: 0.0...100.0))
                .bind { x in
                    Gen.lens(extract: \TestPoint.y, Gen.choose(in: 0.0...100.0)).map { y in
                        TestPoint(x: x, y: y)
                    }
                }
            
            let rectGen = Gen.lens(extract: \TestRectangle.topLeft, pointGen)
                .bind { topLeft in
                    Gen.lens(extract: \TestRectangle.bottomRight, pointGen).map { bottomRight in
                        TestRectangle(topLeft: topLeft, bottomRight: bottomRight)
                    }
                }
            
            var iterator = ValueGenerator(rectGen)
            let rect = iterator.next()!
            
            // Test round-trip
            if let recipe = try Interpreters.reflect(rectGen, with: rect) {
                if let replayed = try Interpreters.replay(rectGen, using: recipe) {
                    #expect(rect == replayed)
                } else {
                    #expect(false, "Replay failed for rectangle")
                }
            } else {
                #expect(false, "Reflection failed for rectangle")
            }
        }
    }
    
    @Suite("Array Generation")
    struct ArrayTests {
        
        @Test("Gen.arrayOf creates arrays of specified size")
        func testGenArrayOf() {
            let elementGen = Gen.choose(in: 1...100)
            let lengthGen = Gen.just(UInt64(5))
            let arrayGen = Gen.arrayOf(elementGen, lengthGen)
            
            for _ in 0..<20 {
                var iterator = ValueGenerator(arrayGen)
                let array = iterator.next()!
                #expect(array.count == 5)
                for element in array {
                    #expect(1...100 ~= element)
                }
            }
        }
        
        @Test("Arbitrary.proliferate creates arrays")
        func testArbitraryProliferate() {
            let gen = Int.arbitrary.proliferate(with: 3...7)
            
            for _ in 0..<20 {
                var iterator = ValueGenerator(gen)
                let array = iterator.next()!
                #expect(3...7 ~= array.count)
            }
        }
        
        @Test("Nested proliferate creates nested arrays")
        func testNestedProliferate() {
            let gen = String.arbitrary
                .proliferate(with: 2...4)  // Inner arrays of 2-4 strings
                .proliferate(with: 2...3)  // Outer array of 2-3 inner arrays
            
            for _ in 0..<10 {
                var iterator = ValueGenerator(gen)
                let nestedArray = iterator.next()!
                #expect(2...3 ~= nestedArray.count)
                
                for innerArray in nestedArray {
                    #expect(2...4 ~= innerArray.count)
                }
            }
        }
        
        @Test("Very large arrays")
        func testLargeArrays() throws {
            let gen = UInt8.arbitrary.proliferate(with: 1000...1000)
            
            var iterator = ValueGenerator(gen)
            let largeArray = iterator.next()!
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
        func testDeeplyNestedStructures() throws {
            // Create a generator for arrays of arrays of arrays
            let gen = Int.arbitrary
                .proliferate(with: 2...3)    // [Int]
                .proliferate(with: 2...3)    // [[Int]]
                .proliferate(with: 2...3)    // [[[Int]]]
            
            var iterator = ValueGenerator(gen)
            let nested = iterator.next()!
            
            // Validate structure
            #expect(2...3 ~= nested.count)
            for level1 in nested {
                #expect(2...3 ~= level1.count)
                for level2 in level1 {
                    #expect(2...3 ~= level2.count)
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
        
        @Test("Gen.pick chooses between alternatives")
        func testGenPick() {
            let intGen = Gen.choose(in: 1...10)
            let stringGen = String.arbitrary
            
            let choiceGen = Gen.pick(choices: [
                (weight: UInt64(1), generator: intGen.map { "\($0)" }),
                (weight: UInt64(1), generator: stringGen)
            ])
            
            var sawNumeric = false
            var sawNonNumeric = false
            
            for _ in 0..<100 {
                var iterator = ValueGenerator(choiceGen)
                let result = iterator.next()!
                
                if Int(result) != nil {
                    sawNumeric = true
                } else {
                    sawNonNumeric = true
                }
                
                if sawNumeric && sawNonNumeric { break }
            }
            
            #expect(sawNumeric && sawNonNumeric)
        }
        
        @Test("Gen.pick with weighted choices")
        func testGenPickWeighted() {
            let gen = Gen.pick(choices: [
                (weight: UInt64(9), generator: Gen.just("common")),
                (weight: UInt64(1), generator: Gen.just("rare"))
            ])
            
            var commonCount = 0
            var rareCount = 0
            
            for _ in 0..<1000 {
                var iterator = ValueGenerator(gen)
                let result = iterator.next()!
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
        func testComplexComposition() throws {
            let personGen = Gen.lens(extract: \TestPerson.name, Gen.just("Bill Gates"))
                .bind { name in
                    Gen.lens(extract: \TestPerson.age, Gen.choose(in: 18...65))
                        .bind { age in
                            Gen.lens(extract: \TestPerson.height, Gen.choose(in: 150.0...200.0))
                                .map { height in
                                    TestPerson(name: name, age: age, height: height)
                                }
                        }
                }
            
            let companyGen = Gen.lens(extract: \TestCompany.name, Gen.just("Microsoft"))
                .bind { name in
                    Gen.lens(extract: \TestCompany.employees, personGen.proliferate(with: 5...20))
                        .bind { employees in
                            Gen.lens(extract: \TestCompany.founded, Gen.choose(in: 1900...2023))
                                .map { founded in
                                    TestCompany(name: name, employees: employees, founded: founded)
                                }
                        }
                }
            
            var iterator = ValueGenerator(companyGen)
            let company = iterator.next()!
            
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
        func testComplexGeneratorStability() throws {
            // Build a very complex generator with multiple composition patterns
            let baseGen = Gen.choose(in: 1...100)
            let arrayGen = baseGen.proliferate(with: 1...10)
            let nestedGen = arrayGen.proliferate(with: 1...5)
            let pickedGen = Gen.pick(choices: [
                (weight: UInt64(1), generator: nestedGen),
                (weight: UInt64(1), generator: nestedGen.map { $0.reversed() })
            ])
            
            // Generate many values to test stability
            for iteration in 0..<100 {
                var iterator = ValueGenerator(pickedGen)
                let generated = iterator.next()!
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
        func testBizipIsReplayable2() throws {
            struct Thing: Equatable {
                let a: Int
                let b: String
                let c: Bool
            }
            
            // Gen.zip will lens each generator into its position in the tuple
            let gen = Gen.zip(Int.arbitrary, String.arbitrary, Bool.arbitrary)
            .mapped(
                forward: { Thing(a: $0.0, b: $0.1, c: $0.2) },
                backward: { ($0.a, $0.b, $0.c) }
            )
            let (recipe, instance) = try validateGenerator(gen)
            print()
        }
        
        @Test("Test bimap is replayable")
        func testBimapIsReplayable() throws {
            let gen = Int.arbitrary.mapped(
                forward: { $0.bitPattern64 },
                backward: { Int(bitPattern64: $0) }
            )
            
            var iterator = ValueGenerator(gen)
            let instance = iterator.next()!
            let recipe = try #require(try Interpreters.reflect(gen, with: instance))
            let replay = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(instance == replay)
        }
    }
}
