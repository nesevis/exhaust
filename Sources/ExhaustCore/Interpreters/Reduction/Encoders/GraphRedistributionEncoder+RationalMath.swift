//
//  GraphRedistributionEncoder+RationalMath.swift
//  Exhaust
//

// MARK: - Mixed Redistribution Math

extension GraphRedistributionEncoder {
    /// Builds a ``MixedRedistributionContext`` from current source and sink choices.
    ///
    /// Both sides are converted to rational form with a common denominator. When at least one side is integer, ``MixedRedistributionContext/intStepSize`` equals the denominator so the integer side only takes whole-number deltas. Distance uses order-preserving `Int64` bit patterns: the gap from `Int64.min` to zero fits in `UInt64` even though signed subtraction would overflow.
    static func makeMixedRedistributionContext(
        sourceChoice: ChoiceValue,
        sinkChoice: ChoiceValue,
        sourceValidRange: ClosedRange<UInt64>?,
        sourceIsRangeExplicit: Bool
    ) -> MixedRedistributionContext? {
        guard let sourceRatio = rationalForChoice(sourceChoice),
              let sinkRatio = rationalForChoice(sinkChoice)
        else {
            return nil
        }

        let sourceTargetBitPattern = sourceChoice.reductionTarget(
            in: sourceIsRangeExplicit ? sourceValidRange : nil
        )
        guard let targetRatio = rationalForTarget(
            sourceChoice,
            targetBitPattern: sourceTargetBitPattern
        ) else {
            return nil
        }

        guard let pairDenominator = leastCommonMultiple(sourceRatio.denominator, sinkRatio.denominator),
              let denominator = leastCommonMultiple(pairDenominator, targetRatio.denominator),
              denominator > 0
        else {
            return nil
        }

        guard let sourceNumerator = scaledNumerator(sourceRatio, to: denominator),
              let sinkNumerator = scaledNumerator(sinkRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else {
            return nil
        }

        let sourceIsInteger = isIntegerTag(sourceChoice.tag)
        let sinkIsInteger = isIntegerTag(sinkChoice.tag)
        let intStepSize: UInt64 = (sourceIsInteger || sinkIsInteger) ? denominator : 1
        guard intStepSize > 0 else {
            return nil
        }

        let sourceMovesUpward = targetNumerator > sourceNumerator
        let sourcePattern = sourceNumerator.bitPattern64
        let targetPattern = targetNumerator.bitPattern64
        let rawDistance = sourceMovesUpward
            ? targetPattern - sourcePattern
            : sourcePattern - targetPattern
        guard rawDistance > 0 else {
            return nil
        }

        let distanceInSteps = rawDistance / intStepSize
        guard distanceInSteps > 0 else {
            return nil
        }

        return MixedRedistributionContext(
            sourceNumerator: sourceNumerator,
            sinkNumerator: sinkNumerator,
            denominator: denominator,
            intStepSize: intStepSize,
            sourceMovesUpward: sourceMovesUpward,
            distanceInSteps: distanceInSteps
        )
    }

    /// Rejects transfers whose resulting numerators or original numeric types cannot represent the new values.
    ///
    /// The delta need not fit in `Int64`; checked transfers in order-preserving pattern space cover the full signed span without wrapping. Both numerators remain `Int64` after decoding, and each choice is validated against its own type width.
    static func mixedRedistributedPairChoices(
        sourceChoice: ChoiceValue,
        sinkChoice: ChoiceValue,
        delta: UInt64,
        context: MixedRedistributionContext
    ) -> (ChoiceValue, ChoiceValue)? {
        guard delta <= context.distanceInSteps else {
            return nil
        }

        let (actualDelta, stepOverflow) = delta.multipliedReportingOverflow(by: context.intStepSize)
        guard stepOverflow == false,
              let patterns = checkedTransferPatterns(
                  sourceBitPattern: context.sourceNumerator.bitPattern64,
                  sinkBitPattern: context.sinkNumerator.bitPattern64,
                  sourceMovesDownward: context.sourceMovesUpward == false,
                  delta: actualDelta
              )
        else {
            return nil
        }

        guard let newSourceChoice = choiceFromNumerator(
            Int64(bitPattern64: patterns.source),
            denominator: context.denominator,
            original: sourceChoice
        ),
            let newSinkChoice = choiceFromNumerator(
                Int64(bitPattern64: patterns.sink),
                denominator: context.denominator,
                original: sinkChoice
            )
        else {
            return nil
        }

        return (newSourceChoice, newSinkChoice)
    }

    // MARK: - Rational Arithmetic Helpers

    /// Restricts rational numerators to the shared signed representation before denominator scaling.
    private static func rationalForChoice(
        _ choice: ChoiceValue
    ) -> (numerator: Int64, denominator: UInt64)? {
        if choice.tag.isFloatingPoint {
            let value = choice.decodedDoubleValue
            guard value.isFinite else {
                return nil
            }
            return FloatReduction.integerRatio(for: value, tag: choice.tag)
        } else if choice.tag.isSigned {
            return (choice.decodedSignedValue, 1)
        } else {
            guard choice.bitPattern64 <= UInt64(Int64.max) else {
                return nil
            }
            return (Int64(choice.bitPattern64), 1)
        }
    }

    /// Decodes the target with the source tag so range-constrained and floating targets use the same rational units.
    private static func rationalForTarget(
        _ choice: ChoiceValue,
        targetBitPattern: UInt64
    ) -> (numerator: Int64, denominator: UInt64)? {
        let tag = choice.tag
        let targetChoice = ChoiceValue(
            tag.makeConvertible(bitPattern64: targetBitPattern),
            tag: tag
        )
        if tag.isFloatingPoint {
            let targetValue = targetChoice.decodedDoubleValue
            guard targetValue.isFinite else {
                return nil
            }
            return FloatReduction.integerRatio(for: targetValue, tag: tag)
        } else if tag.isSigned {
            return (targetChoice.decodedSignedValue, 1)
        } else {
            guard targetChoice.bitPattern64 <= UInt64(Int64.max) else {
                return nil
            }
            return (Int64(targetChoice.bitPattern64), 1)
        }
    }

    /// Preserves integral values only when the quotient fits the original type; signed encoding uses that type's zero pattern rather than the 64-bit sign bias.
    private static func choiceFromNumerator(
        _ numerator: Int64,
        denominator: UInt64,
        original: ChoiceValue
    ) -> ChoiceValue? {
        let tag = original.tag
        if tag.isFloatingPoint {
            let value = Double(numerator) / Double(denominator)
            return tag.floatingChoice(from: value)
        }
        guard let signedDenominator = Int64(exactly: denominator),
              signedDenominator > 0,
              numerator % signedDenominator == 0
        else {
            return nil
        }
        let integerValue = numerator / signedDenominator
        if tag.isSigned {
            let (pattern, overflow) = switch integerValue >= 0 {
                case true:
                    tag.simplestBitPattern.addingReportingOverflow(integerValue.magnitude)
                case false:
                    tag.simplestBitPattern.subtractingReportingOverflow(integerValue.magnitude)
            }
            guard overflow == false, tag.bitPatternRange.contains(pattern) else {
                return nil
            }
            return ChoiceValue(pattern, tag: tag)
        }
        guard integerValue >= 0 else {
            return nil
        }
        let pattern = UInt64(integerValue)
        guard tag.bitPatternRange.contains(pattern) else {
            return nil
        }
        return ChoiceValue(pattern, tag: tag)
    }

    /// Rejects denominator expansion when its scale or resulting signed numerator exceeds the rational representation.
    private static func scaledNumerator(
        _ ratio: (numerator: Int64, denominator: UInt64),
        to denominator: UInt64
    ) -> Int64? {
        guard denominator % ratio.denominator == 0 else {
            return nil
        }
        let scale = denominator / ratio.denominator
        guard scale <= UInt64(Int64.max) else {
            return nil
        }
        let (scaled, overflow) = ratio.numerator.multipliedReportingOverflow(by: Int64(scale))
        guard overflow == false else {
            return nil
        }
        return scaled
    }

    /// Reduces denominator factors with remainders so intermediate products cannot overflow.
    private static func greatestCommonDivisor(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var dividend = first
        var divisor = second
        while divisor != 0 {
            let remainder = dividend % divisor
            dividend = divisor
            divisor = remainder
        }
        return dividend
    }

    /// Keeps the common denominator exact and rejects products that exceed the unsigned representation.
    private static func leastCommonMultiple(_ first: UInt64, _ second: UInt64) -> UInt64? {
        guard first > 0, second > 0 else {
            return nil
        }
        let divisor = greatestCommonDivisor(first, second)
        let reducedFirst = first / divisor
        let (product, overflow) = reducedFirst.multipliedReportingOverflow(by: second)
        guard overflow == false else {
            return nil
        }
        return product
    }

    private static func isIntegerTag(_ tag: TypeTag) -> Bool {
        switch tag {
            case .int, .int8, .int16, .int32, .int64,
                 .uint, .uint8, .uint16, .uint32, .uint64:
                true
            default:
                false
        }
    }
}
