////
////  ShrinkingTests.swift
////  ExhaustTests
////
////  Tests for the shrinking functionality including simple and complex
////  structure shrinking scenarios.
////
//
// import Testing
// @testable import Exhaust
@testable import ExhaustCore
//
// @Suite("Shrinking Functionality")
// struct ShrinkingTests {
//
//    @Suite("Choice base type shrinks")
//    struct ChoiceBaseTypeShrinks {
//
//        @Test("UInt shrinks from max to 6")
//        func testBasicUintShrink() throws {
//            typealias Shrink = UInt
//            let gen = Shrink.arbitrary
//            let failing: Shrink = .max
//            let target: Shrink = 6
//            let property: (Shrink) -> Bool = { value in
//                value < target
//            }
//
//            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
//            #expect(shrunken == target)
//        }
//
//        @Test("Int shrinks from max to 6")
//        func testBasicIntShrink() throws {
//            typealias Shrink = Int
//            let gen = Shrink.arbitrary
//            let failing: Shrink = .max
//            let target: Shrink = 6
//            let property: (Shrink) -> Bool = { value in
//                value < target
//            }
//
//            // Goes to -1 as part of fundamentals, can't shrink up from there
//            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
//            #expect(shrunken == target)
//        }
//
//        // FIXME: This is my biggest worry. This has to do with setting proper ranges in the Reflect function
//        // Idea: Once shrink is called we know that the failing example represents an upper bound. We can set this immediately.
//        // However, the `Value` in the shrinker is the composite element created by the generator. We can only work
//        // on the recipe values. It is correct to initially have the full range of doubles
//        @Test("Double shrinks from max to 6")
//        func testBasicDoubleShrink() throws {
//            typealias Shrink = Double
//            let gen = Shrink.arbitrary
//            let failing: Shrink = .greatestFiniteMagnitude
//            let target: Shrink = 6
//            let property: (Shrink) -> Bool = { value in
//                print("Shrinking \(value) \(value > target)")
//                return value < target
//            }
//
//            // This now fails because the complexity score doesn't deal with fractions
//            let reflectedRecipe = try Interpreters.reflect(gen, with: target)
//            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
//            print()
//            #expect(shrunken <= target + 0.1)
//        }
//
//        @Test("Character shrinks from max to \0")
//        func testBasicCharacterShrink() throws {
//            typealias Shrink = Character
//            let gen = Shrink.arbitrary
//            let failing: Shrink = "圽"
//            let target: Shrink = "f"
//            let property: (Shrink) -> Bool = { value in
//                value.bitPattern64 < target.bitPattern64
//            }
//
//            let shrunken = try Interpreters.shrink(failing, using: gen, where: property)
//            #expect(shrunken == target)
//        }
//    }
//
//    @Suite("Basic Shrinking")
//    struct BasicShrinkingTests {
//
//        @Test("Shrinker with simple generators")
//        func testShrinkingSimpleGenerator() throws {
//            // Note to self: restricting the generator to values in 1...1000 fails the test.
//            // Presumably one of the strategies finds it does not have any viable options due to filtering
//            let gen = Int.arbitrary
//
//            let failingValue = 500
//            let property: (Int) -> Bool = { $0 <= 100 }
//
//            // This acts weird because of ints
//            let shrunken = try Interpreters.shrink(failingValue, using: gen, where: property)
//
//            // Should shrink towards the boundary
//            #expect(shrunken == 101)
//        }
//
//        @Test("Shrinker with array generators")
//        func testShrinkingArrayGenerator() throws {
//            let gen = UInt.arbitrary.proliferate(with: 1...20)
//
//            let largeArray = Array(1...15).map(UInt.init)
//            let property: ([UInt]) -> Bool = { $0.count <= 5 }
//
//            // Christ on a stick this is ripe for some optimisation
//            // Returning counterexample after 1011 steps, 1001 cache hits and 35 complexity. There were 11 unique attempts and 1 valid shrinks. Recipe:
//            let shrunken = try Interpreters.shrink(largeArray, using: gen, where: property)
//
//            #expect(shrunken.count > 5)
//        }
//
//        @Test("Sequence with steps")
//        func testSequenceWithSteps() throws {
//            // This map makes the shrinker feel like it's dealing with the unmultiplied values
//            let gen = UInt.arbitrary.map { $0 &* 10 }
//            let property: (UInt) -> Bool = { thing in
////                print("Shrinking: \(thing)")
//                return thing < 100
//            }
//
//            // Returning counterexample after 41 steps, 28 cache hits and 10 complexity. There were 14 unique attempts and 8 valid shrinks. Recipe:
//            // After refactor:
//            // Returning counterexample after 26 steps, 0 cache hits and 10 complexity. There were 27 unique attempts and 16 valid shrinks
//            let shrunken = try Interpreters.shrink(1330, using: gen, where: property)
//            #expect(shrunken == 100)
//        }
//
//        @Test("Shrink to a small even number")
//        func testWithASmallShrunkenNumber() throws {
//            let gen = Int.arbitrary.map { $0 }
//            let counterExample: Int = 33
//            let property: (Int) -> Bool = { thing in
//                print("Testing \(thing) -> \(thing % 2 == 0 && thing < 10 && thing > 0)")
//                return thing % 2 == 0 && thing < 10 && thing > 0
//            }
//            // Returning counterexample after 5 steps, 1 cache hits and 1 complexity. There were 5 unique attempts and 3 valid shrinks. Recipe:
//            // With changes now terminates with cache hit max and goes to zero. Reduce the cache hits here
//            // After refactor it uses Fundamental and goes to 0, fails, then goes to -Int.max and returns early. Funky
//            let shrunken = try Interpreters.shrink(counterExample, using: gen, where: property)
//            #expect(shrunken == 1)
//        }
//
//        @Test("Sum of two numbers must be less than 100")
//        func testWithSumOfTwoNumbers() throws {
//            let gen = Gen.choose(in: UInt(1)...1_000_000, input: Any.self)
//            let zipGen = Gen.zip(gen, gen)
//            let counterExample: (UInt, UInt) = (150, 250)
//            let property: ((UInt, UInt)) -> Bool = { thing in
//                let isTrue = thing.0 &+ thing.1 < 100
//                print("Testing \(thing) -> \(isTrue)")
//                return isTrue
//            }
//
//            // Returning counterexample after 59 steps, 1 cache hits and 100 complexity. There were 59 unique attempts and 55 valid shrinks. Recipe:
//            // After refactoring this fails after 0 steps hmm..
//            let shrunken = try Interpreters.shrink(counterExample, using: zipGen, where: property)
//            #expect(shrunken == (1, 99))
//        }
//    }
//
//    @Suite("Complex Structure Shrinking")
//    struct ComplexShrinkingTests {
//
//        struct TestPerson: Equatable {
//            let name: String
//            let age: UInt
//            let height: Double
//        }
//
//        @Test("Shrinker finds minimal failing Person")
//        func testPersonShrinking() throws {
//            struct Person: Equatable {
//                let age: Int
//                let canDrink: Bool
//            }
//
//            let lensedAge = Gen.lens(extract: \Person.age, Gen.choose(in: 0...150))
//            let lensedBool = Gen.lens(extract: \Person.canDrink, Bool.arbitrary)
//            let personGen = lensedAge.bind { age in
//                lensedBool.map { canDrink in
//                    Person(age: age, canDrink: canDrink)
//                }
//            }
//
//            // The test property: fails if the age is over 50 AND the height is under 150.
//            let property: (Person) -> Bool = { person in
//                person.canDrink && person.age >= 18
//            }
//
//            // An initial, large failing value.
//            let initialFailingValue = Person(age: 19, canDrink: false)
//
//            // Pre-condition: make sure our initial value actually fails.
//            #expect(property(initialFailingValue) == false)
//
//            // This fails. The shrinker can't work it
//            /*
//             Returning counterexample after 4 steps, 1 cache hits and 165 complexity. There were 4 unique attempts and 3 valid shrinks. Recipe:
//              └── group
//                 ├── choice(signed: 0))
//                 └── choice(signed: 165))
//             */
//            // FIXME: This is great as a test bed for shrinking _up_
//            let expectedMinimalValue = Person(age: 0, canDrink: true)
//            let shrunk = try Interpreters.shrink(initialFailingValue, using: personGen, where: property)
//            #expect(expectedMinimalValue == shrunk)
//        }
//
//        @Test("Shrinker with complex structures")
//        func testShrinkingComplexStructure() throws {
//            struct Thing: Equatable {
//                let name: String
//                let age: UInt
//            }
//            let personGen = Gen.lens(extract: \Thing.name, String.arbitrary)
//                .bind { name in
//                    Gen.lens(extract: \Thing.age, UInt.arbitrary).map { age in
//                        Thing(name: name, age: age)
//                    }
//                }
//
////            let generated = try #require(Interpreters.generate(personGen))
//            let failingPerson = Thing(name: "圽苙➂颾꘬귕䞰霣퇨ꁼ趈₠ⵔ玮ᜏ⭅되ナ狾쬭닕䋉퉬ꤑგ阉簼ᬑ줙쒱룴驦欺㍖ࠑ胰ׂ瘅雯휘虌ǖ狓߶ꃫ䳵⹰禹掩ꥤ贼掯ᅄꂲ饟溱⻁꿸⮝儺춐㗏㤴ރ仄aa鷑朜舲棃峙쇄돱䟫́⪏쵑垭쏣캠鄨噉∧듼왬쿺ꠀ㕰㟛㲣᧤挽ꢚ볪䱫㣵憬뉣瓲죥̈́卽⭠퉿ٔѩaa쨡⃴㧣兡᝺狢穧昽ቜೡꆫ䳪럖죩树ꕣ㤉❇ප", age: 47)
////
////            let failingPerson = Thing(name: "ancaa", age: 47)
//            let property: (Thing) -> Bool = { person in
//                // This is completely opaque. We don't know
//                person.name.contains("aa") == false
//            }
//            #expect(property(failingPerson) == false)
//
//            let shrunken = try Interpreters.shrink(failingPerson, using: personGen, where: property)
//            print()
//
//            // Shrinks well, but pulls out the character.
//            // Good for finding where to break
//            /*
//             Returning counterexample after 1030 steps, 1001 cache hits and 443 complexity. There were 30 unique attempts and 9 valid shrinks. Recipe:
//              └── group
//                 ├── sequence(length: 2)
//                 │   └── choice([char]: "aa")
//                 └── choice(unsigned:47)
//             Of particular interest is the value: a
//             */
//            #expect(shrunken.name == "aa")
//        }
//
//        @Test("Test shrinking with six inputs")
//        func testShrinkingWithSixInputs() throws {
//            // Swift synthesises Equatable conformance for tuples up to 6
//            typealias Tuple = (Int, UInt64, String, String, Double, Int)
//            let gen = Gen.zip(
//                Gen.choose(in: -1_000_000...1_000_000),
//                Gen.choose(in: UInt64(0)...100_000_000),
//                String.arbitrary,
//                String.arbitrary,
//                Gen.choose(in: 0.0...1.0),
//                Gen.choose(in: -50...50),
//            ).map { $0 as Tuple }
//
//            var iterator = GeneratorIterator(gen)
//            let generated = iterator.next()!
//            let recipe = try #require(try Interpreters.reflect(gen, with: generated))
//            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
//            #expect(generated == replayed)
//            let property: (Tuple) -> Bool = { tuple in
//                tuple.1 < 100_000
//            }
//            // The issue here is that it's shrinking "complexity" overall, but isn't reducing the value
//            // that actually plays into the property failing
//            let failing: Tuple = (1_000_000, 1_050_000, "Shonky", "Shabaka", 0.35, -25)
//            #expect(property(failing) == false)
//            let shrunk = try Interpreters.shrink(failing, using: gen, where: property)
//            print(shrunk)
//            #expect(shrunk.1 >= 100_000)
//            /*
//             For some reason it finds the strings more interesting. Perhaps due to the new shortlex complexity measure?
//
//             Returning counterexample after 59 steps, 17 cache hits and 112374 complexity. There were 43 unique attempts and 30 valid shrinks. Recipe:
//              └── group
//                 ├── choice(signed: 0)
//                 ├── choice(unsigned:105000)
//                 ├── ✨sequence(length: 4)✨
//                 │   └── choice([char]: "onk")
//                 ├── ✨sequence(length: 5)✨
//                 │   └── choice([char]: "abak")
//                 ├── choice(float: 0.09999999999999998)
//                 └── choice(signed: -25)
//             */
//        }
//    }
//
//    @Suite("String Shrinking")
//    struct StringShrinkingTests {
//
//        @Test("Shrinking something with strings!")
//        func testStringObjectShrinking() throws {
//            // Arrange
//            struct Thing: Equatable {
//                let name: String
//            }
//            let gen = Gen.lens(extract: \Thing.name, String.arbitrary)
//                .map { Thing(name: $0) }
//
//            let failingExample = Thing(name: "blabla here we go again what is this even, come on")
//            let recipe = try #require(try Interpreters.reflect(gen, with: failingExample))
//            let replayed = try #require(try Interpreters.replay(gen, using: recipe))
//            #expect(replayed.name == failingExample.name)
//
//            let property: (Thing) -> Bool = { thing in
//                thing.name.isEmpty == false && thing.name.first!.isUppercase
//            }
//            #expect(property(failingExample) == false)
//
//
//            let expectedMinimumCounterExample = Thing(name: "")
//
//            // Act
//            let shrunken = try Interpreters.shrink(failingExample, using: gen, where: property)
//
//            // Assert
//            print()
//            #expect(expectedMinimumCounterExample == shrunken)
//        }
//    }
//
//    @Suite("Advanced Shrinking Scenarios")
//    struct AdvancedShrinkingTests {
//
//        struct Receipt: Equatable {
//            let items: [String]
//            let cost: UInt64
//        }
//
//        @Test("Sequence with picks")
//        func testSequenceWithPicks() throws {
//
//            let stringArrGen = String.arbitrary.proliferate(with: 5...10)
//            let gen = Gen.lens(
//                extract: \Receipt.items,
//                stringArrGen
//            )
//                .bind { items in
//                    Gen.lens(extract: \Receipt.cost, Gen.choose(in: 1...100)).map { cost in
//                        Receipt(items: items, cost: cost)
//                    }
//                }
//            let property: (Receipt) -> Bool = { thing in
//                let flattened = thing.items
//                guard
//                    flattened.isEmpty == false
//                else {
//                    return true
//                }
//                let costPerItem = thing.cost / UInt64(flattened.count)
//                return costPerItem > 1
//            }
//            let counterExample = Receipt(
//                items: ["ham", "cheese", "a", "b", "c"],
//                cost: 4
//            )
//            #expect(property(counterExample) == false)
//
//            let shrunken = try Interpreters.shrink(counterExample, using: gen, where: property)
//            // Looks like shrinking runs aground with getSize
//            let minimalCounterExample = Receipt(items: ["b"], cost: 1)
//            #expect(minimalCounterExample == shrunken)
//            /*
//             Chuffed with that one. This is a proper minimal example
//             Returning counterexample after 17 steps, 7 cache hits and 2 complexity. There were 11 unique attempts and 4 valid shrinks. Recipe:
//              └── group
//                 ├── ✨sequence(length: 1)✨
//                 │   └── sequence(length: 0)
//                 └── choice(unsigned: 1)
//
//             Now returns
//             Cache hit limit reached; breaking
//             Returning counterexample after 1012 steps, 1001 cache hits and 401 complexity. There were 12 unique attempts and 3 valid shrinks. Recipe:
//              └── group
//                 ├── sequence(length: 2)
//                 │   ├── sequence(length: 1)
//                 │   │   └── choice([char]: "a")
//                 │   └── sequence(length: 1)
//                 │       └── choice([char]: "b")
//                 └── ✨choice(unsigned:2)✨
//             */
//
//        }
//    }
// }
