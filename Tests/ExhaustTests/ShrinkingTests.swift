//
//  ShrinkingTests.swift
//  ExhaustTests
//
//  Tests for the shrinking functionality including simple and complex
//  structure shrinking scenarios.
//

import Testing
@testable import Exhaust

@Suite("Shrinking Functionality")
struct ShrinkingTests {
    
    @Suite("Basic Shrinking")
    struct BasicShrinkingTests {
        
        @Test("Shrinker with simple generators")
        func testShrinkingSimpleGenerator() {
            let gen = Gen.choose(in: 1...1000, input: Any.self)
            let shrinker = Shrinker()
            
            let failingValue = 500
            let property: (Int) -> Bool = { $0 <= 100 }
            
            let shrunken = shrinker.shrink(failingValue, using: gen, where: property)
            
            // Should shrink towards the boundary
            #expect(shrunken == 101)
        }
        
        @Test("Shrinker with array generators")
        func testShrinkingArrayGenerator() {
            let gen = UInt.arbitrary.proliferate(with: 1...20)
            let shrinker = Shrinker()
            
            let largeArray = Array(1...15).map(UInt.init)
            let property: ([UInt]) -> Bool = { $0.count <= 5 }
            
            let shrunken = shrinker.shrink(largeArray, using: gen, where: property)
            
            #expect(shrunken.count > 5)
        }
        
        @Test("Sequence with steps")
        func testSequenceWithSteps() {
            let shrinker = Shrinker()
            let gen = UInt.arbitrary.map { $0 * 10 }
            let counterExample: UInt = 1330
            let property: (UInt) -> Bool = { thing in
                thing == counterExample
            }
            
            let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
            #expect(counterExample == shrunken)
        }
        
        @Test("Shrink to a small even number")
        func testWithASmallShrunkenNumber() {
            let shrinker = Shrinker()
            let gen = Int.arbitrary.map { $0 }
            let counterExample: Int = 33
            let property: (Int) -> Bool = { thing in
                print("Testing \(thing) -> \(thing % 2 == 0 && thing < 10 && thing > 0)")
                return thing % 2 == 0 && thing < 10 && thing > 0
            }
            
            let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
            #expect(shrunken == 1)
        }
        
        @Test("Sum of two numbers must be less than 100")
        func testWithSumOfTwoNumbers() {
            let shrinker = Shrinker()
            let gen = Gen.zip(UInt.arbitrary, UInt.arbitrary)
            let counterExample: (UInt, UInt) = (150, 250)
            let property: ((UInt, UInt)) -> Bool = { thing in
                let isTrue = thing.0 + thing.1 < 100
                print("Testing \(thing) -> \(isTrue)")
                return isTrue
            }
            
            let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
            #expect(shrunken == (0, 100))
        }
    }
    
    @Suite("Complex Structure Shrinking")
    struct ComplexShrinkingTests {
        
        struct TestPerson: Equatable {
            let name: String
            let age: UInt
            let height: Double
        }
        
        @Test("Shrinker finds minimal failing Person")
        func testPersonShrinking() {
            struct Person: Equatable {
                let age: Int
                let height: Int
            }
            let shrinker = Shrinker()
            
            let lensedAge = Gen.lens(extract: \Person.age, Gen.choose(in: 0...1500))
            let lensedHeight = Gen.lens(extract: \Person.height, Gen.choose(in: 25...250))
            let personGen = lensedAge.bind { age in
                lensedHeight.map { height in
                    Person(age: age, height: height)
                }
            }
            
            // The test property: fails if the age is over 50 AND the height is under 150.
            let property: (Person) -> Bool = { person in
                person.age >= 51 && person.age <= 125 && person.height < 150 && person.height >= 99
            }
            
            // An initial, large failing value.
            let initialFailingValue = Person(age: 997, height: 165)
            
            // Pre-condition: make sure our initial value actually fails.
            #expect(property(initialFailingValue) == false)
            
            // Assert: The shrinker should find the minimal boundary case.
            let expectedMinimalValue = Person(age: 51, height: 99)
            let recipe = Interpreters.reflect(personGen, with: expectedMinimalValue)
            #expect(recipe != nil)
        }
        
        @Test("Shrinker with complex structures")
        func testShrinkingComplexStructure() {
            Tyche.withConsoleReporting {
                let personGen = Gen.lens(extract: \TestPerson.name, String.arbitrary)
                    .bind { name in
                        Gen.lens(extract: \TestPerson.age, Gen.choose(in: 0...100))
                            .map { age in
                                TestPerson(name: name, age: age, height: 170.0)
                            }
                    }
                
                let shrinker = Shrinker()
                let failingPerson = TestPerson(name: "Very Long Name", age: 37, height: 170.0)
                
                // Property: succeedes if age > 50 OR name length > 5
                let property: (TestPerson) -> Bool = { person in
                    person.age > 50 || person.name.count < 5
                }
                #expect(property(failingPerson) == false)
                
                let shrunken = shrinker.shrink(failingPerson, using: personGen, where: property)
                
                // Should shrink to minimal failing case
                #expect(shrunken.age == 49)
                #expect(shrunken.name.count >= 5)
                #expect(shrunken.age <= failingPerson.age)
                #expect(shrunken.name.count <= failingPerson.name.count)
            }
        }
        
