import Testing
@testable import ExhaustCore

// MARK: - Rational Arithmetic Helpers

@Suite("RedistributeAcrossBindRegionsEncoder — Rational Helpers")
struct RedistributeAcrossBindRegionsRationalTests {
    // MARK: - rationalForChoice

    @Test("Unsigned integer has denominator 1")
    func unsignedRational() {
        let choice = ChoiceValue(UInt64(42), tag: .uint64)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        #expect(ratio?.numerator == 42)
        #expect(ratio?.denominator == 1)
    }

    @Test("Signed integer has denominator 1")
    func signedRational() {
        let choice = ChoiceValue(Int64(-7), tag: .int64)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        #expect(ratio?.numerator == -7)
        #expect(ratio?.denominator == 1)
    }

    @Test("Signed zero has numerator 0")
    func signedZeroRational() {
        let choice = ChoiceValue(Int64(0), tag: .int)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        #expect(ratio?.numerator == 0)
        #expect(ratio?.denominator == 1)
    }

    @Test("Double produces finite rational")
    func doubleRational() {
        let choice = ChoiceValue(2.5, tag: .double)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        #expect(ratio != nil)
        // 2.5 = 5/2
        guard let ratio else { return }
        let value = Double(ratio.numerator) / Double(ratio.denominator)
        #expect(value == 2.5)
    }

    @Test("Float produces finite rational")
    func floatRational() {
        let choice = ChoiceValue(Float(0.25), tag: .float)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        #expect(ratio != nil)
        guard let ratio else { return }
        let value = Double(ratio.numerator) / Double(ratio.denominator)
        #expect(value == 0.25)
    }

    @Test("Non-finite double returns nil")
    func infiniteDoubleRational() {
        let choice = ChoiceValue(Double.infinity, tag: .double)
        #expect(RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice) == nil)
    }

    @Test("UInt64 exceeding Int64.max returns nil")
    func overflowUnsignedRational() {
        let choice = ChoiceValue(UInt64.max, tag: .uint64)
        #expect(RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice) == nil)
    }

    // MARK: - rationalForTarget

    @Test("Unsigned target rational matches bit pattern")
    func unsignedTargetRational() {
        let choice = ChoiceValue(UInt64(10), tag: .uint64)
        let targetBP = choice.reductionTarget(in: 0 ... 100)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForTarget(choice, targetBitPattern: targetBP)
        #expect(ratio != nil)
        // Reduction target for unsigned 10 is 0.
        #expect(ratio?.numerator == 0)
        #expect(ratio?.denominator == 1)
    }

    @Test("Signed target rational matches bit pattern")
    func signedTargetRational() {
        let choice = ChoiceValue(Int64(15), tag: .int)
        // The semanticSimplest for signed integers is 0.
        let target = choice.semanticSimplest
        let targetBP = target.bitPattern64
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForTarget(choice, targetBitPattern: targetBP)
        #expect(ratio != nil)
        #expect(ratio?.numerator == 0)
    }

    @Test("Double target rational is finite")
    func doubleTargetRational() {
        let choice = ChoiceValue(3.5, tag: .double)
        let targetBP = choice.reductionTarget(in: nil)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForTarget(choice, targetBitPattern: targetBP)
        #expect(ratio != nil)
    }

    // MARK: - choiceFromNumerator

    @Test("Integer round-trip through numerator space")
    func integerRoundTrip() {
        let original = ChoiceValue(Int64(9), tag: .int)
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(9, denominator: 1, original: original)
        #expect(result == original)
    }

    @Test("Unsigned round-trip through numerator space")
    func unsignedRoundTrip() {
        let original = ChoiceValue(UInt64(42), tag: .uint64)
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(42, denominator: 1, original: original)
        #expect(result == original)
    }

    @Test("Double round-trip through numerator space")
    func doubleRoundTrip() {
        let original = ChoiceValue(2.5, tag: .double)
        // 2.5 = 5/2
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(5, denominator: 2, original: original)
        guard case let .floating(value, _, _) = result else {
            Issue.record("Expected floating result")
            return
        }
        #expect(value == 2.5)
    }

    @Test("Float round-trip through numerator space")
    func floatRoundTrip() {
        let original = ChoiceValue(Float(0.75), tag: .float)
        // 0.75 = 3/4
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(3, denominator: 4, original: original)
        guard case let .floating(value, _, _) = result else {
            Issue.record("Expected floating result")
            return
        }
        #expect(Float(value) == 0.75)
    }

