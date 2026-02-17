//
//  AdaptationInterpreterTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/8/2025.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Adaptation Interpreter", .disabled("Not used"))
struct AdaptationInterpreterTests {
    @Test("CGS Test")
    func cgsTest() throws {
        let gen = Gen.zip(Gen.choose(in: UInt(1) ... 2000), Gen.just("Heyo"))
        let predicate: ((UInt, String)) -> Bool = { $0.0 < 150 }
        let result = try CGSAdaptationInterpreter.adapt(original: gen, predicate)
        let valueIterator = ValueInterpreter(result, maxRuns: 100)

        var results = [Bool]()
        for value in valueIterator {
            results.append(predicate(value))
        }

        print("Result: \(result.debugDescription)")
//        print("true: \(results.count(where: { $0 }))/\(valueIterator.context.maxRuns)")
    }

    @Test("GetSize")
    func getSize() throws {
        let arrGen = Gen.arrayOf(UInt64.arbitrary)
        let predicate: ([UInt64]) -> Bool = { $0.count < 5 }
        let result = try SpeculativeAdaptationInterpreter.adapt(original: arrGen, predicate)

        let valueIterator = ValueInterpreter(result, maxRuns: 100)

        var results = [Bool]()
        for value in valueIterator {
//            print(value)
            results.append(predicate(value))
        }

        print("Result: \(result.debugDescription)")
        print("true: \(results.count(where: { $0 }))")
        print("false: \(results.count(where: { !$0 }))")
    }

    @Test("Kicking tyres!")
    func kickingTyres() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1 ... 1000).map { $0 * 2 }),
            (1, Gen.pick(choices: [
                (1, Gen.choose(in: 1 ... 1000)),
                (1, Gen.choose(in: 1 ... 1000).map { $0 * 4 }),
            ])),
        ])

        let predicate: (Int) -> Bool = {
            $0.isMultiple(of: 2) && $0 < 500
        }

        let result = try SpeculativeAdaptationInterpreter.adapt(original: gen, samples: 100, predicate)

        let valueIterator = ValueInterpreter(result, maxRuns: 100)

        var results = [Bool]()
        for value in valueIterator {
//            print(value)
            results.append(predicate(value))
        }

        print("Result: \(result.debugDescription)")
        print("true: \(results.count(where: { $0 }))")
        print("false: \(results.count(where: { !$0 }))")
    }

    @Test("Sequence length adaptation")
    func sequenceLengthAdaptation() throws {
        // Create a direct sequence generator with chooseBits for length to test subdivision
        let lengthGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1 ... 50)
        let elementGen = Gen.choose(in: 1 ... 10)
        let gen: ReflectiveGenerator<[Int]> = .impure(
            operation: .sequence(
                length: lengthGen,
                gen: elementGen.erase(),
            ),
        ) { result in
            guard let array = result as? [Int] else {
                throw GeneratorError.typeMismatch(expected: "Array<Int>", actual: String(describing: type(of: result)))
            }
            return .pure(array)
        }

        // Predicate that strongly favors very short arrays (length <= 3)
        let predicate: ([Int]) -> Bool = { array in
            array.count <= 3
        }

        let result = try SpeculativeAdaptationInterpreter.adapt(
            original: gen,
            samples: 100, // Increase samples for better statistical significance
            predicate,
        )

        let valueIterator = ValueInterpreter(result, maxRuns: 200)

        var results = [Bool]()
        var lengths = [Int]()
        for value in valueIterator {
            results.append(predicate(value))
            lengths.append(value.count)
        }

        print("Original generator: \(gen.debugDescription)")
        print("Sequence adaptation result: \(result.debugDescription)")
        print("true: \(results.count(where: { $0 }))")
        print("false: \(results.count(where: { !$0 }))")
        print("Average length: \(Double(lengths.reduce(0, +)) / Double(lengths.count))")
        print("Length distribution: \(Dictionary(grouping: lengths, by: { $0 }).mapValues { $0.count })")

        // Should generate mostly short arrays
        let shortArrays = results.count(where: { $0 })
        let totalArrays = results.count
        let successRate = Double(shortArrays) / Double(totalArrays)
        print("Success rate: \(successRate)")
    }

    @Test("Zip adaptation with focused components")
    func zipAdaptationWithFocusedComponents() throws {
        // Create a zip with three independent components
        let intGen1 = Gen.choose(in: 1 ... 100)
        let intGen2 = Gen.choose(in: 1 ... 100)
        let arrayGen: ReflectiveGenerator<[Int]> = .impure(
            operation: .sequence(
                length: Gen.choose(in: 1 ... 50),
                gen: Gen.choose(in: 1 ... 10).erase(),
            ),
        ) { result in
            guard let array = result as? [Int] else {
                throw GeneratorError.typeMismatch(expected: "Array<Int>", actual: String(describing: type(of: result)))
            }
            return .pure(array)
        }

        // Create a zip generator that produces tuples of (Int, Int, [Int])
        let zipGen: ReflectiveGenerator<(Int, Int, [Int])> = .impure(
            operation: .zip(ContiguousArray([
                intGen1.erase(),
                intGen2.erase(),
                arrayGen.erase(),
            ])),
        ) { result in
            guard let values = result as? [Any],
                  values.count == 3,
                  let v1 = values[0] as? Int,
                  let v2 = values[1] as? Int,
                  let v3 = values[2] as? [Int]
            else {
                throw GeneratorError.typeMismatch(expected: "(Int, Int, [Int])", actual: String(describing: type(of: result)))
            }
            return .pure((v1, v2, v3))
        }

        // Predicate that only depends on the third component (array length)
        // The first two components are irrelevant
        let predicate: ((Int, Int, [Int])) -> Bool = { tuple in
            tuple.2.count <= 3
        }

        let result = try SpeculativeAdaptationInterpreter.adapt(
            original: zipGen,
            samples: 100,
            predicate,
        )

        let valueIterator = ValueInterpreter(result, maxRuns: 200)

        var results = [Bool]()
        var arrayLengths = [Int]()
        for value in valueIterator {
            results.append(predicate(value))
            arrayLengths.append(value.2.count)
        }

        print("Zip adaptation result: \(result.debugDescription)")
        print("true: \(results.count(where: { $0 }))")
        print("false: \(results.count(where: { !$0 }))")
        print("Average array length: \(Double(arrayLengths.reduce(0, +)) / Double(arrayLengths.count))")
        print("Length distribution: \(Dictionary(grouping: arrayLengths, by: { $0 }).mapValues { $0.count })")

        // CGS should discover that the third component (array) is what matters
        // and focus adaptation effort there
        let successRate = Double(results.count(where: { $0 })) / Double(results.count)
        print("Success rate: \(successRate)")
    }

