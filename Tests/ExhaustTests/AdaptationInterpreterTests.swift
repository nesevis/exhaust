//
//  AdaptationInterpreterTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/8/2025.
//

import Testing
@testable import Exhaust

@Suite("Adaptation Interpreter")
struct AdaptationInterpreterTests {
    
    @Test("Kicking tyres!")
    func kickingTyres() throws {
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 1...1000).map { $0 * 2 }),
            (1, Gen.pick(choices: [
                (1, Gen.choose(in: 1...1000)),
                (1, Gen.choose(in: 1...1000).map { $0 * 4 })
            ]))
        ])
        
        let predicate: (Int) -> Bool = {
            $0.isMultiple(of: 2) && $0 < 500
        }
        
        let result = try SpeculativeAdaptationInterpreter.adapt(original: gen, input: (), samples: 100, choiceTree: .just(""), predicate)
    
        
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
        let lengthGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1...50)
        let elementGen = Gen.choose(in: 1...10)
        let gen: ReflectiveGenerator<[Int]> = .impure(
            operation: .sequence(
                length: lengthGen,
                gen: elementGen.erase()
            )
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
            input: (),
            samples: 100, // Increase samples for better statistical significance
            choiceTree: .just(""),
            predicate
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
}
