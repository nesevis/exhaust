import ExhaustCore
import Testing

@Suite("CGS tuning with array generators")
struct CGSArrayTuningTests {
    @Test("Tuning an array generator with a predicate does not crash")
    func tuneArrayGeneratorWithPredicate() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            within: 1 ... 10
        )

        let tuned = try ChoiceGradientTuner.tune(
            gen,
            predicate: { (array: [Int]) in array.count > 5 },
            warmupRuns: 50,
            sampleCount: 10,
            seed: 42,
            subdivisionThresholds: .relaxed
        )

        var interpreter = ValueAndChoiceTreeInterpreter(
            tuned,
            materializePicks: false,
            seed: 42,
            maxRuns: 20
        )

        var sampledCount = 0
        while let (value, _) = try? interpreter.next() {
            #expect(value.count >= 1)
            #expect(value.count <= 10)
            sampledCount += 1
        }
        #expect(sampledCount == 20)
    }

    @Test("Tuning an array generator with default thresholds does not crash")
    func tuneArrayGeneratorDefaultThresholds() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: -50 ... 50) as ReflectiveGenerator<Int>,
            within: 2 ... 8
        )

        let tuned = try ChoiceGradientTuner.tune(
            gen,
            predicate: { (array: [Int]) in array.reduce(0, +) > 0 },
            warmupRuns: 50,
            sampleCount: 10,
            seed: 42
        )

        var interpreter = ValueAndChoiceTreeInterpreter(
            tuned,
            materializePicks: false,
            seed: 42,
            maxRuns: 10
        )

        var sampledCount = 0
        while let (value, _) = try? interpreter.next() {
            #expect(value.count >= 2)
            #expect(value.count <= 8)
            sampledCount += 1
        }
        #expect(sampledCount == 10)
    }
}
