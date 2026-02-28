////
////  ShrinkingChallenges.swift
////  Exhaust
////
////  Created by Chris Kolbu on 30/7/2025.
////
//
// @testable import Exhaust
@_spi(ExhaustInternal) @testable import ExhaustCore
// import Testing
//
// @Suite("Shrinking challenges")
// struct ShrinkingChallenges {
//    @Test("Bound 5")
//    func testBound5() throws {
//        /*
//         Given a 5-tuple of lists of 16-bit integers, we want to test the property that if each list sums to less than 256, then the sum of all the values in the lists is less than 5 * 256. This is false because of overflow. e.g. ([-20000], [-20000], [], [], []) is a counter-example.
//
//         The interesting thing about this example is the interdependence between separate parts of the sample data. A single list in the tuple will never break the invariant, but you need at least two lists together. This prevents most of trivial shrinking algorithms from getting close to a minimum example, which would look somethink like ([-32768], [-1], [], [], []).
//         https://github.com/jlink/shrinking-challenge/blob/main/challenges/bound5.md
//         */
//
//        typealias FiveTuple = ([Int16], [Int16], [Int16], [Int16], [Int16])
//        let arrayGen = Gen.arrayOf(Int16.arbitrary)
//        let tupleGen = Gen.zip(arrayGen, arrayGen, arrayGen, arrayGen, arrayGen)
//
//        let property = { (value: FiveTuple) in
//            let sum1 = value.0.reduce(0, (&+))
//            let sum2 = value.1.reduce(0, (&+))
//            let sum3 = value.2.reduce(0, (&+))
//            let sum4 = value.3.reduce(0, (&+))
//            let sum5 = value.4.reduce(0, (&+))
//            let arr = [sum1, sum2, sum3, sum4, sum5]
//            if arr.allSatisfy({ $0 < 256 }) {
//                return arr.reduce(0, &+) < (arr.count * 256)
//            }
//            return false
//        }
//
//        // No hope to do this one yet. It doesn't normalise well
//        let failingExample: FiveTuple = ([-20000], [-20000], [], [], [])
//        let recipe = try #require(try Interpreters.reflect(tupleGen, with: failingExample))
////        let normalization = try TestCaseReducer.normalize(failingExample, generator: tupleGen, property: property, recipe: recipe)
//        let shrink = try TestCaseReducer.shrink(failingExample, using: tupleGen, where: property)
//        print()
//    }
//
//    @Test("Length list")
//    func testLengthList() throws {
//        /*
//         A list should be generated first by picking a length between 1 and 100, then by generating a list of precisely that length whose elements are integers between 0 and 1000. The test should fail if the maximum value of the list is 900 or larger.
//
//         This list should specifically be generated using monadic combinators (bind) or some equivalent, and this is a test that is only interesting for integrated shrinking. This is only interesting as a test of a problem (https://clojure.github.io/test.check/growth-and-shrinking.html#unnecessary-bind) some property-based testing libraries have with monadic bind. In particular the use of the length parameter is critical, and the challenge is to shrink this example to [900] reliably when using a PBT library's built in generator for lists.
//         */
//
//        // We need the ability to search upwards for this one. And possible replace the generator passed to Gen.arrayOf with Just a closed range to clamp the generated size
//        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...1000, input: Any.self), within: 1...100)
//        let property: ([UInt64]) -> Bool = { arr in
//            arr.reduce(0, (+)) < 900
//        }
//        let failingExample: [UInt64] = [450, 250, 30, 20, 90, 4500]
//        let minimalCounterExample: [UInt64] = [900]
//        let recipe = try #require(try Interpreters.reflect(gen, with: failingExample))
//        let normalization = try TestCaseReducer.normalize(failingExample, generator: gen, limit: 100, property: property, recipe: recipe)
//        let shrink = try TestCaseReducer.shrink(failingExample, using: gen, where: property)
//        print()
//
//    }
// }
