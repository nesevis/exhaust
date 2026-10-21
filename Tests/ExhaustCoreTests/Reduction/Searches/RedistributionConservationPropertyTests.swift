import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Redistribution Conservation Properties")
struct RedistributionConservationPropertyTests {
    @Test("Integer transfers conserve the sum and move by the requested delta", arguments: [TypeTag.int64, .uint64])
    func transferContract(tag: TypeTag) throws {
        // Bounded magnitudes keep both results and their sum representable; overflow rejection has separate boundary tests.
        let transfers = Gen.zip(
            Gen.choose(in: Int64(1) ... 1000),
            Gen.choose(in: tag == .int64 ? Int64(-1000) ... 1000 : Int64(0) ... 999),
            Gen.choose(from: tag == .int64 ? [Int64(-1), 1] : [Int64(1)])
        ).bind { magnitude, sink, sign in
            Gen.choose(in: UInt64(1) ... UInt64(magnitude)).map { delta in
                (source: magnitude * sign, sink: sink, delta: delta)
            }
        }
        try exhaustCheck(transfers, maxIterations: 500) { transfer in
            let source = tag == .int64
                ? ChoiceValue(transfer.source, tag: tag)
                : ChoiceValue(UInt64(transfer.source), tag: tag)
            let sink = tag == .int64
                ? ChoiceValue(transfer.sink, tag: tag)
                : ChoiceValue(UInt64(transfer.sink), tag: tag)
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
            let sourceValue = tag == .int64 ? newSource.decodedSignedValue : Int64(newSource.bitPattern64)
            let sinkValue = tag == .int64 ? newSink.decodedSignedValue : Int64(newSink.bitPattern64)
            let movement = transfer.source > 0 ? Int64(transfer.delta) : -Int64(transfer.delta)
            return sourceValue == transfer.source - movement
                && sinkValue == transfer.sink + movement
                && sourceValue + sinkValue == transfer.source + transfer.sink
                && abs(sourceValue) < abs(transfer.source)
        }
    }
}
