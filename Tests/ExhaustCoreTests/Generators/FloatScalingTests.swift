import ExhaustCore
import Testing

@Suite("Float Scaling")
struct FloatScalingTests {
    @Test("Exponential scaling keeps generated values within a sub-unit range")
    func exponentialScalingSubUnitRange() throws {
        let gen = Gen.choose(in: 0.0 ... 0.5, scaling: .exponential)
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 500)
        while let value = try iterator.next() {
            #expect(value >= 0.0, "Generated \(value) below lower bound 0.0")
            #expect(value <= 0.5, "Generated \(value) above upper bound 0.5")
        }
    }
}
