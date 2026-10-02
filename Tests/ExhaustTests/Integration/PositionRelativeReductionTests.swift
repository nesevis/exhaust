import Exhaust
import Testing

@Suite("Position-relative reduction")
struct PositionRelativeReductionTests {
    @Test("Corresponding signed fields reduce while same-valued decoys stay fixed", arguments: [2, 3, 5], [false, true])
    func signedFieldsReduce(count: Int, varyingDecoys: Bool) throws {
        let record = #gen(.int(in: 0 ... 2), .int(in: 0 ... 2))
            .mapped(
                forward: { score, marker in PositionRecord(score: score, marker: marker) },
                backward: { ($0.score, $0.marker) }
            )
        let markers = (0 ..< count).map { varyingDecoys && $0 % 2 == 1 ? 2 : 1 }
        let start = markers.map { PositionRecord(score: 1, marker: $0) }
        let counterexample = #exhaust(record.array(length: count), reflecting: start, .suppress(.all)) { records in
            records.enumerated().allSatisfy { ordinal, record in
                record.score == records[0].score && record.marker == markers[ordinal]
            } == false
        }
        let reduced = try #require(counterexample)
        #expect(reduced == markers.map { PositionRecord(score: 0, marker: $0) })
    }

    @Test("Corresponding negative fields reach zero while unequal negative decoys stay fixed", arguments: [2, 3, 5])
    func negativeFieldsReduce(count: Int) throws {
        let record = #gen(.int(in: -2 ... 2), .int(in: -2 ... 2))
            .mapped(
                forward: { score, marker in PositionRecord(score: score, marker: marker) },
                backward: { ($0.score, $0.marker) }
            )
        let markers = (0 ..< count).map { -($0 % 2 + 1) }
        let start = markers.map { PositionRecord(score: -1, marker: $0) }
        let counterexample = #exhaust(record.array(length: count), reflecting: start, .suppress(.all)) { records in
            records.enumerated().allSatisfy { ordinal, record in
                record.score == records[0].score && record.marker == markers[ordinal]
            } == false
        }
        let reduced = try #require(counterexample)
        #expect(reduced == markers.map { PositionRecord(score: 0, marker: $0) })
    }

    @Test("Corresponding unsigned fields reduce even when whole records differ", arguments: [2, 3, 5])
    func unsignedFieldsReduce(count: Int) throws {
        let record = #gen(.uint64(in: 0 ... 2), .uint64(in: 0 ... 2))
            .mapped(
                forward: { score, marker in PositionRecord(score: score, marker: marker) },
                backward: { ($0.score, $0.marker) }
            )
        let markers = (0 ..< count).map { UInt64($0 % 2 + 1) }
        let start = markers.map { PositionRecord(score: UInt64(1), marker: $0) }
        let counterexample = #exhaust(record.array(length: count), reflecting: start, .suppress(.all)) { records in
            records.enumerated().allSatisfy { ordinal, record in
                record.score == records[0].score && record.marker == markers[ordinal]
            } == false
        }
        let reduced = try #require(counterexample)
        #expect(reduced == markers.map { PositionRecord(score: UInt64(0), marker: $0) })
    }
}

private struct PositionRecord<Value: Equatable>: Equatable {
    let score: Value
    let marker: Value
}
