import Exhaust
import ExhaustCore
import Testing

@Suite("Float cancellation reduction")
struct FloatCancellationReductionTests {
    @Test("Independent seeds reduce cancellation to unit rounding boundaries", arguments: Array(UInt64(1337) ..< 1437))
    func generatedCancellation(seed: UInt64) throws {
        let doubleGenerator = #gen(.double(in: -1e6 ... 1e6, scaling: .exponential))
        let generator = #gen(doubleGenerator, doubleGenerator).gen
        let property: ((Double, Double)) -> Bool = { values in
            (values.0 + values.1) - values.1 == values.0
        }
        var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: seed, maxRuns: 10000)
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else {
                continue
            }
            let result = Interpreters.choiceGraphReduce(
                gen: generator,
                tree: tree,
                output: value,
                config: .init(maxStalls: 2),
                property: property
            )
            let output = try #require(result.counterexample?.1)
            #expect(property(output) == false)
            #expect(
                (output.0 == 1 && output.1 == 1.0.nextUp)
                    || (output.0 == -1.0.nextUp && output.1 == -1)
            )
            return
        }
        Issue.record("No cancellation failure found for seed \(seed)")
    }
}
