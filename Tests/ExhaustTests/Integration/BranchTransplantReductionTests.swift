import Exhaust
import Testing

@Suite("Branch witness transplantation reduction")
struct BranchTransplantReductionTests {
    @Test("A narrow witness survives a pivot to a smaller representation", arguments: [37, -37], [UInt64(1), 2, 3])
    func witnessSurvivesPivot(witness: Int, seed: UInt64) throws {
        let compact = #gen(.int(in: -1000 ... 1000), .just(0)) { witness, marker in
            TransplantRecord.compact(witness: witness, marker: marker)
        }
        let expanded = #gen(.int(in: -1000 ... 1000), .int(in: 0 ... 1000), .int(in: 0 ... 1000)) { witness, first, second in
            TransplantRecord.expanded(witness: witness, first: first, second: second)
        }
        let counterexample = #exhaust(
            .oneOf(compact, expanded),
            reflecting: TransplantRecord.expanded(witness: witness, first: 0, second: 0),
            .replay(.numeric(seed)),
            .suppress(.all)
        ) { record in
            record.witness != witness
        }
        let reduced = try #require(counterexample)
        #expect(reduced == .compact(witness: witness, marker: 0))
    }

    @Test("The property rejects a transplant when corresponding inputs have different mapped meanings")
    func differingMappingsDoNotPreserveFailure() throws {
        let mappedWitness = #gen(.int(in: -1000 ... 1000)).mapped(
            forward: { $0 + 1 },
            backward: { $0 - 1 }
        )
        let compact = #gen(mappedWitness, .just(0)) { witness, marker in
            TransplantRecord.compact(witness: witness, marker: marker)
        }
        let expanded = #gen(.int(in: -1000 ... 1000), .int(in: 0 ... 1000), .int(in: 0 ... 1000)) { witness, first, second in
            TransplantRecord.expanded(witness: witness, first: first, second: second)
        }
        let start = TransplantRecord.expanded(witness: 37, first: 0, second: 0)
        let property: @Sendable (TransplantRecord) -> Bool = { $0.witness != 37 }
        let counterexample = #exhaust(.oneOf(compact, expanded), reflecting: start, .suppress(.all)) { record in
            property(record)
        }
        let reduced = try #require(counterexample)
        #expect(property(reduced) == false)
        #expect(reduced.witness == 37)
    }
}

private enum TransplantRecord: Equatable {
    case compact(witness: Int, marker: Int)
    case expanded(witness: Int, first: Int, second: Int)

    var witness: Int {
        switch self {
            case let .compact(witness, _), let .expanded(witness, _, _):
                return witness
        }
    }
}
