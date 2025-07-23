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
    
    @Suite("Choice base type shrinks")
    struct ChoiceBaseTypeShrinks {
        
        @Test("UInt shrinks from max to 6")
        func testBasicUintShrink() throws {
            typealias Shrink = UInt
            let gen = Shrink.arbitrary
            let failing: Shrink = .max
            let target: Shrink = 6
            let property: (Shrink) -> Bool = { value in
                value < target
            }
            
            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
            #expect(shrunken == target)
        }
        
        @Test("Int shrinks from max to 6")
        func testBasicIntShrink() throws {
            typealias Shrink = Int
            let gen = Shrink.arbitrary
            let failing: Shrink = .max
            let target: Shrink = 6
            let property: (Shrink) -> Bool = { value in
                value < target
            }
            
            // Goes to -1 as part of fundamentals, can't shrink up from there
            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
            #expect(shrunken == target)
        }
        
        @Test("Double shrinks from max to 6")
        func testBasicDoubleShrink() throws {
            typealias Shrink = Double
            let gen = Shrink.arbitrary
            let failing: Shrink = 999
            let target: Shrink = 6
            let property: (Shrink) -> Bool = { value in
                return value.isNaN == false && value < target
            }

            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
            #expect(shrunken <= target + 0.1)
        }
        
        @Test("Character shrinks from max to \0")
        func testBasicCharacterShrink() throws {
            typealias Shrink = Character
            let gen = Shrink.arbitrary
            let failing: Shrink = "圽"
            let target: Shrink = "f"
            let property: (Shrink) -> Bool = { value in
                value.bitPattern64 < target.bitPattern64
            }

            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
            #expect(shrunken == target)
        }
    }
    
    @Suite("Basic Shrinking")
    struct BasicShrinkingTests {
        
        @Test("Shrinker with simple generators")
        func testShrinkingSimpleGenerator() throws {
            let gen = Gen.choose(in: 1...1000, input: Any.self)
            
            let failingValue = 500
            let property: (Int) -> Bool = { $0 <= 100 }
            
            // This acts weird because of ints
            let shrunken = try Interpreters.shrink(failingValue, using: gen, where: property)
            
            // Should shrink towards the boundary
            #expect(shrunken == 101)
        }
        
        @Test("Shrinker with array generators")
        func testShrinkingArrayGenerator() throws {
            let gen = UInt.arbitrary.proliferate(with: 1...20)
            
            let largeArray = Array(1...15).map(UInt.init)
            let property: ([UInt]) -> Bool = { $0.count <= 5 }
            
            // This deadlocks the shrinker
            let shrunken = try Interpreters.shrink(largeArray, using: gen, where: property)
            
            #expect(shrunken.count > 5)
        }
        
        @Test("Sequence with steps")
        func testSequenceWithSteps() throws {
            let gen = UInt.arbitrary.map { $0 &* 10 }
            let property: (UInt) -> Bool = { thing in
                thing < 100
            }
            
            // This loses the `important` aspect. Perhaps single values shouldn't have them?
            let shrunken = try Interpreters.shrink(1330, using: gen, where: property)
            #expect(shrunken == 100)
        }
        
        @Test("Shrink to a small even number")
        func testWithASmallShrunkenNumber() throws {
            let gen = Int.arbitrary.map { $0 }
            let counterExample: Int = 33
            let property: (Int) -> Bool = { thing in
                print("Testing \(thing) -> \(thing % 2 == 0 && thing < 10 && thing > 0)")
                return thing % 2 == 0 && thing < 10 && thing > 0
            }
            // This deadlocks the shrinker. Int?
            let shrunken = try Interpreters.shrink(counterExample, using: gen, where: property)
            #expect(shrunken == 1)
        }
        
        @Test("Sum of two numbers must be less than 100")
        func testWithSumOfTwoNumbers() throws {
            let gen = Gen.choose(in: UInt(1)...1_000_000, input: Any.self)
            let zipGen = Gen.zip(gen, gen)
            let counterExample: (UInt, UInt) = (150, 250)
            let property: ((UInt, UInt)) -> Bool = { thing in
                let isTrue = thing.0 &+ thing.1 < 100
                print("Testing \(thing) -> \(isTrue)")
                return isTrue
            }
            let recipe = Interpreters.reflect(zipGen, with: counterExample)
            // This is just wrong at (127, 1) due to binary kicking in when it switched to `.important`
            let shrunken = try Interpreters.shrink(counterExample, using: zipGen, where: property)
            #expect(shrunken == (1, 99))
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
        func testPersonShrinking() throws {
            struct Person: Equatable {
                let age: Int
                let height: Int
            }
            
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
        
        @Test("Test Choice Tree merge")
        func testChoiceTreeMerge() throws {
            let char = ChoiceTree.choice(.character("F"), .init(validRanges: Character.bitPatternRanges, strategies: Character.strategies))
            let left = ChoiceTree.group([.sequence(length: 10, elements: Array(repeating: char, count: 10), .init(validRanges: Character.bitPatternRanges, strategies: Character.strategies))])
            let right = left.map { choice in
                guard case let .choice(.character, meta) = choice else {
                    return choice
                }
                return .choice(.character("G"), meta)
            }
            
            let merged = left.merge(with: right) { lhs, rhs in
                switch (lhs, rhs) {
                case (.choice, .choice):
                    return lhs != rhs ? .important(lhs) : lhs
                case let (.sequence(lhsLength, lhsElements, _), .sequence(rhsLength, rhsElements, _)):
                    if lhsLength != rhsLength {
                        return .important(lhs)
                    }
                    if lhsElements.elementsEqual(rhsElements) == false {
                        return .important(lhs)
                    }
                    return nil
                default:
                    return nil
                }
            }
            
            print()
        }
        
        @Test("Shrinker with complex structures")
        func testShrinkingComplexStructure() throws {
            struct Thing: Equatable {
                let name: String
                let age: UInt
            }
            let personGen = Gen.lens(extract: \Thing.name, String.arbitrary)
                .bind { name in
                    Gen.lens(extract: \Thing.age, UInt.arbitrary).map { age in
                        Thing(name: name, age: age)
                    }
                }

//            let generated = try #require(Interpreters.generate(personGen))
            let failingPerson = Thing(name: "圽苙➂颾꘬귕䞰霣퇨ꁼ趈₠ⵔ玮ᜏ⭅되ナ狾쬭닕䋉퉬ꤑგ阉簼ᬑ줙쒱룴驦欺㍖ࠑ胰ׂ瘅雯휘虌ǖ狓߶ꃫ䳵⹰禹掩ꥤ贼掯ᅄꂲ饟溱⻁꿸⮝儺춐㗏㤴ރ仄aa鷑朜舲棃峙쇄돱䟫́⪏쵑垭쏣캠鄨噉∧듼왬쿺ꠀ㕰㟛㲣᧤挽ꢚ볪䱫㣵憬뉣瓲죥̈́卽⭠퉿ٔѩaa쨡⃴㧣兡᝺狢穧昽ቜೡꆫ䳪럖죩树ꕣ㤉❇ප", age: 47)
//
//            let failingPerson = Thing(name: "ancaa", age: 47)
            let property: (Thing) -> Bool = { person in
                // This is completely opaque. We don't know
                person.name.contains("aa") == false
            }
            #expect(property(failingPerson) == false)
            
            let shrunken = try Interpreters.shrink(failingPerson, using: personGen, where: property)
            
            // Should shrink to minimal failing case
            #expect(shrunken.name == "aa")
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
                num < 47
            }
            
            let shrunk = try Interpreters.shrink(failing, using: gen, where: property)
            print(shrunk)
            #expect(shrunk.1 == 47)
        }
        
        @Test("Test shrinking with six inputs")
        func testShrinkingWithSixInputs() throws {
            // Swift synthesises Equatable conformance for tuples up to 6
            typealias Tuple = (Int, UInt64, String, String, Double, Int)
            let gen = Gen.zip(
                Gen.choose(in: -1_000_000...1_000_000),
                Gen.choose(in: UInt64(0)...100_000_000),
                String.arbitrary,
                String.arbitrary,
                Gen.choose(in: 0.0...1.0),
                Gen.choose(in: -50...50),
            ).map { $0 as Tuple }
            
            let generated = try #require(Interpreters.generate(gen))
            let recipe = try #require(Interpreters.reflect(gen, with: generated))
            let replayed = try #require(Interpreters.replay(gen, using: recipe))
            #expect(generated == replayed)
            let property: (Tuple) -> Bool = { tuple in
                // TestIsFailing if this is true?
                tuple.1 < 100_000
            }
            // The issue here is that it's shrinking "complexity" overall, but isn't reducing the value
            // that actually plays into the property failing
            let failing: Tuple = (1_000_000, 1_050_000, "Shonky", "Shabaka", 0.35, -25)
            #expect(property(failing) == false)
            let shrunk = try Interpreters.shrink(failing, using: gen, where: property)
            print(shrunk)
            #expect(shrunk.1 >= 100_000)
//            try Tyche.withConsoleReporting {
//            }
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
            let gen = Gen.lens(extract: \Thing.name, String.arbitrary)
                .map { Thing(name: $0) }
            
            let failingExample = Thing(name: "blabla here we go again what is this even, come on")
            let recipe = try #require(Interpreters.reflect(gen, with: failingExample))
            let replayed = try #require(Interpreters.replay(gen, using: recipe))
            #expect(replayed.name == failingExample.name)
            
            let property: (Thing) -> Bool = { thing in
                thing.name.isEmpty == false && thing.name.first!.isUppercase
            }
            #expect(property(failingExample) == false)
            
            
            let expectedMinimumCounterExample = Thing(name: "")
            
            // Act
            let shrunken = try Interpreters.shrink(failingExample, using: gen, where: property)
            
            // Assert
            #expect(expectedMinimumCounterExample == shrunken)
        }
        
        @Test("Simple string array")
        func testSimpleStringArray() throws {
            let gen = String.arbitrary.proliferate(with: 1...10)
            let minimal = ["Hello there"]
            let recipe = Interpreters.reflect(gen, with: minimal)
            let shrunken = try Interpreters.shrink(minimal, using: gen, where: {
                $0.first?.contains(where: { $0.isUppercase }) ?? false
            })
        }
        
        @Test("Simple nested string array")
        func testSimpleNestedStringArray() throws {
            let gen = String.arbitrary.proliferate(with: 1...10).proliferate(with: 1...10)
            let minimal = [["hello there"]]
            let shrunken = try Interpreters.shrink(minimal, using: gen) {
                $0.first?.first?.contains(where: { $0.isUppercase }) ?? false
            }
            #expect(shrunken == [])
        }
    }
    
    @Suite("Advanced Shrinking Scenarios")
    struct AdvancedShrinkingTests {
        
        struct Receipt: Equatable {
            let items: [String]
            let cost: UInt64
        }
        
        @Test("Sequence with picks")
        func testSequenceWithPicks() throws {
            
            let stringArrGen = String.arbitrary.proliferate(with: 5...10)
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
                let flattened = thing.items
                guard
                    flattened.isEmpty == false
                else {
                    return true
                }
                let costPerItem = thing.cost / UInt64(flattened.count)
                return costPerItem > 1
            }
            let counterExample = Receipt(
                items: ["ham", "cheese", "a", "b", "c"],
                cost: 4
            )
            #expect(property(counterExample) == false)
            
            let shrunken = try Interpreters.shrink(counterExample, using: gen, where: property)
            let minimalCounterExample = Receipt(items: ["ham"], cost: 0)
            #expect(minimalCounterExample == shrunken)
        }
    }
}
