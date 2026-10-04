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

    @Test("A distant partner is searched when more stalled sources than the pair cap sit between them", arguments: [1, 5, 10])
    func distantPartnerBeyondAdjacentCap(source: Int) throws {
        let padding = Array(repeating: 1, count: WeightedLinearPreservationChallenge.paddingCount)
        let result = #exhaust(
            WeightedLinearPreservationChallenge.paddedGen,
            reflecting: [source] + padding + [20 - source * 2],
            .suppress(.all)
        ) { values in
            WeightedLinearPreservationChallenge.paddedProperty(values)
        }
        let counterexample = try #require(result)
        #expect(counterexample == [0] + padding + [20])
    }
}

private enum WeightedLinearPreservationChallenge {
    static let intGen = #gen(.int(in: 0 ... 20))
    static let gen = #gen(intGen, intGen, intGen)

    static let property: @Sendable (Int, Int, Int) -> Bool = {
        $0 * 2 + $1 + $2 != 20
    }

    /// More than the 30-pair cap, so the middle values alone supply enough stalled sources to fill it with adjacent pairs.
    static let paddingCount = 31
    static let paddedGen = #gen(.int(in: 0 ... 20).array(length: paddingCount + 2))

    /// Fails only while every middle value is one, so the first value can trade only with the last.
    static let paddedProperty: @Sendable ([Int]) -> Bool = { values in
        let middle = values.dropFirst().dropLast()
        return middle.allSatisfy { $0 == 1 } == false || values[0] * 2 + values[values.count - 1] != 20
    }
}
