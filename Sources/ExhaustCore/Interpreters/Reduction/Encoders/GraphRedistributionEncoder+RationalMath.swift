//
//  GraphRedistributionEncoder+RationalMath.swift
//  Exhaust
//

// MARK: - Mixed Redistribution Math

extension GraphRedistributionEncoder {
    /// Builds a ``MixedRedistributionContext`` from current source and sink choices.
    ///
    /// Both sides are converted to rational form with a common denominator. When at least one side is integer, ``MixedRedistributionContext/intStepSize`` equals the denominator so the integer side only takes whole-number deltas.
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

        // Compute source's reduction target as a rational.
        let sourceTargetBitPattern = sourceChoice.reductionTarget(
            in: sourceIsRangeExplicit ? sourceValidRange : nil
        )
        guard let targetRatio = rationalForTarget(
            sourceChoice,
            targetBitPattern: sourceTargetBitPattern
        ) else { return nil }

        guard let lcmAB = leastCommonMultiple(sourceRatio.denominator, sinkRatio.denominator),
              let denominator = leastCommonMultiple(lcmAB, targetRatio.denominator),
              denominator > 0 else { return nil }

        guard let sourceNumerator = scaledNumerator(sourceRatio, to: denominator),
              let sinkNumerator = scaledNumerator(sinkRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else { return nil }

        let sourceIsInt = isIntegerTag(sourceChoice.tag)
        let sinkIsInt = isIntegerTag(sinkChoice.tag)
        let intStepSize: UInt64 = (sourceIsInt || sinkIsInt) ? denominator : 1
        guard intStepSize > 0 else { return nil }

        let sourceMovesUpward = targetNumerator > sourceNumerator
        let rawDistance = sourceMovesUpward
            ? UInt64(targetNumerator - sourceNumerator)
            : UInt64(sourceNumerator - targetNumerator)
        guard rawDistance > 0 else { return nil }

        let distanceInSteps = rawDistance / intStepSize
        guard distanceInSteps > 0 else { return nil }

        return MixedRedistributionContext(
            sourceNumerator: sourceNumerator,
            sinkNumerator: sinkNumerator,
            denominator: denominator,
            intStepSize: intStepSize,
            sourceMovesUpward: sourceMovesUpward,
            distanceInSteps: distanceInSteps
        )
    }

    /// Applies a delta (in step units) to a mixed pair, producing new source and sink choices.
    static func mixedRedistributedPairChoices(
        sourceChoice: ChoiceValue,
        sinkChoice: ChoiceValue,
        delta: UInt64,
        context: MixedRedistributionContext
    ) -> (ChoiceValue, ChoiceValue)? {
        guard delta <= context.distanceInSteps else { return nil }

        let (actualDelta, stepOverflow) = delta.multipliedReportingOverflow(by: context.intStepSize)
        guard stepOverflow == false, actualDelta <= UInt64(Int64.max) else { return nil }
        let signedDelta = Int64(actualDelta)

        let newSourceNum: Int64
        let newSinkNum: Int64
        if context.sourceMovesUpward {
            let (s, sOverflow) = context.sourceNumerator.addingReportingOverflow(signedDelta)
            let (k, kOverflow) = context.sinkNumerator.subtractingReportingOverflow(signedDelta)
            guard sOverflow == false, kOverflow == false else { return nil }
            newSourceNum = s
            newSinkNum = k
        } else {
            let (s, sOverflow) = context.sourceNumerator.subtractingReportingOverflow(signedDelta)
            let (k, kOverflow) = context.sinkNumerator.addingReportingOverflow(signedDelta)
            guard sOverflow == false, kOverflow == false else { return nil }
            newSourceNum = s
            newSinkNum = k
        }

        guard let newSourceChoice = choiceFromNumerator(
            newSourceNum,
            denominator: context.denominator,
            original: sourceChoice
        ),
            let newSinkChoice = choiceFromNumerator(
                newSinkNum,
                denominator: context.denominator,
                original: sinkChoice
            )
        else { return nil }

        return (newSourceChoice, newSinkChoice)
    }

    // MARK: - Rational Arithmetic Helpers

    private static func rationalForChoice(
        _ choice: ChoiceValue
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch choice {
        case let .floating(value, _, tag):
            guard value.isFinite else { return nil }
            return FloatReduction.integerRatio(for: value, tag: tag)
        case let .signed(value, _, _):
            return (value, 1)
        case let .unsigned(value, _):
            guard value <= UInt64(Int64.max) else { return nil }
            return (Int64(value), 1)
        }
    }

    private static func rationalForTarget(
        _ choice: ChoiceValue,
        targetBitPattern: UInt64
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch choice {
        case let .floating(_, _, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .floating(targetValue, _, _) = targetChoice,
                  targetValue.isFinite else { return nil }
            return FloatReduction.integerRatio(for: targetValue, tag: tag)
        case let .signed(_, _, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .signed(targetValue, _, _) = targetChoice else { return nil }
            return (targetValue, 1)
        case let .unsigned(_, tag):
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .unsigned(targetValue, _) = targetChoice else { return nil }
            guard targetValue <= UInt64(Int64.max) else { return nil }
            return (Int64(targetValue), 1)
        }
    }

    private static func choiceFromNumerator(
        _ numerator: Int64,
        denominator: UInt64,
        original: ChoiceValue
    ) -> ChoiceValue? {
        switch original {
        case let .floating(_, _, tag):
            let value = Double(numerator) / Double(denominator)
            return tag.floatingChoice(from: value)
        case let .signed(_, _, tag):
            let denom = Int64(denominator)
            guard denom > 0, numerator % denom == 0 else { return nil }
            let intValue = numerator / denom
            let narrowed = ChoiceValue(intValue, tag: tag)
            guard case let .signed(narrowedValue, _, _) = narrowed,
                  narrowedValue == intValue else { return nil }
            return narrowed
        case let .unsigned(_, tag):
            let denom = Int64(denominator)
            guard denom > 0, numerator % denom == 0 else { return nil }
            let intValue = numerator / denom
            guard intValue >= 0 else { return nil }
            let uintValue = UInt64(intValue)
            let narrowed = ChoiceValue(uintValue, tag: tag)
            guard case let .unsigned(narrowedValue, _) = narrowed,
                  narrowedValue == uintValue else { return nil }
            return narrowed
        }
    }

    private static func scaledNumerator(
        _ ratio: (numerator: Int64, denominator: UInt64),
        to denominator: UInt64
    ) -> Int64? {
        guard denominator % ratio.denominator == 0 else { return nil }
        let scale = denominator / ratio.denominator
        guard scale <= UInt64(Int64.max) else { return nil }
        let (scaled, overflow) = ratio.numerator.multipliedReportingOverflow(by: Int64(scale))
        guard overflow == false else { return nil }
        return scaled
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    private static func leastCommonMultiple(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs > 0, rhs > 0 else { return nil }
        let gcd = greatestCommonDivisor(lhs, rhs)
        let reducedLHS = lhs / gcd
        let (product, overflow) = reducedLHS.multipliedReportingOverflow(by: rhs)
        guard overflow == false else { return nil }
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
