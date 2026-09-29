//
//  SymptomPreservingReductionTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Fuzz reduction preserves the failure's symptom")
struct SymptomPreservingReductionTests {
    @Test("A failure reduces to its own fault's minimal form, not into a smaller fault with another symptom", arguments: [
        (UInt64(700), FailureSymptom.thrown(HighFault()), UInt64(500)),
        (UInt64(300), FailureSymptom.thrown(LowFault()), UInt64(10)),
    ])
    func reductionStaysInTheFaultsBasin(start: UInt64, symptom: FailureSymptom, expected: UInt64) throws {
        let generator = Gen.choose(in: UInt64(0) ... 1000)
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        let reduce = FuzzRunner<UInt64>.propertyOnlyReduceStrategy(
            gen: generator,
            property: twoFaultVerdict,
            reducerConfiguration: Interpreters.ReducerConfiguration(maxStalls: 2)
        )

        let result = reduce(tree, start, symptom, nil)

        #expect(result.value == expected)
    }
}

// MARK: - Supporting Types

/// Thrown for values of 500 and above.
private struct HighFault: Error {}

/// Thrown for values from 10 up to 500. Its minimal form, 10, is shortlex-smaller than every ``HighFault`` failure, so reducing on "still fails" alone walks a ``HighFault`` failure into it.
private struct LowFault: Error {}

// MARK: - Helpers

private let twoFaultVerdict: @Sendable (UInt64) -> FuzzVerdict = { value in
    if value >= 500 {
        return .fail(.thrown(HighFault()))
    }
    if value >= 10 {
        return .fail(.thrown(LowFault()))
    }
    return .pass
}