//    @Test("CGS adaptation versus rejection sampling")
//    func testCGSAdaptationVsRejectionSampling() async throws {
//        let naive = BinarySearchTree<UInt>.arbitrary
//
//        let validBst: (BinarySearchTree<UInt>) -> Bool = { tree in
//            return tree.isValidBST() && tree != .leaf
//        }
//
//        var start = Date()
//        let rejectionSampled = naive.filter(validBst)
//        let rejection = ValueInterpreter(rejectionSampled, maxRuns: 100000)
//        let rsampled = Array(rejection)
//        let results = rsampled.map { validBst($0) }
//        print("Rejection sampling: true \(results.count(where: { $0 })) false: \(results.count(where: { !$0 }))")
//        print("Rejection sampling: Unique BSTs: \(Set(rsampled.filter(validBst)).count)")
//        print("Rejection sampling: \(Date().timeIntervalSince(start) * 1000)ms")
//
//        start = Date()
//        let adapted = try SpeculativeAdaptationInterpreter.adapt(original: naive, samples: 1000, validBst)
//        print("CGS: adaptation \(Date().timeIntervalSince(start) * 1000)ms")
//        start = Date()
//        let cgs = ValueInterpreter(adapted, maxRuns: 100000)
//        let cgsArr = Array(cgs)
//        var cgsResults = cgsArr.map { validBst($0) }
    ////        print("CGS: \(adapted.debugDescription)")
//        print("CGS sampling: true \(cgsResults.count(where: { $0 })) false: \(cgsResults.count(where: { !$0 }))")
//        print("CGS: Unique BSTs: \(Set(cgsArr.filter(validBst)).count)")
//        print("CGS: \(Date().timeIntervalSince(start) * 1000)ms")
//
//        print("Rejection: \(rejectionSampled.debugDescription)")
//        print("CGS: \(adapted.debugDescription)")
//    }
}
