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
        
        @Test("Gen.lens with simple property extraction")
        func testSimpleLens() throws {
            let nameGen = Gen.lens(extract: \TestPerson.name, String.arbitrary)
            let ageGen = Gen.lens(extract: \TestPerson.age, Gen.choose(in: 0...100))
            let heightGen = Gen.lens(extract: \TestPerson.height, Gen.choose(in: 150.0...200.0))
            
            let personGen = nameGen.bind { name in
                ageGen.bind { age in
                    heightGen.map { height in
                        TestPerson(name: name, age: age, height: height)
                    }
                }
            }
            
            // Test generation
            let person = Interpreters.generate(personGen)!
            #expect(person.age >= 0 && person.age <= 100)
            #expect(person.height >= 150.0 && person.height <= 200.0)
            
            // Test round-trip: generate -> reflect -> replay
            if let recipe = try Interpreters.reflect(personGen, with: person) {
                if let replayed = try Interpreters.replay(personGen, using: recipe) {
                    #expect(person == replayed)
                } else {
                    #expect(false, "Replay failed for person")
                }
            } else {
                #expect(false, "Reflection failed for person")
            }
        }
        
        @Test("Gen.lens with zip of two values")
        func testLensWithZip() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo")
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of two values, themselves lenses")
        func testLensWithZippedLenses() throws {
            struct Apple: Equatable {
                let color: String
                let weight: Int
            }
            let gen = Gen.zip(
                Gen.lens(extract: \Apple.color, String.arbitrary),
                Gen.lens(extract: \Apple.weight, Int.arbitrary)
            ).map { (color, weight) in Apple(color: color, weight: weight) }
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of three values")
        func testLensWithZip3() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of four values")
        func testLensWithZip4() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of five values")
        func testLensWithZip5() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of six values")
        func testLensWithZip6() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true),
                Gen.choose(in: 0.0...1.0, input: Any.self)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
        }
        
        @Test("Gen.lens with zip of seven values")
        func testLensWithZip7() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true),
                Gen.choose(in: 0.0...1.0, input: Any.self),
                Gen.just("bar")
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            
            #expect(generated.0 == replayed.0)
            #expect(generated.1 == replayed.1)
            #expect(generated.2 == replayed.2)
            #expect(generated.3 == replayed.3)
            #expect(generated.4 == replayed.4)
            #expect(generated.5 == replayed.5)
            #expect(generated.6 == replayed.6)
        }
        
        @Test("Gen.lens with zip of eight values")
        func testLensWithZip8() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true),
                Gen.choose(in: 0.0...1.0, input: Any.self),
                Gen.just("bar"),
                Gen.choose(in: -50...50, input: Any.self)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            
            #expect(generated.0 == replayed.0)
            #expect(generated.1 == replayed.1)
            #expect(generated.2 == replayed.2)
            #expect(generated.3 == replayed.3)
            #expect(generated.4 == replayed.4)
            #expect(generated.5 == replayed.5)
            #expect(generated.6 == replayed.6)
            #expect(generated.7 == replayed.7)
        }
        
        @Test("Gen.lens with zip of nine values")
        func testLensWithZip9() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true),
                Gen.choose(in: 0.0...1.0, input: Any.self),
                Gen.just("bar"),
                Gen.choose(in: -50...50, input: Any.self),
                Gen.just(false)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            
            #expect(generated.0 == replayed.0)
            #expect(generated.1 == replayed.1)
            #expect(generated.2 == replayed.2)
            #expect(generated.3 == replayed.3)
            #expect(generated.4 == replayed.4)
            #expect(generated.5 == replayed.5)
            #expect(generated.6 == replayed.6)
            #expect(generated.7 == replayed.7)
            #expect(generated.8 == replayed.8)
        }
        
        @Test("Gen.lens with zip of ten values")
        func testLensWithZip10() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.just("foo"),
                String.arbitrary,
                Gen.choose(in: 1...100, input: Any.self),
                Gen.just(true),
                Gen.choose(in: 0.0...1.0, input: Any.self),
                Gen.just("bar"),
                Gen.choose(in: -50...50, input: Any.self),
                Gen.just(false),
                String.arbitrary
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
            
            #expect(generated.0 == replayed.0)
            #expect(generated.1 == replayed.1)
            #expect(generated.2 == replayed.2)
            #expect(generated.3 == replayed.3)
            #expect(generated.4 == replayed.4)
            #expect(generated.5 == replayed.5)
            #expect(generated.6 == replayed.6)
            #expect(generated.7 == replayed.7)
            #expect(generated.8 == replayed.8)
            #expect(generated.9 == replayed.9)
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
            
            let rect = Interpreters.generate(rectGen)!
            
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
            let elementGen = Gen.choose(in: 1...100, input: Any.self)
            let lengthGen = Gen.just(UInt64(5))
            let arrayGen = Gen.arrayOf(elementGen, lengthGen)
            
            for _ in 0..<20 {
                let array = Interpreters.generate(arrayGen)!
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
                let array = Interpreters.generate(gen)!
                #expect(3...7 ~= array.count)
            }
        }
        
        @Test("Nested proliferate creates nested arrays")
        func testNestedProliferate() {
            let gen = String.arbitrary
                .proliferate(with: 2...4)  // Inner arrays of 2-4 strings
                .proliferate(with: 2...3)  // Outer array of 2-3 inner arrays
            
            for _ in 0..<10 {
                let nestedArray = Interpreters.generate(gen)!
                #expect(2...3 ~= nestedArray.count)
                
                for innerArray in nestedArray {
                    #expect(2...4 ~= innerArray.count)
                }
            }
        }
        
        @Test("Very large arrays")
        func testLargeArrays() throws {
            let gen = UInt8.arbitrary.proliferate(with: 1000...1000)
            
            let largeArray = Interpreters.generate(gen)!
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
            
            let nested = Interpreters.generate(gen)!
            
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
            let intGen = Gen.choose(in: 1...10, input: Any.self)
            let stringGen = String.arbitrary
            
            let choiceGen = Gen.pick(choices: [
                (weight: UInt64(1), generator: intGen.map { "\($0)" }),
                (weight: UInt64(1), generator: stringGen)
            ])
            
            var sawNumeric = false
            var sawNonNumeric = false
            
            for _ in 0..<100 {
                let result = Interpreters.generate(choiceGen)!
                
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
                let result = Interpreters.generate(gen)!
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
            
            let company = Interpreters.generate(companyGen)!
            
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
            let baseGen = Gen.choose(in: 1...100, input: Any.self)
            let arrayGen = baseGen.proliferate(with: 1...10)
            let nestedGen = arrayGen.proliferate(with: 1...5)
            let pickedGen = Gen.pick(choices: [
                (weight: UInt64(1), generator: nestedGen),
                (weight: UInt64(1), generator: nestedGen.map { $0.reversed() })
            ])
            
            // Generate many values to test stability
            for iteration in 0..<100 {
                let generated = Interpreters.generate(pickedGen)!
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
        
        @Test("Test zip implicit lensing composes with bimap")
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
            let shrink = try Interpreters.shrink(instance, using: gen, where: { $0.c == !instance.c })
        }
        
        @Test("Test bimap is replayable")
        func testBimapIsReplayable() throws {
            let gen = Int.arbitrary.mapped(
                forward: { $0.bitPattern64 },
                backward: { Int(bitPattern64: $0) }
            )
            
            let instance = try #require(Interpreters.generate(gen))
            let recipe = try #require(try Interpreters.reflect(gen, with: instance))
            let replay = try #require(try Interpreters.replay(gen, using: recipe))
            #expect(instance == replay)
        }
    }
}
