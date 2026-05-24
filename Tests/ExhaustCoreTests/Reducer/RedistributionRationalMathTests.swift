import Testing
@testable import ExhaustCore

@Suite("Redistribution Rational Math")
struct RedistributionRationalMathTests {
    // MARK: - makeMixedRedistributionContext: Integer Pairs

    @Test("Same-type signed integers produce denominator 1 and correct distance")
    func sameSignedIntegers() {
        let source = ChoiceValue(Int64(10), tag: .int64)
        let sink = ChoiceValue(Int64(3), tag: .int64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let context else {
            Issue.record("Expected non-nil context for same-type signed pair")
            return
        }
        #expect(context.denominator == 1)
        #expect(context.intStepSize == 1)
        #expect(context.distanceInSteps == 10)
        #expect(context.sourceMovesUpward == false)
    }

    @Test("Negative signed source moves upward toward zero")
    func negativeSignedMovesUpward() {
        let source = ChoiceValue(Int64(-7), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let context else {
            Issue.record("Expected non-nil context for negative source")
            return
        }
        #expect(context.sourceMovesUpward == true)
        #expect(context.distanceInSteps == 7)
    }

    @Test("Source already at target returns nil")
    func sourceAtTargetReturnsNil() {
        let source = ChoiceValue(Int64(0), tag: .int64)
        let sink = ChoiceValue(Int64(5), tag: .int64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        #expect(context == nil)
    }

    // MARK: - makeMixedRedistributionContext: Cross-Type Pairs

    @Test("Cross-type integer pair has intStepSize equal to denominator")
    func crossTypeIntegerPair() {
        let source = ChoiceValue(Int16(6), tag: .int16)
        let sink = ChoiceValue(Int32(2), tag: .int32)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let context else {
            Issue.record("Expected non-nil context for cross-type pair")
            return
        }
        #expect(context.denominator == 1)
        #expect(context.intStepSize == 1)
        #expect(context.distanceInSteps == 6)
    }

    @Test("Unsigned source with large value produces valid context")
    func unsignedLargeValue() {
        let source = ChoiceValue(100 as UInt64, tag: .uint64)
        let sink = ChoiceValue(0 as UInt64, tag: .uint64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let context else {
            Issue.record("Expected non-nil context for unsigned pair")
            return
        }
        #expect(context.distanceInSteps == 100)
        #expect(context.sourceMovesUpward == false)
    }

    @Test("Unsigned value exceeding Int64.max returns nil")
    func unsignedExceedingInt64MaxReturnsNil() {
        let source = ChoiceValue(UInt64(Int64.max) + 1, tag: .uint64)
        let sink = ChoiceValue(0 as UInt64, tag: .uint64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        #expect(context == nil)
    }

    // MARK: - makeMixedRedistributionContext: Float Pairs

    @Test("Same-type double pair produces rational context with nonzero distance")
    func sameTypeDoublePair() {
        let source = ChoiceValue(4.0, tag: .double)
        let sink = ChoiceValue(1.0, tag: .double)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let context else {
            Issue.record("Expected non-nil context for double pair")
            return
        }
        #expect(context.distanceInSteps > 0)
        #expect(context.denominator > 0)
    }

    @Test("Non-finite float source returns nil")
    func nonFiniteFloatReturnsNil() {
        let source = ChoiceValue(Double.infinity, tag: .double)
        let sink = ChoiceValue(1.0, tag: .double)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        #expect(context == nil)
    }

    @Test("Non-finite float sink returns nil")
    func nonFiniteFloatSinkReturnsNil() {
        let source = ChoiceValue(1.0, tag: .double)
        let sink = ChoiceValue(Double.nan, tag: .double)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        #expect(context == nil)
    }

    // MARK: - makeMixedRedistributionContext: Explicit Range

    @Test("Explicit source range constrains reduction target")
    func explicitRangeConstrainsTarget() {
        let source = ChoiceValue(Int64(10), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)
        let rangedBP = Int64(5).bitPattern64 ... Int64(15).bitPattern64

        let contextWithRange = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: rangedBP,
            sourceIsRangeExplicit: true
        )
        let contextWithoutRange = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        guard let withRange = contextWithRange, let withoutRange = contextWithoutRange else {
            Issue.record("Both contexts should be non-nil")
            return
        }
        #expect(withRange.distanceInSteps <= withoutRange.distanceInSteps)
    }

    // MARK: - mixedRedistributedPairChoices: Basic Round-Trips

    @Test("Redistributed signed integers move source toward target and sink in opposite direction")
    func redistSignedRoundTrip() {
        let source = ChoiceValue(Int64(10), tag: .int64)
        let sink = ChoiceValue(Int64(3), tag: .int64)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: 3,
            context: context
        ) else {
            Issue.record("Expected non-nil result for delta=3")
            return
        }

        #expect(newSource.decodedSignedValue == 7)
        #expect(newSink.decodedSignedValue == 6)
    }

    @Test("Full delta zeroes the source")
    func fullDeltaZeroesSource() {
        let source = ChoiceValue(Int64(5), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: context.distanceInSteps,
            context: context
        ) else {
            Issue.record("Expected non-nil result for full delta")
            return
        }

        #expect(newSource.decodedSignedValue == 0)
        #expect(newSink.decodedSignedValue == 5)
    }

    @Test("Negative source redistributes upward toward zero")
    func negativeSourceRedistributes() {
        let source = ChoiceValue(Int64(-8), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        #expect(context.sourceMovesUpward == true)

        guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: 4,
            context: context
        ) else {
            Issue.record("Expected non-nil result for delta=4")
            return
        }

        #expect(newSource.decodedSignedValue == -4)
        #expect(newSink.decodedSignedValue == -4)
    }

    // MARK: - mixedRedistributedPairChoices: Edge Cases

    @Test("Delta exceeding distanceInSteps returns nil")
    func excessiveDeltaReturnsNil() {
        let source = ChoiceValue(Int64(5), tag: .int64)
        let sink = ChoiceValue(Int64(0), tag: .int64)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        let result = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: context.distanceInSteps + 1,
            context: context
        )
        #expect(result == nil)
    }

    @Test("Zero delta is prevented by makeMixedRedistributionContext requiring nonzero distance")
    func zeroDeltaGuardedByContextConstruction() {
        let source = ChoiceValue(Int64(0), tag: .int64)
        let sink = ChoiceValue(Int64(5), tag: .int64)

        let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        )
        #expect(context == nil)
    }

    // MARK: - mixedRedistributedPairChoices: Unsigned

    @Test("Unsigned integer redistribution preserves total")
    func unsignedRedistributionPreservesTotal() {
        let source = ChoiceValue(20 as UInt64, tag: .uint64)
        let sink = ChoiceValue(5 as UInt64, tag: .uint64)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: 7,
            context: context
        ) else {
            Issue.record("Expected non-nil result")
            return
        }

        #expect(newSource.bitPattern64 == 13)
        #expect(newSink.bitPattern64 == 12)
    }

