import ExhaustCore
import Testing

@Suite("CGS constrained generation review")
struct CGSConstrainedGenerationReviewTests {
    @Test("Online CGS isolates equal-range chooseBits sites")
    func onlineCGSIsolatesEqualRangeChooseBitsSites() throws {
        let subdivisionsPerSite = 4
        let siteCount = 2
        let accumulator = FitnessAccumulator()
        let generator = Gen.zip(
            Gen.choose(in: UInt64(0) ... 15),
            Gen.choose(in: UInt64(0) ... 15)
        )
        var interpreter = OnlineCGSInterpreter(
            generator,
            predicate: { values in
                values.0 < 4 && values.1 >= 12
            },
            sampleCount: 8,
            seed: 42,
            maxRuns: 1,
            fitnessAccumulator: accumulator,
            subdivisionThresholds: .relaxed
        )

        _ = try interpreter.next()

        #expect(accumulator.records.count == subdivisionsPerSite * siteCount)
    }

    @Test("Online CGS preserves choice-sequence uniqueness for non-Hashable values")
    func onlineCGSPreservesChoiceSequenceUniqueness() throws {
        let generator = ReflectiveGenerator(
            Gen.just(NonHashableValue(value: 42))
        ).unique().gen
        var interpreter = OnlineCGSInterpreter(
            generator,
            predicate: { _ in true },
            sampleCount: 2,
            seed: 42,
            maxRuns: 3
        )

        var generatedValues = [NonHashableValue]()
        while let value = try interpreter.next() {
            generatedValues.append(value)
        }

        #expect(generatedValues.count == 1)
    }

    @Test("Sequential exploration charges warm-up samples to the shared attempt budget")
    func sequentialExplorationChargesWarmupToAttemptBudget() throws {
        let maxAttemptsPerDirection = 1
        var runner = ClassificationExploreRunner(
            gen: Gen.just(0),
            property: { _ in true },
            directions: [
                (name: "unreachable", predicate: { _ in false }),
            ],
            hitsPerDirection: 1,
            maxAttemptsPerDirection: maxAttemptsPerDirection,
            seed: 42
        )

        let result = try runner.run()

        #expect(result.propertyInvocations <= maxAttemptsPerDirection)
    }
}

private struct NonHashableValue: Equatable {
    let value: Int
}
