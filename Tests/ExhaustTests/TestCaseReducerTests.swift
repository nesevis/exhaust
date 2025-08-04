//
//  TestCaseReducerTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

@testable import Exhaust
import Testing

//@Suite("Test Case Reducer tests")
//struct TestCaseReducerTests {
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
//    @Test("TestSimpleDoubleReduction")
//    func testSimpleDoubleReduction() throws {
//        let gen = Gen.choose(in: Double(-1_000_000)...1_000_000, input: Any.self)
//        let failing = Double(1_000_000)
//        let property = { (value: Double) in
//            value < -1337
//        }
//        // The binary reducer starts dividing the value into ever smaller fractions of <0.0001 instead of going negative.
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let shrunk = try TestCaseReducer.shrink(failing, using: gen, where: property)
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
//        let failing = Person(name: "malebolge", age: 67, height: 192)
//        let property = { (value: Person) in
//            value.age > 14
//        }
//        // How do you even prune a character gen, a pick with discontiguous ranges?
//        let recipe = try Interpreters.reflect(gen, with: failing)
//        let normalized30 = try TestCaseReducer.normalize(failing, generator: gen, limit: 30, property: property, recipe: recipe!)
////        let shrunk = try TestCaseReducer.shrink(failing, recipe: normalized, using: gen, where: property)
//        let replayed = try Interpreters.replay(gen, using: normalized30)
//        print()
//    }
//    
//    @Test("Sum of two numbers must be less than 100")
//    func testWithSumOfTwoNumbers() throws {
//        let gen = Gen.choose(in: UInt(1)...1_000_000, input: Any.self)
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
//}
