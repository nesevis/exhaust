//
//  TestCaseReducerTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

// @Suite("Test Case Reducer tests")
// struct TestCaseReducerTests {
//    @Test("TestSimpleReduction")
//    func testSimpleIntReduction() throws {
//        let gen = Int64.arbitrary
//        let failing = Int64.max
//        let property = { (value: Int64) in
//            value < -1337
//        }
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let shrunk = try TestCaseReducer.shrink(failing, using: gen, where: property)
//        print()
//    }
//
//    @Test("Test Simple Number Reduction")
//    func testSimpleNumberReduction() throws {
//        let gen = UInt64.arbitrary // Gen.choose(in: Int(-10_000)...10_000, input: Any.self)
//        let failing = UInt64(9600)
//        let property = { (value: UInt64) in
//            value > 8 && value < 470
//        }
//        // The insight here is that in a range L...U, the shrinker will have to pick one side of a passing value P
//        // E.g L..P..U. It will either take L..<P or P+1...U and then winnow from there. Whichever side of the range differs from the original is the direction to head. Towards the lower bound or towards the higher bound.
//        /*
//         After minimisation:
//         └── group
//             ├── getSize(?)
//             └── choice(unsigned:9600) 19...1125899906842624
//         Here we start with 9600 but end up with a lower bound of 19 which passes the test. In this case this means 19 is the lowest passing test. Does it follow that going below that will cause the test to refail?
//         */
//
//        // The binary reducer starts dividing the value into ever smaller fractions of <0.0001 instead of going negative.
//        let recipe = try Interpreters.reflect(gen, with: failing)
////        let shrunk = try TestCaseReducer.shrink(failing, using: gen, where: property)
//        let normalized = try TestCaseReducer.normalize(failing, generator: gen, limit: 50, property: property, recipe: recipe!)
//        // Why isn't both ends of the range clamping when we have failures on both sides?
//        /*
//         // With 100 test cases
//         Before:
//         └── choice(signed: 10000) -10000...10000
//         After 49 fails:
//         └── choice(signed: -1384) -10000...10000 // The semantically simplest failure, e.g abs(x) distance from zero
//         After 51 passes:
//         └── choice(signed: -1384) -10000...-1254 // Passes help narrow the end of the range we should shrink towards
//         After minimisation:
//         └── choice(signed: -1384) -10000...-1254 // // -10000 is unchanged, so the threshold into not-failing is -1254
//         // The actual cutoff is -1337, which we would get much closer to with more test cases
//         // With 1000:
//         After minimisation:
//         └── choice(signed: -1355) -10000...-1333 (so 4 off)
//         // We will need to check the altered range bound and use that as a shrinking direction, e.g towardUpper|LowerBound.
//         // For our 100 limit attempt, the remaining space is -1384-1254 = 130, and 1337 is only about a third of the way in
//         // When it's >= && <= the shrinker will focus in on a signal in either direction and pick one
//         // This is perfectly fine, as the minimal repro will need to pick one of the boundaries
//         */
//        print()
//    }
//
//    @Test("TestSimpleCharReduction")
//    func testSimpleCharReduction() throws {
//        let gen = Character.arbitrary
//        let failing: Character = "G"
//        let property = { (value: Character) in
//            value < "C"
//        }
//        // How do you even prune a character gen, a pick with discontiguous ranges?
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let normalized = try TestCaseReducer.normalize(failing, generator: gen, limit: 1000, property: property, recipe: recipe!)
////        let shrunk = try TestCaseReducer.shrink(failing, recipe: normalized, using: gen, where: property)
//        print()
//    }
//
//    @Test("TestComplexObjectNormalization")
//    func testComplexObjectNormalization() throws {
//        struct Person: Equatable {
//            let name: String
//            let age: UInt
//            let height: Double
//        }
//        let gen = Gen.zip(String.arbitrary, UInt.arbitrary, Double.arbitrary)
//            .mapped(
//                forward: { Person(name: $0, age: $1, height: $2) },
//                backward: { ($0.name, $0.age, $0.height) }
//            )
//        let failing = Person(name: "malebolge", age: 67, height: 45)
//        let property = { (value: Person) in
//            value.name.count > 5
//        }
//        // Something is happening with the float range here
//        // How do you even prune a character gen, a pick with discontiguous ranges?
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let normalized30 = try TestCaseReducer.normalize(failing, generator: gen, limit: 30, property: property, recipe: recipe!)
////        let shrunk = try TestCaseReducer.shrink(failing, recipe: normalized, using: gen, where: property)
////        let replayed = try Interpreters.replay(gen, using: normalized30)
//        print()
//    }
//
//    @Test("Sum of two numbers must be less than 100")
//    func testWithSumOfTwoNumbers() throws {
//        let gen = Gen.choose(in: UInt(1)...1_000_000)
//        let zipGen = Gen.zip(gen, gen)
//        let counterExample: (UInt, UInt) = (150, 250)
//        let property: ((UInt, UInt)) -> Bool = { thing in
//            let isTrue = thing.0 &+ thing.1 < 100
//            return isTrue
//        }
//
//        // This returns early because the range has narrowed enough that the strategies are
//        // exhausted. Not entirely correctly. It hit a boundary value and was happy with that
//        /*
//         Returning test case reduction after 2 steps and 0 cache hits:
//         Original:
//         └── group
//             ├── choice(unsigned:150) 1...1000000
//             └── choice(unsigned:250) 1...1000000
//         Reduced:
//         └── group
//             ├── ✨choice(unsigned:1)✨ 1...1
//             └── ✨choice(unsigned:250)✨ 1...250
//         (1, 1) // Actual output value
//         */
//        let shrunken = try TestCaseReducer.shrink(counterExample, using: zipGen, where: property)
//        print(shrunken)
//        #expect(shrunken == (1, 99))
//    }
//
//    @Test("TestSimpleStringReduction")
//    func testSimpleStringReduction() throws {
//        let gen = String.arbitrary
//        let failing = "I like sexy sauce hello hello"
//        let property = { (value: String) in
//            value.contains("s") == false && value.contains("e") == false && value.contains("x") == false
//        }
//        // String reduction is a bit tricker. Shortlex is very sensitive and prefers much shorter strings
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let shrunk = try TestCaseReducer.shrink(failing, using: gen, where: property)
//        print()
//    }
// }
