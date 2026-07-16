import Exhaust
import Testing

@Suite("Bound-range shortlex regressions", .serialized)
struct BoundRangeShortlexRegressionTests {
    @Test(
        "boundArray(boundRange) reduction preserves the minimal failing length",
        arguments: [
            (range: -89 ... -63, maxLength: 3),
            (range: -89 ... -63, maxLength: 4),
            (range: -89 ... -63, maxLength: 5),
            (range: -96 ... -46, maxLength: 3),
        ]
    )
    func boundArrayBoundRangeReduction(
        range: ClosedRange<Int>,
        maxLength: Int
    ) {
        let gen = #gen(.uint64(in: 0 ... UInt64(maxLength))).bind { length in
            boundRangeGen(range).array(length: Int(length))
        }
        let result = #exhaust(
            gen,
            .replay(.numeric(4)),
            .budget(.custom(screening: 0, sampling: 5)),
            .log(.debug),
            .suppress(.issueReporting)
        ) { values in
            values.count < 2
        }

        #expect(result?.count == 2)
    }
}

// MARK: - Helpers

private func boundRangeGen(_ range: ClosedRange<Int>) -> ReflectiveGenerator<Int> {
    #gen(.int(in: range)).bind { lowerBound in
        #gen(.int(in: lowerBound ... (lowerBound + 50)))
    }
}
