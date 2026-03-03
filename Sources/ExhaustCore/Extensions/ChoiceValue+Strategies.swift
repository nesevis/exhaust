//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

extension ChoiceValue {
    @_spi(ExhaustInternal) public var bitPattern64: UInt64 {
        switch self {
        case let .unsigned(uint, _):
            uint
        case let .signed(_, uint, _):
            uint
        case let .floating(_, uint, _):
            uint
        }
    }

    /// Key for shortlex ordering where values closer to zero are smaller.
    /// - Signed integers: zigzag encoding (0 → 0, -1 → 1, 1 → 2, -2 → 3, ...)
    /// - Floating point: absolute value's raw IEEE 754 bit pattern (0.0 → 0, ±small → small, ±large → large)
    /// - Unsigned integers: identical to `bitPattern64`
    @_spi(ExhaustInternal) public var shortlexKey: UInt64 {
        switch self {
        case let .unsigned(uint, _):
            uint
        case let .signed(value, _, _):
            UInt64(bitPattern: (value << 1) ^ (value >> 63))
        case let .floating(value, _, _):
            FloatShortlex.shortlexKey(for: value)
        }
    }

    /// Constructs a `ChoiceValue` from a shortlex key, reversing `shortlexKey`.
    ///
    /// - For signed integers: zigzag decodes the key back to a signed value.
    /// - For unsigned integers and floats: the key equals the bit pattern.
    @_spi(ExhaustInternal) public static func fromShortlexKey(_ key: UInt64, tag: TypeTag) -> ChoiceValue {
        switch tag {
        case .int, .int8, .int16, .int32, .int64:
            // Zigzag decode: inverse of (value << 1) ^ (value >> 63)
            let decoded = Int64(bitPattern: key >> 1) ^ -Int64(bitPattern: key & 1)
            // Convert decoded Int64 to the typed value's bit pattern encoding
            let bp: UInt64 = switch tag {
            case .int8: Int8(truncatingIfNeeded: decoded).bitPattern64
            case .int16: Int16(truncatingIfNeeded: decoded).bitPattern64
            case .int32: Int32(truncatingIfNeeded: decoded).bitPattern64
            case .int: Int(truncatingIfNeeded: decoded).bitPattern64
            default: decoded.bitPattern64 // .int64
            }
            return ChoiceValue(tag.makeConvertible(bitPattern64: bp), tag: tag)
        default:
            // Unsigned, float: shortlexKey == bitPattern64
            return ChoiceValue(tag.makeConvertible(bitPattern64: key), tag: tag)
        }
    }

    /// The bit pattern of the ideal shrink target for this value type.
    /// - Unsigned: lowest valid bit pattern (smallest value)
    /// - Signed/Float: 0's bit pattern if in range, else the range bound closest to 0's bit pattern
    @_spi(ExhaustInternal) public func reductionTarget(in range: ClosedRange<UInt64>?) -> UInt64 {
        let target = semanticSimplest.bitPattern64
        if fits(in: range, bitPattern: target) {
            return target
        }

        if case let .floating(_, _, type) = self,
           let floatingTarget = floatingReductionTarget(in: range, type: type)
        {
            return floatingTarget
        }

        guard let range else { return target }

        // Find the range bound closest to the target
        var bestBound = range.lowerBound
        var bestDistance = target > bestBound
            ? target - bestBound
            : bestBound - target
        for bound in [range.lowerBound, range.upperBound] {
            let distance = target > bound
                ? target - bound
                : bound - target
            if distance < bestDistance {
                bestDistance = distance
                bestBound = bound
            }
        }
        return bestBound
    }

    private func floatingReductionTarget(
        in range: ClosedRange<UInt64>?,
        type: any BitPatternConvertible.Type,
    ) -> UInt64? {
        guard let range else { return nil }

        var best: (key: UInt64, bitPattern: UInt64)?
        func consider(_ bitPattern: UInt64) {
            guard let value = floatingValue(for: bitPattern, type: type) else {
                return
            }
            let key = FloatShortlex.shortlexKey(for: value)
            if let currentBest = best, currentBest.key <= key {
                return
            }
            best = (key, bitPattern)
        }

        consider(range.lowerBound)
        consider(range.upperBound)

        if let lower = floatingValue(for: range.lowerBound, type: type),
           let upper = floatingValue(for: range.upperBound, type: type),
           lower.isFinite,
           upper.isFinite
        {
            // Hypothesis-style ordering prefers simple non-negative integers when available.
            let simpleUpper = FloatShortlex.simpleIntegerUpperBound

            let positiveLower = max(0.0, lower)
            let positiveUpper = min(simpleUpper, upper)
            if positiveLower <= positiveUpper {
                let integerCandidate = positiveLower.rounded(.up)
                if integerCandidate <= positiveUpper,
                   let bitPattern = floatingBitPattern(for: integerCandidate, type: type)
                {
                    consider(bitPattern)
                }
            }

            let negativeLower = max(-simpleUpper, lower)
            let negativeUpper = min(0.0, upper)
            if negativeLower <= negativeUpper {
                let integerCandidate = negativeUpper.rounded(.down)
                if integerCandidate >= negativeLower,
                   let bitPattern = floatingBitPattern(for: integerCandidate, type: type)
                {
                    consider(bitPattern)
                }
            }
        }

        return best?.bitPattern
    }

    private func floatingValue(
        for bitPattern: UInt64,
        type: any BitPatternConvertible.Type,
    ) -> Double? {
        if type is Double.Type {
            return Double(Double(bitPattern64: bitPattern))
        }
        if type is Float.Type {
            return Double(Float(bitPattern64: bitPattern))
        }
        return nil
    }

    private func floatingBitPattern(
        for value: Double,
        type: any BitPatternConvertible.Type,
    ) -> UInt64? {
        if type is Double.Type {
            return Double(value).bitPattern64
        }
        if type is Float.Type {
            return Float(value).bitPattern64
        }
        return nil
    }

    private func fits(in range: ClosedRange<UInt64>?, bitPattern: UInt64) -> Bool {
        guard let range else { return true }
        return range.contains(bitPattern)
    }

    var fundamentalValues: [ChoiceValue] {
        switch self {
        case .unsigned:
            let values: [UInt64] = [0, 1, 2]
            return values
                .map { ChoiceValue($0, tag: .uint64) }
        case .signed:
            let values: [Int64] = [0, -1, 1, 2, -2]
            return values
                .map { ChoiceValue($0, tag: .int64) }
        case .floating:
            let values: [Double] = [0, -0.1, -0.01, -0.001, -Double.ulpOfOne, -0.0001, Double.ulpOfOne, 0.001, 0.01, 0.1]
            return values
                .map { ChoiceValue($0, tag: .double) }
        }
    }
}
