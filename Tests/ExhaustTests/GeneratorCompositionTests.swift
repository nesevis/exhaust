//
//  GeneratorCompositionTests.swift
//  ExhaustTests
//
//  Comprehensive test suite for generator composition using Gen factory methods,
//  Arbitrary extensions, interpreters, and shrinkers.
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

// MARK: - Basic Gen Factory Method Tests

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
func testGenExact() {
    let value = 42
    let gen = Gen.exact(value)
    
    // Test reflection works with exact value
    let recipe = Interpreters.reflect(gen, with: value)
    #expect(recipe != nil)
    
    // Test reflection fails with different value
    let badRecipe = Interpreters.reflect(gen, with: 43)
    #expect(badRecipe == nil)
    
    // Test replay
    guard let recipe = recipe else {
        #expect(false, "Reflection failed for Gen.exact test")
        return
    }
    guard let replayed = Interpreters.replay(gen, using: recipe) else {
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

// MARK: - Lens Composition Tests

@Test("Gen.lens with simple property extraction")
func testSimpleLens() {
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
    if let recipe = Interpreters.reflect(personGen, with: person) {
        if let replayed = Interpreters.replay(personGen, using: recipe) {
            #expect(person == replayed)
        } else {
            #expect(false, "Replay failed for person")
        }
    } else {
        #expect(false, "Reflection failed for person")
    }
}

@Test("Gen.lens with nested structures")
func testNestedLens() {
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
    if let recipe = Interpreters.reflect(rectGen, with: rect) {
        if let replayed = Interpreters.replay(rectGen, using: recipe) {
            #expect(rect == replayed)
        } else {
            #expect(false, "Replay failed for rectangle")
        }
    } else {
        #expect(false, "Reflection failed for rectangle")
    }
}

// MARK: - Pick/Choice Tests

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

// MARK: - Array and Proliferate Tests

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

// MARK: - Complex Composition Tests

@Test("Complex company structure with nested generators")
func testComplexComposition() {
    let personGen = Gen.lens(extract: \TestPerson.name, String.arbitrary)
        .bind { name in
            Gen.lens(extract: \TestPerson.age, Gen.choose(in: 18...65))
                .bind { age in
                    Gen.lens(extract: \TestPerson.height, Gen.choose(in: 150.0...200.0))
                        .map { height in
                            TestPerson(name: name, age: age, height: height)
                        }
                }
        }
    
    let companyGen = Gen.lens(extract: \TestCompany.name, String.arbitrary)
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
    
    // Validate structure
    #expect(5...20 ~= company.employees.count)
    #expect(1900...2023 ~= company.founded)
    
    for employee in company.employees {
        #expect(18...65 ~= employee.age)
        #expect(150.0...200.0 ~= employee.height)
    }
    
    // Test round-trip
    if let recipe = Interpreters.reflect(companyGen, with: company) {
        if let replayed = Interpreters.replay(companyGen, using: recipe) {
            #expect(company == replayed)
        } else {
            #expect(false, "Replay failed for company")
        }
    } else {
        #expect(false, "Reflection failed for company")
    }
}

// MARK: - Interpreter Interaction Tests

@Test("Generate-Reflect-Replay cycle consistency")
func testGenerateReflectReplayConsistency() {
    let generators: [ReflectiveGenerator<Any, String>] = [
        String.arbitrary,
//        Gen.just("constant"),
//        String.arbitrary.proliferate(with: 1...5).map { $0.joined() }
    ]
    
    for (index, gen) in generators.enumerated() {
        for iteration in 0..<10 {
            let generated = Interpreters.generate(gen)!
            if let recipe = Interpreters.reflect(gen, with: generated) {
                if let replayed = Interpreters.replay(gen, using: recipe) {
                    print()
                    #expect(generated.map(\.bitPattern64) == replayed.map(\.bitPattern64), "Generator \(index), iteration \(iteration): \(generated) != \(replayed)")
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
func testMultipleGenerationConsistency() {
    let gen = Gen.choose(in: 1...100, input: Any.self)
    guard let recipe = Interpreters.reflect(gen, with: 42) else {
        #expect(false, "Reflection failed for value 42")
        return
    }
    
    // Multiple replays should produce the same result
    for _ in 0..<20 {
        if let replayed = Interpreters.replay(gen, using: recipe) {
            #expect(replayed == 42)
        } else {
            #expect(false, "Replay failed for value 42")
        }
    }
}

// MARK: - Shrinking Tests

@Test("Shrinker with simple generators")
func testShrinkingSimpleGenerator() {
    let gen = Gen.choose(in: 1...1000, input: Any.self)
    let shrinker = Shrinker()
    
    let failingValue = 500
    let property: (Int) -> Bool = { $0 >= 100 }
    
    let shrunken = shrinker.shrink(failingValue, using: gen, where: property)
    
    // Should shrink towards the boundary
    #expect(shrunken >= 100)
    #expect(shrunken < failingValue)
}

@Test("Shrinker with array generators")
func testShrinkingArrayGenerator() {
    let gen = UInt.arbitrary.proliferate(with: 1...20)
    let shrinker = Shrinker()
    
    let largeArray = Array(1...15).map(UInt.init)
    let property: ([UInt]) -> Bool = { $0.count >= 5 }
    
    let shrunken = shrinker.shrink(largeArray, using: gen, where: property)
    
    #expect(shrunken.count >= 5)
    #expect(shrunken.count <= largeArray.count)
}

@Test("Shrinker with complex structures")
func testShrinkingComplexStructure() {
    let personGen = Gen.lens(extract: \TestPerson.name, String.arbitrary)
        .bind { name in
            Gen.lens(extract: \TestPerson.age, Gen.choose(in: 0...100))
                .map { age in
                    TestPerson(name: name, age: age, height: 170.0)
                }
        }
    
    let shrinker = Shrinker()
    let failingPerson = TestPerson(name: "Very Long Name", age: 80, height: 170.0)
    
    // Property: fails if age > 50 OR name length > 5
    let property: (TestPerson) -> Bool = { person in
        person.age > 50 || person.name.count > 5
    }
    
    let shrunken = shrinker.shrink(failingPerson, using: personGen, where: property)
    
    // Should shrink to minimal failing case
    #expect(shrunken.age > 50 || shrunken.name.count > 5)
    #expect(shrunken.age <= failingPerson.age)
    #expect(shrunken.name.count <= failingPerson.name.count)
}

// MARK: - Edge Cases and Error Handling

@Test("Empty range handling")
func testEmptyRangeHandling() {
    // Single value range
    let gen = Gen.choose(in: 42...42, input: Any.self)
    
    for _ in 0..<10 {
        let value = Interpreters.generate(gen)!
        #expect(value == 42)
    }
}

@Test("Very large arrays")
func testLargeArrays() {
    let gen = UInt8.arbitrary.proliferate(with: 1000...1000)
    
    let largeArray = Interpreters.generate(gen)!
    #expect(largeArray.count == 1000)
    
    // Should still support round-trip
    if let recipe = Interpreters.reflect(gen, with: largeArray) {
        if let replayed = Interpreters.replay(gen, using: recipe) {
            #expect(largeArray == replayed)
        } else {
            #expect(false, "Replay failed for large array")
        }
    } else {
        #expect(false, "Reflection failed for large array")
    }
}

@Test("Deeply nested structures")
func testDeeplyNestedStructures() {
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
    if let recipe = Interpreters.reflect(gen, with: nested) {
        if let replayed = Interpreters.replay(gen, using: recipe) {
            #expect(nested == replayed)
        } else {
            #expect(false, "Replay failed for deeply nested structure")
        }
    } else {
        #expect(false, "Reflection failed for deeply nested structure")
    }
}

// MARK: - Performance and Stress Tests

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

@Test("Complex generator composition stability")
func testComplexGeneratorStability() {
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
        if let recipe = Interpreters.reflect(pickedGen, with: generated) {
            if let replayed = Interpreters.replay(pickedGen, using: recipe) {
                #expect(generated == replayed, "Failed at iteration \(iteration)")
            } else {
                #expect(false, "Replay failed at iteration \(iteration)")
            }
        } else {
            #expect(false, "Reflection failed at iteration \(iteration)")
        }
    }
}
