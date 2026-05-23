import ExhaustCore
import Testing

@Suite("Offset batch reproducibility")
struct OffsetBatchReproducibilityTests {
    @Test
    func `Two offset interpreters with the same seed concatenate to the sequential result`() throws {
        let gen: Generator<Int> = Gen.choose(in: 0 ... 10000)
        let seed: UInt64 = 42
        let totalRuns: UInt64 = 200

        var sequentialValues: [Int] = []
        var sequential = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: totalRuns)
        while let value = try sequential.nextValueOnly() {
            sequentialValues.append(value)
        }

        var firstHalfValues: [Int] = []
        var firstHalf = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 100, initialRunIndex: 0)
        while let value = try firstHalf.nextValueOnly() {
            firstHalfValues.append(value)
        }

        var secondHalfValues: [Int] = []
        var secondHalf = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 200, initialRunIndex: 100)
        while let value = try secondHalf.nextValueOnly() {
            secondHalfValues.append(value)
        }

        #expect(sequentialValues.count == 200)
        #expect(firstHalfValues.count == 100)
        #expect(secondHalfValues.count == 100)
        #expect(sequentialValues == firstHalfValues + secondHalfValues)
    }
}
