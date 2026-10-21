import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Redistribution Conservation Properties")
struct RedistributionConservationPropertyTests {
    @Test("Integer transfers conserve the sum and move by the requested delta", arguments: IntegerTransferDomain.all)
    private func transferContract(domain: IntegerTransferDomain) throws {
        // Bounded magnitudes keep both results and their sum representable; overflow rejection has separate boundary tests.
        let transfers = Gen.zip(
            Gen.choose(in: Int64(1) ... 1000),
            Gen.choose(in: domain.sinkRange),
            Gen.choose(from: domain.sourceSigns)
        ).bind { magnitude, sink, sign in
            Gen.choose(in: UInt64(1) ... UInt64(magnitude)).map { delta in
                (source: magnitude * sign, sink: sink, delta: delta)
            }
        }
        try exhaustCheck(transfers, maxIterations: 500) { transfer in
            let source = domain.encode(transfer.source)
            let sink = domain.encode(transfer.sink)
            let context = try #require(RedistributionSearch.makeMixedRedistributionContext(
                sourceChoice: source,
                sinkChoice: sink,
                sourceValidRange: nil,
                sourceIsRangeExplicit: false
            ))
            let (newSource, newSink) = try #require(RedistributionSearch.mixedRedistributedPairChoices(
                sourceChoice: source,
                sinkChoice: sink,
                delta: transfer.delta,
                context: context
            ))
            let sourceValue = domain.decode(newSource)
            let sinkValue = domain.decode(newSink)
            let movement = transfer.source > 0 ? Int64(transfer.delta) : -Int64(transfer.delta)
            return sourceValue == transfer.source - movement
                && sinkValue == transfer.sink + movement
                && sourceValue + sinkValue == transfer.source + transfer.sink
                && abs(sourceValue) < abs(transfer.source)
        }
    }
}

// MARK: - Fixtures

private struct IntegerTransferDomain: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let sinkRange: ClosedRange<Int64>
    let sourceSigns: [Int64]
    let encode: @Sendable (Int64) -> ChoiceValue
    let decode: @Sendable (ChoiceValue) -> Int64

    static let all: [Self] = [
        .init(
            testDescription: "signed 64-bit",
            sinkRange: -1000 ... 1000,
            sourceSigns: [-1, 1],
            encode: { ChoiceValue($0, tag: .int64) },
            decode: { $0.decodedSignedValue }
        ),
        .init(
            testDescription: "unsigned 64-bit",
            sinkRange: 0 ... 999,
            sourceSigns: [1],
            encode: { ChoiceValue(UInt64($0), tag: .uint64) },
            decode: { Int64($0.bitPattern64) }
        ),
    ]
}
