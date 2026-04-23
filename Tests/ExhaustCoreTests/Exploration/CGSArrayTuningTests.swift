import ExhaustCore
import Foundation
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
            warmupRuns: 400,
            sampleCount: 10,
            seed: 42,
            subdivisionThresholds: .relaxed
        )

        let tunedDescription = tuned.debugDescription
        #expect(tunedDescription.contains("pick"), "Tuned generator should contain pick nodes from subdivision")

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

    @Test("Tuning steers element values toward predicate-satisfying arrays")
    func tuneArrayElementValues() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            within: 3 ... 5
        )

        let tuned = try ChoiceGradientTuner.tune(
            gen,
            predicate: { (array: [Int]) in array.allSatisfy { $0 > 80 } },
            warmupRuns: 100,
            sampleCount: 20,
            seed: 42,
            subdivisionThresholds: .relaxed
        )

        var interpreter = ValueAndChoiceTreeInterpreter(
            tuned,
            materializePicks: false,
            seed: 42,
            maxRuns: 50
        )

        var highValueCount = 0
        var totalCount = 0
        while let (value, _) = try? interpreter.next() {
            totalCount += 1
            if value.allSatisfy({ $0 > 80 }) {
                highValueCount += 1
            }
        }

        let hitRate = Double(highValueCount) / Double(totalCount)
        let untunedBaseline = pow(20.0 / 101.0, 3.0)
        #expect(hitRate > untunedBaseline, "Tuned hit rate (\(hitRate)) should exceed untuned baseline (\(untunedBaseline))")
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
