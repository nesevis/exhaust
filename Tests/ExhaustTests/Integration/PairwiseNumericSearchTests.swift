import Exhaust
import Testing

@Suite("Pairwise numeric search integration")
struct PairwiseNumericSearchIntegrationTests {
    @Test("Weighted equality reaches its smallest tuple", arguments: [1, 2, 3, 5, 10])
    func weightedEquality(source: Int) throws {
        let result = #exhaust(
            WeightedLinearPreservationChallenge.gen,
            reflecting: (source, 0, 20 - source * 2),
            .suppress(.all)
        ) { first, second, third in
            WeightedLinearPreservationChallenge.property(first, second, third)
        }
        let counterexample = try #require(result)
        #expect(counterexample.0 == 0)
        #expect(counterexample.1 == 0)
        #expect(counterexample.2 == 20)
    }
}

private enum WeightedLinearPreservationChallenge {
    static let intGen = #gen(.int(in: 0 ... 20))
    static let gen = #gen(intGen, intGen, intGen)

    static let property: @Sendable (Int, Int, Int) -> Bool = {
        $0 * 2 + $1 + $2 != 20
    }
}