        @Test("Text shrinking with zipped")
        func testShrinkingWithZips() throws {
            let gen = Gen.zip(
                String.arbitrary,
                Gen.choose(in: UInt64(0)...100_000_000)
            )
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(Interpreters.reflect(gen, with: generated))
            let replayed = try #require(Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
            let failing: (String, UInt64) = ("Kolbu", 45_000)

            let property: (String, UInt64) -> Bool = { name, num in
                num != 80085 && name.count > 2
            }
            
            let shrunk = Shrinker().shrink(failing, using: gen, where: property)
            print(shrunk)
            #expect(shrunk.1 == 80085)
            #expect(shrunk.0.count <= 2)
        }
        
        @Test("Test shrinking with six inputs")
        func testShrinkingWithSixInputs() throws {
            try Tyche.withConsoleReporting {
                // Swift synthesises Equatable conformance for tuples up to 6
                typealias Tuple = (String, String, Int, UInt64, Double, Int)
                let gen = Gen.zip(
                    String.arbitrary,
                    String.arbitrary,
                    Gen.choose(in: -1_000_000...1_000_000),
                    Gen.choose(in: UInt64(0)...100_000_000),
                    Gen.choose(in: 0.0...1.0),
                    Gen.choose(in: -50...50),
                ).map { $0 as Tuple }
                
                let generated = try #require(Interpreters.generate(gen))
                let recipe = try #require(Interpreters.reflect(gen, with: generated))
                let replayed = try #require(Interpreters.replay(gen, using: recipe))
                #expect(generated == replayed)
                let property: (Tuple) -> Bool = { tuple in
                    // TestIsFailing if this is true?
                    tuple.3 < 100_000 && tuple.3 > 50_000
                }
                let failing: Tuple = ("Shonky", "Shabaka", 1, 75000, 0.35, -25)
                #expect(property(failing))
                let shrunk = Shrinker().shrink(failing, using: gen, where: property)
                print(shrunk)
                #expect(shrunk.2 >= 100_000)
            }
        }
    }
    
    @Suite("String Shrinking")
    struct StringShrinkingTests {
        
        @Test("Shrinking something with strings!")
        func testStringObjectShrinking() throws {
            // Arrange
            struct Thing: Equatable {
                let name: String
            }
            let shrinker = Shrinker()
            let gen = Gen.lens(extract: \Thing.name, String.arbitrary)
                .map { Thing(name: $0) }
            
            let failingExample = Thing(name: "blabla here we go again what is this even, come on")
            let recipe = try #require(Interpreters.reflect(gen, with: failingExample))
            let replayed = try #require(Interpreters.replay(gen, using: recipe))
            #expect(replayed.name == failingExample.name)
            
            let property: (Thing) -> Bool = { thing in
                thing.name.first?.isUppercase ?? false
            }
            #expect(property(failingExample) == false)
            
            
            let expectedMinimumCounterExample = Thing(name: "A")
            
            // Act
            let shrunken = shrinker.shrink(failingExample, using: gen, where: property)
            
            // Assert
            #expect(expectedMinimumCounterExample == shrunken)
        }
        
        @Test("Simple string array")
        func testSimpleStringArray() {
            let gen = String.arbitrary.proliferate(with: 1...10)
            let minimal = ["Hello there"]
            let recipe = Interpreters.reflect(gen, with: minimal)
            let shrunken = Shrinker().shrink(minimal, using: gen, where: {
                $0.first?.contains(where: { $0.isUppercase }) ?? false
            })
        }
        
        @Test("Simple nested string array")
        func testSimpleNestedStringArray() {
            let gen = String.arbitrary.proliferate(with: 1...10).proliferate(with: 1...10)
            let minimal = [["Hello there"]]
            let recipe = Interpreters.reflect(gen, with: minimal)
            let shrunken = Shrinker().shrink(minimal, using: gen, where: {
                $0.first?.first?.contains(where: { $0.isUppercase }) ?? false
            })
        }
    }
    
    @Suite("Advanced Shrinking Scenarios")
    struct AdvancedShrinkingTests {
        
        struct Receipt: Equatable {
            let items: [[String]]
            let cost: UInt64
        }
        
        @Test("Sequence with picks")
        func testSequenceWithPicks() {
            let shrinker = Shrinker()
            
            let stringArrGen = String.arbitrary.proliferate(with: 5...10).proliferate(with: 1...2)
            let gen = Gen.lens(
                extract: \Receipt.items,
                stringArrGen
            )
                .bind { items in
                    Gen.lens(extract: \Receipt.cost, Gen.choose(in: 1...100)).map { cost in
                        Receipt(items: items, cost: cost)
                    }
                }
            let property: (Receipt) -> Bool = { thing in
                let flattened = thing.items.flatMap { $0 }
                guard
                    flattened.isEmpty == false
                else {
                    return true
                }
                let costPerItem = thing.cost / UInt64(flattened.count)
                return costPerItem > 1
            }
            let counterExample = Receipt(
                items: [["ham", "cheese", "a", "b", "c"]],
                cost: 4
            )
            #expect(property(counterExample) == false)
            
            let recipe = Interpreters.reflect(gen, with: counterExample)
            let shrunken = shrinker.shrink(counterExample, using: gen, where: property)
            let minimalCounterExample = Receipt(items: [[""]], cost: 0)
            #expect(minimalCounterExample == shrunken)
        }
    }
}
