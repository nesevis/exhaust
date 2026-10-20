import Exhaust
import Testing

@Suite("Float cancellation reduction")
struct FloatCancellationReductionTests {
    @Test("Independent seeds reduce cancellation to unit rounding boundaries", arguments: Array(UInt64(1337) ..< 1437))
    func generatedCancellation(seed: UInt64) throws {
        let doubleGenerator = #gen(.double(in: -1e6 ... 1e6, scaling: .exponential))
        let generator = #gen(doubleGenerator, doubleGenerator)
        let property: @Sendable ((Double, Double)) -> Bool = { values in
            (values.0 + values.1) - values.1 == values.0
        }
        // Sampling only, so each seed reduces the first failure its random generation finds rather than a boundary row.
        let counterexample = #exhaust(
            generator,
            .replay(.numeric(seed)),
            .budget(.custom(screening: 0, sampling: 10000)),
            .suppress(.issueReporting)
        ) { values in
            property(values)
        }
        let output = try #require(counterexample, "No cancellation failure found for seed \(seed)")
        #expect(property(output) == false)
        #expect(output.0 == 1 && output.1 == 1.0.nextUp)
    }
}