    // MARK: - mixedRedistributedPairChoices: Float Round-Trip

    @Test("Double pair redistribution produces finite results")
    func doubleRedistributionFinite() {
        let source = ChoiceValue(6.0, tag: .double)
        let sink = ChoiceValue(2.0, tag: .double)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context for double pair")
            return
        }

        guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
            sourceChoice: source,
            sinkChoice: sink,
            delta: 1,
            context: context
        ) else {
            Issue.record("Expected non-nil result for delta=1")
            return
        }

        #expect(newSource.decodedDoubleValue.isFinite)
        #expect(newSink.decodedDoubleValue.isFinite)
        #expect(newSource.decodedDoubleValue < 6.0, "Source should decrease after redistribution")
        #expect(newSink.decodedDoubleValue > 2.0, "Sink should increase after redistribution")
    }

    // MARK: - Conservation Property

    @Test("Signed integer redistribution conserves total value across all valid deltas")
    func conservationAcrossDeltas() {
        let source = ChoiceValue(Int64(12), tag: .int64)
        let sink = ChoiceValue(Int64(3), tag: .int64)
        let originalTotal = Int64(12) + Int64(3)

        guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
            sourceChoice: source,
            sinkChoice: sink,
            sourceValidRange: nil,
            sourceIsRangeExplicit: false
        ) else {
            Issue.record("Expected non-nil context")
            return
        }

        for delta in 1 ... context.distanceInSteps {
            guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
                sourceChoice: source,
                sinkChoice: sink,
                delta: delta,
                context: context
            ) else {
                continue
            }
            let newTotal = newSource.decodedSignedValue + newSink.decodedSignedValue
            #expect(newTotal == originalTotal, "Total not conserved at delta=\(delta): \(newSource.decodedSignedValue) + \(newSink.decodedSignedValue) = \(newTotal) != \(originalTotal)")
        }
    }
}
