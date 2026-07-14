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

    @Test("Online CGS treats choice-sequence uniqueness as tuning-transparent")
    func onlineCGSTreatsChoiceSequenceUniquenessAsTransparent() throws {
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

        #expect(generatedValues.count == 3)

        let hashableGenerator = ReflectiveGenerator(Gen.just(42)).unique().gen
        var hashableInterpreter = OnlineCGSInterpreter(
            hashableGenerator,
            predicate: { _ in true },
            sampleCount: 2,
            seed: 42,
            maxRuns: 3
        )
        var hashableValues = [Int]()
        while let value = try hashableInterpreter.next() {
            hashableValues.append(value)
        }

        #expect(hashableValues == [42, 42, 42])
    }

    @Test("Sequential exploration accounts for warm-up outside the direction attempt pool")
    func sequentialExplorationAccountsForWarmupOutsideAttemptPool() throws {
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

        #expect(result.warmupSamples == 100)
        #expect(result.directionCoverage[0].tuningPassSamples == maxAttemptsPerDirection)
        #expect(result.propertyInvocations == 100 + maxAttemptsPerDirection)
    }
}

private struct NonHashableValue: Equatable {
    let value: Int
}
