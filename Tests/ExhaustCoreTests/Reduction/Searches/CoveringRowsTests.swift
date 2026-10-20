import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Covering rows")
struct CoveringRowsTests {
    @Test("Exhaustive integer covering visits every value in positive-first shortlex order")
    func integerCoveringOrder() throws {
        // Widths stay within the exhaustive regime; lower bounds span all-negative, straddling, and all-positive ranges.
        let maximumWidth = Int(ReductionTuning().coveringExhaustiveThreshold) - 1
        let ranges = Gen.zip(
            Gen.choose(in: -40 ... 40) as Generator<Int>,
            Gen.choose(in: 0 ... maximumWidth) as Generator<Int>,
            Gen.choose(in: 0 ... maximumWidth) as Generator<Int>
        )
        try exhaustCheck(ranges, maxIterations: 500) { lower, width, initialOffset in
            let range = Int64(lower) ... Int64(lower + width)
            let initial = range.lowerBound + Int64(initialOffset % (width + 1))
            let sequence = ChoiceSequence(.choice(
                ChoiceValue(initial, tag: .int64),
                .init(validRange: range.lowerBound.bitPattern64 ... range.upperBound.bitPattern64, isRangeExplicit: true)
            ))
            var rows = CoveringRows(tuning: .init(), rowCache: CoveringRowCache())
            rows.start(sequence: sequence, positions: [0])
            var values: [Int64] = []
            while let candidate = rows.nextProbe(lastAccepted: false) {
                guard let value = candidate[0].value?.choice.decodedSignedValue else {
                    return false
                }
                values.append(value)
            }
            let expected = range.sorted {
                ChoiceValue($0, tag: .int64).shortLexCompare(ChoiceValue($1, tag: .int64)) == .lt
            }
            return values == expected
        }
    }
}