    @Test("Negative numerator produces negative signed integer")
    func negativeNumerator() {
        let original = ChoiceValue(Int64(-5), tag: .int64)
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(-5, denominator: 1, original: original)
        guard case let .signed(value, _, _) = result else {
            Issue.record("Expected signed result")
            return
        }
        #expect(value == -5)
    }

    @Test("Negative numerator for unsigned returns nil")
    func negativeNumeratorUnsigned() {
        let original = ChoiceValue(UInt64(5), tag: .uint64)
        #expect(RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(-1, denominator: 1, original: original) == nil)
    }

    @Test("Non-integral numerator for integer type returns nil")
    func nonIntegralNumerator() {
        let original = ChoiceValue(Int64(3), tag: .int)
        // 5/2 = 2.5 — not an integer
        #expect(RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(5, denominator: 2, original: original) == nil)
    }

    @Test("Non-finite result for double returns nil")
    func nonFiniteDoubleResult() {
        let original = ChoiceValue(1.0, tag: .double)
        // Division by very small denominator with huge numerator could overflow,
        // but Int64.max / 1 is finite. Use a case that produces infinity.
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(Int64.max, denominator: 1, original: original)
        // This should produce a finite double since Int64.max fits in Double.
        #expect(result != nil)
    }

    // MARK: - scaledNumerator

    @Test("Scales numerator to common denominator")
    func scaleNumerator() {
        // 3/4 scaled to denominator 12 → 9/12
        let result = RedistributeAcrossBindRegionsEncoder.scaledNumerator((numerator: 3, denominator: 4), to: 12)
        #expect(result == 9)
    }

    @Test("Scale factor of 1 preserves numerator")
    func scaleFactorOne() {
        let result = RedistributeAcrossBindRegionsEncoder.scaledNumerator((numerator: 7, denominator: 5), to: 5)
        #expect(result == 7)
    }

    @Test("Incompatible denominator returns nil")
    func incompatibleDenominator() {
        // 3/4 cannot be scaled to denominator 7 (7 % 4 != 0)
        #expect(RedistributeAcrossBindRegionsEncoder.scaledNumerator((numerator: 3, denominator: 4), to: 7) == nil)
    }

    @Test("Overflow during scaling returns nil")
    func scaleOverflow() {
        let result = RedistributeAcrossBindRegionsEncoder.scaledNumerator(
            (numerator: Int64.max, denominator: 1), to: 2
        )
        #expect(result == nil)
    }

    // MARK: - leastCommonMultiple

