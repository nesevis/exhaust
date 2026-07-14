import Exhaust
import ExhaustCore
import Testing

@Suite("Unique tuning integration")
struct UniqueTuningIntegrationTests {
    @Test("VACTI deduplicates a tuned generator with non-Hashable output")
    func valueAndChoiceTreeInterpreterDeduplicatesTunedGenerator() throws {
        let generator = ReflectiveGenerator(
            Gen.just(NonHashableTunedValue(value: 42))
        ).unique().gen
        let tunedGenerator = try ChoiceGradientTuner.tune(
            generator,
            predicate: { _ in true },
            warmupRuns: 3,
            sampleCount: 2,
            seed: 42
        )
        var interpreter = ValueAndChoiceTreeInterpreter(
            tunedGenerator,
            seed: 42,
            maxRuns: 3
        )

        var generatedValues = [NonHashableTunedValue]()
        while let (value, _) = try interpreter.next() {
            generatedValues.append(value)
        }

        #expect(generatedValues.count == 1)
        #expect(generatedValues[0].value == 42)
    }
}

private struct NonHashableTunedValue: Sendable {
    let value: Int
}
