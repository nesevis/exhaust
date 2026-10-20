//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

package extension ChoiceValue {
    /// Ranks signed integers as `0, 1, -1, 2, -2, …`, with the unpaired minimum value last within each type's width.
    ///
    /// Floats use the magnitude-based ``FloatShortlex`` key; ``shortLexCompare(_:)`` resolves equal keys by preferring positive signs. Unsigned integers use their stored bit patterns directly. These search coordinates do not change the numeric encoding used for range checks and replay.
    @inline(__always)
    var shortlexKey: UInt64 {
        if tag.isFloatingPoint {
            return FloatShortlex.shortlexKey(for: decodedDoubleValue)
        } else if tag.isSigned {
            let value = decodedSignedValue
            let zigzag = UInt64(bitPattern: (value << 1) ^ (value >> 63))
            guard zigzag != 0, bitPattern64 != 0 else {
                return zigzag
            }
            return zigzag & 1 == 0 ? zigzag - 1 : zigzag + 1
        } else {
            return bitPattern64
        }
    }

    /// Applies the reducer's complete value order, including positive-first ties and deterministic ordering of NaN payloads.
    ///
    /// Every pair of values compares the same lexicographic key, the ``shortlexKey``, then the sign with positive first, then the bit pattern, so the order stays transitive when sequence comparison aligns values of different tags. Float signs come from the order-preserving encoding so half-precision NaN signs survive comparison even when decoding through ``Float16Emulation`` would discard them. Numeric search admission and sequence comparison must use this same order.
    func shortLexCompare(_ other: ChoiceValue) -> ShortlexOrder {
        // Sequence comparison mostly aligns identical values; answering those before computing either key keeps the common case cheap.
        if tag == other.tag, bitPattern64 == other.bitPattern64 {
            return .eq
        }
        let key = shortlexKey
        let otherKey = other.shortlexKey
        if key < otherKey {
            return .lt
        }
        if key > otherKey {
            return .gt
        }
        let isNegative = hasNegativeSign
        let otherIsNegative = other.hasNegativeSign
        if isNegative != otherIsNegative {
            return isNegative ? .gt : .lt
        }
        if bitPattern64 < other.bitPattern64 {
            return .lt
        }
        if bitPattern64 > other.bitPattern64 {
            return .gt
        }
        return .eq
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

        guard let range else {
            return target
        }

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
        guard let range else {
            return nil
        }

        var best: ChoiceValue?
        func consider(_ bitPattern: UInt64) {
            let candidate = ChoiceValue(bitPattern, tag: tag)
            if let currentBest = best, candidate.shortLexCompare(currentBest) != .lt {
                return
            }
            best = candidate
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

        return best?.bitPattern64
    }

    func fits(in range: ClosedRange<UInt64>?, bitPattern: UInt64) -> Bool {
        range?.contains(bitPattern) ?? true
    }
}
