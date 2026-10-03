import Exhaust
import Testing

@Suite("Recurring zip reduction")
struct RecurringZipReductionTests {
    @Test("Recurring zipped scores reduce together while per-node markers and recursive shape stay fixed", arguments: [1, -1])
    func recursiveFieldsReduce(score: Int) throws {
        let generator: ReflectiveGenerator<RecurringRecord> = .recursive(baseValue: .end, depthRange: 0 ... 5) { recurse, _ in
            .oneOf(
                .just(.end),
                #gen(.int(in: -2 ... 2), .int(in: -2 ... 2), recurse()) { score, marker, child in
                    RecurringRecord.node(score: score, marker: marker, child: child)
                }
            )
        }
        let markers = [score, score * 2, score]
        let start = recurringChain(score: score, markers: markers)
        let counterexample = #exhaust(generator, reflecting: start, .suppress(.all)) { record in
            let fields = record.fields
            return (
                fields.count == markers.count && fields.enumerated().allSatisfy { ordinal, field in
                    field.score == fields[0].score && field.marker == markers[ordinal]
                }
            ) == false
        }
        let reduced = try #require(counterexample)
        #expect(reduced == recurringChain(score: 0, markers: markers))
    }
}

private indirect enum RecurringRecord: Equatable {
    case end
    case node(score: Int, marker: Int, child: RecurringRecord)

    var fields: [(score: Int, marker: Int)] {
        switch self {
            case .end:
                return []
            case let .node(score, marker, child):
                return [(score: score, marker: marker)] + child.fields
        }
    }
}

private func recurringChain(score: Int, markers: [Int]) -> RecurringRecord {
    markers.reversed().reduce(.end) { child, marker in
        .node(score: score, marker: marker, child: child)
    }
}
