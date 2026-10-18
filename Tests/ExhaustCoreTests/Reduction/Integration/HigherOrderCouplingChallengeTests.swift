import Testing
@testable import ExhaustCore

@Suite("Harder higher-order coupling challenges")
struct HigherOrderCouplingChallengeTests {
    @Test("Shifted power curves require every determining coordinate to move", arguments: Coupling.allCases)
    func genuineCoordination(coupling: Coupling) {
        let initial = coupling.counterexample(source: 75)
        let minimum = coupling.counterexample(source: 1)
        #expect(coupling.property(initial) == false)
        #expect(coupling.property(minimum) == false)
        #expect(coupling.property(initial.map { $0 / 2 }))
        #expect(coupling.property(Array(repeating: 1, count: initial.count)))
        let divisor = initial.reduce(UInt64(0)) { ReductionIntegerMath.greatestCommonDivisor($0, UInt64($1)) }
        #expect(divisor == 1)
        // Each coordinate is injective in the positive source, so keeping any coordinate fixes the entire failing tuple.
        for source in 1 ..< 75 {
            let reduced = coupling.counterexample(source: source)
            #expect(coupling.property(reduced) == false)
            #expect(zip(initial, reduced).allSatisfy { $0 != $1 })
        }
        for mask in 1 ..< (1 << initial.count) - 1 {
            let partial = initial.indices.map { index in
                mask & (1 << index) == 0 ? initial[index] : minimum[index]
            }
            #expect(coupling.property(partial))
        }
    }

    /// Supplies a known minimum and an injective failure curve, rather than a lookup table of two specially chosen assignments. All arithmetic fits `Int64` throughout the declared domains.
    enum Coupling: CaseIterable {
        case shiftedPowers
        case conservedSumAndPowers

        /// Constructs the unique failing tuple for a positive source.
        func counterexample(source: Int) -> [Int] {
            let square = source * source + 1
            let cube = source * source * source + 2
            return switch self {
                case .shiftedPowers:
                    [source, square, cube]
                case .conservedSumAndPowers:
                    [source, 101 - source, square, cube]
            }
        }

        /// Fails only when every coordinate lies on the same shifted power curve.
        func property(_ values: [Int]) -> Bool {
            let source = values[0]
            return switch self {
                case .shiftedPowers:
                    values[1] != source * source + 1 || values[2] != source * source * source + 2
                case .conservedSumAndPowers:
                    source + values[1] != 101 || values[2] != source * source + 1 || values[3] != source * source * source + 2
            }
        }
    }
}
