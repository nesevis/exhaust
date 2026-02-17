//
//  ConstraintViolationTests.swift
//  ExhaustTests
//
//  Tests to ensure that constrained generators never produce values
//  that violate their specified constraints.
//

import Testing
@testable import Exhaust

@Suite("Constraint Violation Prevention")
struct ConstraintViolationTests {
    @Test("Range-constrained generators never exceed bounds")
    func rangeBoundsNeverViolated() {
        let gen = Gen.choose(in: 10 ... 50)
        var iterator = ValueInterpreter(gen)

        // Generate many values to test constraint
        for _ in 0 ..< 100 {
            let value = iterator.next()!
            #expect(value >= 10)
            #expect(value <= 50)
        }
    }

    @Test("Array size constraints never violated")
    func arraySizeConstraintsNeverViolated() {
        let gen = Int.arbitrary.proliferate(with: 3 ... 7)
        var iterator = ValueInterpreter(gen)

        // Generate many arrays
        for _ in 0 ..< 50 {
            let array = iterator.next()!
            #expect(array.count >= 3)
            #expect(array.count <= 7)
        }
    }

    @Test("Filtered generators never produce filtered values")
    func filteredGeneratorsNeverViolate() {
        // Generator for even numbers only
        let evenGen = Int.arbitrary.map { $0 &* 2 }
        var iterator = ValueInterpreter(evenGen)

        // All generated values must be even
        for _ in 0 ..< 50 {
            let value = iterator.next()!
            #expect(value % 2 == 0)
        }
    }

    @Test("Mapped generators preserve constraints")
    func mappedGeneratorConstraints() {
        // Generator that produces only positive values after mapping
        let positiveGen = UInt32.arbitrary.map { Int($0) + 1 }
        var iterator = ValueInterpreter(positiveGen)

        for _ in 0 ..< 50 {
            let value = iterator.next()!
            #expect(value > 0)
        }
    }

    @Test("Bound generators respect all constraints")
    func boundGeneratorConstraints() {
        // Generator that produces pairs where second > first
        let orderedPairGen = Gen.choose(in: 1 ... 100).bind { first in
            Gen.choose(in: (first + 1) ... 200).map { second in
                (first, second)
            }
        }

        var iterator = ValueInterpreter(orderedPairGen)
        for _ in 0 ..< 50 {
            let (first, second) = iterator.next()!
            #expect(second > first)
            #expect(first >= 1)
            #expect(first <= 100)
            #expect(second <= 200)
        }
    }

    @Test("String length constraints never violated")
    func stringLengthConstraints() {
        // This test assumes you have a way to constrain string length
        // Adapt based on your actual string generation API
        let shortStringGen = Gen.chooseCharacter(in: 0 ... 30).map(String.init)

        var iterator = ValueInterpreter(shortStringGen)
        for _ in 0 ..< 30 {
            let str = iterator.next()!
            #expect(str.count <= 10)
        }
    }

//    @Test("Nested constraint combinations never violated")

//    @Test("Choice generators respect value constraints")
//    func testChoiceGeneratorConstraints() throws {
//        let allowedValues = [2, 4, 6, 8, 10]
//        let choiceGen = Gen.arrayOf(Gen.choose(1...5).map { $0 * 2}, 5...5)
//
//        for _ in 0..<50 {
//            let value = try #require(Interpreters.generate(choiceGen))
//            #expect(allowedValues.contains(value))
//        }
//    }

    @Test("Zipped generators maintain individual constraints")
    func zippedGeneratorConstraints() {
        let positiveGen = Gen.choose(in: 1 ... 100)
        let evenGen = Gen.choose(in: 0 ... 50).map { $0 * 2 }
        let shortArrayGen = String.arbitrary.proliferate(with: 1 ... 3)

        let combinedGen = Gen.zip(positiveGen, evenGen, shortArrayGen)

        var iterator = ValueInterpreter(combinedGen)
        for _ in 0 ..< 30 {
            let (positive, even, array) = iterator.next()!

            #expect(positive >= 1)
            #expect(positive <= 100)
            #expect(even % 2 == 0)
            #expect(even >= 0)
            #expect(even <= 100)
            #expect(array.count >= 1)
            #expect(array.count <= 3)
        }
    }
}