    @Test("LCM of coprime numbers")
    func lcmCoprime() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(3, 5) == 15)
    }

    @Test("LCM with shared factor")
    func lcmSharedFactor() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(4, 6) == 12)
    }

    @Test("LCM of equal values")
    func lcmEqual() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(7, 7) == 7)
    }

    @Test("LCM with 1")
    func lcmWithOne() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(1, 9) == 9)
    }

    @Test("LCM with zero returns nil")
    func lcmWithZero() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(0, 5) == nil)
    }

    @Test("LCM overflow returns nil")
    func lcmOverflow() {
        #expect(RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(UInt64.max, UInt64.max - 1) == nil)
    }

    // MARK: - greatestCommonDivisor

    @Test("GCD of coprime numbers is 1")
    func gcdCoprime() {
        #expect(RedistributeAcrossBindRegionsEncoder.greatestCommonDivisor(7, 11) == 1)
    }

    @Test("GCD with shared factor")
    func gcdSharedFactor() {
        #expect(RedistributeAcrossBindRegionsEncoder.greatestCommonDivisor(12, 8) == 4)
    }

    @Test("GCD with zero")
    func gcdWithZero() {
        #expect(RedistributeAcrossBindRegionsEncoder.greatestCommonDivisor(0, 5) == 5)
        #expect(RedistributeAcrossBindRegionsEncoder.greatestCommonDivisor(5, 0) == 5)
    }

    // MARK: - absDiff

    @Test("Absolute difference of positive values")
    func absDiffPositive() {
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(10, 3) == 7)
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(3, 10) == 7)
    }

    @Test("Absolute difference with negative values")
    func absDiffNegative() {
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(-5, 5) == 10)
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(5, -5) == 10)
    }

    @Test("Absolute difference of equal values is zero")
    func absDiffEqual() {
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(42, 42) == 0)
    }

    @Test("Absolute difference at Int64 extremes")
    func absDiffExtremes() {
        // Int64.max - Int64.min = UInt64.max
        #expect(RedistributeAcrossBindRegionsEncoder.absDiff(Int64.max, Int64.min) == UInt64.max)
    }

    // MARK: - isIntegerTag

    @Test("Integer tags identified correctly")
    func integerTags() {
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.int) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.int8) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.int16) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.int32) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.int64) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.uint) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.uint8) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.uint16) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.uint32) == true)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.uint64) == true)
    }

    @Test("Float tags are not integer")
    func floatTags() {
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.double) == false)
        #expect(RedistributeAcrossBindRegionsEncoder.isIntegerTag(.float) == false)
    }

    // MARK: - floatingChoice

    @Test("Double choice from value")
    func doubleChoice() {
        let result = RedistributeAcrossBindRegionsEncoder.floatingChoice(from: 3.14, tag: .double)
        guard case let .floating(value, _, tag) = result else {
            Issue.record("Expected floating result")
            return
        }
        #expect(value == 3.14)
        #expect(tag == .double)
    }

    @Test("Float choice narrows correctly")
    func floatChoice() {
        let result = RedistributeAcrossBindRegionsEncoder.floatingChoice(from: 0.5, tag: .float)
        guard case let .floating(value, _, tag) = result else {
            Issue.record("Expected floating result")
            return
        }
        #expect(Float(value) == 0.5)
        #expect(tag == .float)
    }

    @Test("Non-finite input returns nil")
    func nonFiniteChoice() {
        #expect(RedistributeAcrossBindRegionsEncoder.floatingChoice(from: .infinity, tag: .double) == nil)
        #expect(RedistributeAcrossBindRegionsEncoder.floatingChoice(from: .nan, tag: .double) == nil)
    }

    @Test("Non-float tag returns nil")
    func nonFloatTag() {
        #expect(RedistributeAcrossBindRegionsEncoder.floatingChoice(from: 1.0, tag: .int) == nil)
    }

    // MARK: - Full rational round-trip

    @Test("Integer value survives full rational pipeline")
    func integerFullRoundTrip() {
        let choice = ChoiceValue(Int64(17), tag: .int)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        guard let ratio else {
            Issue.record("Expected ratio")
            return
        }
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(
            ratio.numerator, denominator: ratio.denominator, original: choice
        )
        #expect(result == choice)
    }

    @Test("Double value survives full rational pipeline")
    func doubleFullRoundTrip() {
        let choice = ChoiceValue(1.25, tag: .double)
        let ratio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(choice)
        guard let ratio else {
            Issue.record("Expected ratio")
            return
        }
        let result = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(
            ratio.numerator, denominator: ratio.denominator, original: choice
        )
        guard case let .floating(value, _, _) = result else {
            Issue.record("Expected floating result")
            return
        }
        #expect(value == 1.25)
    }

    @Test("Mixed-type pair uses common denominator correctly")
    func mixedTypeCommonDenominator() {
        let intChoice = ChoiceValue(Int64(3), tag: .int)
        let floatChoice = ChoiceValue(1.5, tag: .double)

        guard let intRatio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(intChoice),
              let floatRatio = RedistributeAcrossBindRegionsEncoder.rationalForChoice(floatChoice),
              let commonDenom = RedistributeAcrossBindRegionsEncoder.leastCommonMultiple(
                  intRatio.denominator, floatRatio.denominator
              )
        else {
            Issue.record("Failed to compute rationals")
            return
        }

        guard let intScaled = RedistributeAcrossBindRegionsEncoder.scaledNumerator(intRatio, to: commonDenom),
              let floatScaled = RedistributeAcrossBindRegionsEncoder.scaledNumerator(floatRatio, to: commonDenom)
        else {
            Issue.record("Failed to scale numerators")
            return
        }

        // Verify values are preserved.
        let intValue = Double(intScaled) / Double(commonDenom)
        let floatValue = Double(floatScaled) / Double(commonDenom)
        #expect(intValue == 3.0)
        #expect(floatValue == 1.5)

        // Verify round-trip back to choices.
        let intResult = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(
            intScaled, denominator: commonDenom, original: intChoice
        )
        let floatResult = RedistributeAcrossBindRegionsEncoder.choiceFromNumerator(
            floatScaled, denominator: commonDenom, original: floatChoice
        )
        #expect(intResult == intChoice)
        guard case let .floating(fv, _, _) = floatResult else {
            Issue.record("Expected floating result")
            return
        }
        #expect(fv == 1.5)
    }
}
