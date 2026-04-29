//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

package extension ChoiceValue {
    /// Key for shortlex ordering where values closer to zero are smaller.
    /// - Signed integers: zigzag encoding (0 → 0, -1 → 1, 1 → 2, -2 → 3, ...)
    /// - Floating point: absolute value's raw IEEE 754 bit pattern (0.0 → 0, ±small → small, ±large → large)
    /// - Unsigned integers: identical to `bitPattern64`
    @inline(__always)
    var shortlexKey: UInt64 {
        if tag.isFloatingPoint {
            return FloatShortlex.shortlexKey(for: decodedDoubleValue)
        } else if tag.isSigned {
            let value = decodedSignedValue
            return UInt64(bitPattern: (value << 1) ^ (value >> 63))
        } else {
            return bitPattern64
        }
    }

    /// Constructs a ``ChoiceValue`` from a shortlex key, reversing `shortlexKey`.
    ///
    /// - For signed integers: zigzag decodes the key back to a signed value.
    /// - For unsigned integers and floats: the key equals the bit pattern.
    static func fromShortlexKey(_ key: UInt64, tag: TypeTag) -> ChoiceValue {
        switch tag {
        case .int, .int8, .int16, .int32, .int64, .date:
            let decoded = Int64(bitPattern: key >> 1) ^ -Int64(bitPattern: key & 1)
            let bp: UInt64 = switch tag {
            case .int8: Int8(truncatingIfNeeded: decoded).bitPattern64
            case .int16: Int16(truncatingIfNeeded: decoded).bitPattern64
            case .int32: Int32(truncatingIfNeeded: decoded).bitPattern64
            case .int: Int(truncatingIfNeeded: decoded).bitPattern64
            default: decoded.bitPattern64
            }
            return ChoiceValue(bp, tag: tag)
        default:
            return ChoiceValue(key, tag: tag)
        }
    }

    /// The bit pattern of the ideal reduction target for this value type.
    /// - Unsigned: lowest valid bit pattern (smallest value)
    /// - Signed/Float: 0's bit pattern if in range, else the range bound closest to 0's bit pattern
    func reductionTarget(in range: ClosedRange<UInt64>?) -> UInt64 {
        let target = semanticSimplest.bitPattern64
        if fits(in: range, bitPattern: target) {
            return target
        }

        if tag.isFloatingPoint,
           let floatingTarget = floatingReductionTarget(in: range, tag: tag)
        {
            return floatingTarget
        }

        guard let range else { return target }

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
        tag: TypeTag
    ) -> UInt64? {
        guard let range else { return nil }

        var best: (key: UInt64, bitPattern: UInt64)?
        func consider(_ bitPattern: UInt64) {
            let value = tag.numericDoubleValue(forBitPattern: bitPattern)
            let key = FloatShortlex.shortlexKey(for: value)
            if let currentBest = best, currentBest.key <= key {
                return
            }
            best = (key, bitPattern)
        }

        consider(range.lowerBound)
        consider(range.upperBound)

        let lower = tag.numericDoubleValue(forBitPattern: range.lowerBound)
        let upper = tag.numericDoubleValue(forBitPattern: range.upperBound)
        if lower.isFinite, upper.isFinite {
            let simpleUpper = FloatShortlex.simpleIntegerUpperBound

            let positiveLower = max(0.0, lower)
            let positiveUpper = min(simpleUpper, upper)
            if positiveLower <= positiveUpper {
                let integerCandidate = positiveLower.rounded(.up)
                if integerCandidate <= positiveUpper {
                    consider(tag.floatingBitPattern(from: integerCandidate))
                }
            }

            let negativeLower = max(-simpleUpper, lower)
            let negativeUpper = min(0.0, upper)
            if negativeLower <= negativeUpper {
                let integerCandidate = negativeUpper.rounded(.down)
                if integerCandidate >= negativeLower {
                    consider(tag.floatingBitPattern(from: integerCandidate))
                }
            }
        }

        return best?.bitPattern
    }

    func fits(in range: ClosedRange<UInt64>?, bitPattern: UInt64) -> Bool {
        guard let range else { return true }
        return range.contains(bitPattern)
    }
}
