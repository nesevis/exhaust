import Testing
@testable import ExhaustCore

@Suite("Redistribution Rational Math")
struct RedistributionRationalMathTests {
    @Test("Integral contexts preserve magnitude, direction, and unit steps", arguments: [
        (ChoiceValue(Int64(10), tag: .int64), ChoiceValue(Int64(3), tag: .int64), UInt64(10), false),
        (ChoiceValue(Int64(-7), tag: .int64), ChoiceValue(Int64(0), tag: .int64), UInt64(7), true),
        (ChoiceValue(Int16(6), tag: .int16), ChoiceValue(Int32(2), tag: .int32), UInt64(6), false),
        (ChoiceValue(UInt64(100), tag: .uint64), ChoiceValue(UInt64(0), tag: .uint64), UInt64(100), false),
        (ChoiceValue(4.0, tag: .double), ChoiceValue(1.0, tag: .double), UInt64(4), false),
    ])
    func contextContract(source: ChoiceValue, sink: ChoiceValue, distance: UInt64, movesUpward: Bool) throws {
        let context = try #require(context(source, sink))
        #expect(context.denominator == 1)
        #expect(context.intStepSize == 1)
        #expect(context.distanceInSteps == distance)
        #expect(context.sourceMovesUpward == movesUpward)
    }

    @Test("Ineligible pairs have no rational context", arguments: [
        (ChoiceValue(Int64(0), tag: .int64), ChoiceValue(Int64(5), tag: .int64)),
        (ChoiceValue(UInt64(Int64.max) + 1, tag: .uint64), ChoiceValue(UInt64(0), tag: .uint64)),
        (ChoiceValue(Double.infinity, tag: .double), ChoiceValue(1.0, tag: .double)),
        (ChoiceValue(1.0, tag: .double), ChoiceValue(Double.nan, tag: .double)),
    ])
    func ineligiblePairs(source: ChoiceValue, sink: ChoiceValue) {
        #expect(context(source, sink) == nil)
    }

    @Test("Explicit source range changes the reduction distance")
    func explicitRangeConstrainsTarget() throws {
        let source = ChoiceValue(Int64(10), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)
        let ranged = try #require(RedistributionSearch.makeMixedRedistributionContext(
            sourceChoice: source, sinkChoice: sink,
            sourceValidRange: Int64(5).bitPattern64 ... Int64(15).bitPattern64,
            sourceIsRangeExplicit: true
        ))
        #expect(ranged.distanceInSteps == 5)
        #expect(try #require(context(source, sink)).distanceInSteps == 10)
    }

    @Test("Every legal delta moves both operands exactly and the next delta is rejected", arguments: [
        (ChoiceValue(Int64(10), tag: .int64), ChoiceValue(Int64(3), tag: .int64), Int64(10), Int64(3)),
        (ChoiceValue(Int64(5), tag: .int64), ChoiceValue(Int64(0), tag: .int64), Int64(5), Int64(0)),
        (ChoiceValue(Int64(-8), tag: .int64), ChoiceValue(Int64(0), tag: .int64), Int64(-8), Int64(0)),
        (ChoiceValue(UInt64(20), tag: .uint64), ChoiceValue(UInt64(5), tag: .uint64), Int64(20), Int64(5)),
        (ChoiceValue(6.0, tag: .double), ChoiceValue(2.0, tag: .double), Int64(6), Int64(2)),
        (ChoiceValue(Int64(12), tag: .int64), ChoiceValue(Int64(3), tag: .int64), Int64(12), Int64(3)),
    ])
    func transferContract(source: ChoiceValue, sink: ChoiceValue, sourceValue: Int64, sinkValue: Int64) throws {
        let context = try #require(context(source, sink))
        try #require(context.distanceInSteps == sourceValue.magnitude)
        for delta in 1 ... context.distanceInSteps {
            let (newSource, newSink) = try #require(RedistributionSearch.mixedRedistributedPairChoices(
                sourceChoice: source, sinkChoice: sink, delta: delta, context: context
            ))
            let movement = sourceValue > 0 ? Int64(delta) : -Int64(delta)
            let expectedSource = sourceValue - movement
            let expectedSink = sinkValue + movement
            switch source.tag {
                case .double:
                    #expect(newSource.decodedDoubleValue == Double(expectedSource))
                    #expect(newSink.decodedDoubleValue == Double(expectedSink))
                case .uint64:
                    #expect(newSource.bitPattern64 == UInt64(expectedSource))
                    #expect(newSink.bitPattern64 == UInt64(expectedSink))
                default:
                    #expect(newSource.decodedSignedValue == expectedSource)
                    #expect(newSink.decodedSignedValue == expectedSink)
            }
            #expect(newSource.tag == source.tag)
            #expect(newSink.tag == sink.tag)
        }
        #expect(RedistributionSearch.mixedRedistributedPairChoices(
            sourceChoice: source, sinkChoice: sink, delta: context.distanceInSteps + 1, context: context
        ) == nil)
    }

    private func context(_ source: ChoiceValue, _ sink: ChoiceValue) -> RedistributionSearch.MixedRedistributionContext? {
        RedistributionSearch.makeMixedRedistributionContext(
            sourceChoice: source, sinkChoice: sink, sourceValidRange: nil, sourceIsRangeExplicit: false
        )
    }
}
