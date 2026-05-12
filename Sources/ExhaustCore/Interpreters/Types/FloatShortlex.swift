//
//  FloatShortlex.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Utilities for float-specific shortlex/reduction ordering.
package enum FloatShortlex {
    /// Upper bound (2^56) below which a non-negative integral float is treated as "simple" and mapped to its integer value directly, avoiding the transformed exponent/mantissa encoding.
    public static let simpleIntegerUpperBound = 72_057_594_037_927_936.0 // 2^56

    /// Bitmask isolating the 11-bit exponent field of a ``Double`` bit pattern, forwarded from ``FloatReduction``.
    public static let exponentMask: UInt64 = FloatReduction.doubleExponentMask

    /// Bitmask isolating the 52-bit mantissa field of a ``Double`` bit pattern, forwarded from ``FloatReduction``.
    public static let mantissaMask: UInt64 = FloatReduction.doubleMantissaMask

    /// Exponent bias for IEEE 754 binary64, forwarded from ``FloatReduction`` as ``UInt64`` for use in shortlex key arithmetic.
    public static let exponentBias: UInt64 = .init(FloatReduction.doubleExponentBias)

    /// High bit set on shortlex keys for non-simple floats, ensuring all transformed exponent/mantissa keys sort above the simple integer range.
    public static let nonSimpleTagMask: UInt64 = .init(1) << 63

    /// Maps a `Double` into a lexical key matching Hypothesis-style float ordering.
    ///
    /// This ordering treats non-negative integral floats up to 2^56 as "simple" (key equals the integer value), and encodes other finite values by transformed exponent/mantissa so coarse semantic moves are cheap to discover.
    public static func shortlexKey(for value: Double) -> UInt64 {
        let magnitude = abs(value)

        if magnitude.isNaN {
            return UInt64.max
        }

        if magnitude <= simpleIntegerUpperBound,
           magnitude == magnitude.rounded(.towardZero)
        {
            return UInt64(magnitude)
        }

        let bits = magnitude.bitPattern
        let exponent = (bits >> 52) & exponentMask
        let mantissa = bits & mantissaMask
        let unbiasedExponent = Int64(bitPattern: exponent) - Int64(exponentBias)

        let transformedMantissa: UInt64 = {
            if unbiasedExponent <= 0 {
                return reverseLowerBits(mantissa, count: 52)
            }
            if unbiasedExponent <= 51 {
                let fractionalBits = Int(52 - unbiasedExponent)
                let fractionalMask = (UInt64(1) << fractionalBits) - 1
                let fractionalPart = mantissa & fractionalMask
                return (mantissa ^ fractionalPart) | reverseLowerBits(fractionalPart, count: fractionalBits)
            }
            return mantissa
        }()

        let transformedExponent: UInt64 = {
            if exponent == exponentMask {
                return exponentMask
            }
            if exponent >= exponentBias {
                return exponent - exponentBias
            }
            return 2046 - exponent
        }()

        return nonSimpleTagMask | (transformedExponent << 52) | transformedMantissa
    }

    /// Float overload for callers that are still working in `Float` precision.
    public static func shortlexKey(for value: Float) -> UInt64 {
        shortlexKey(for: Double(value))
    }

    /// Reverses the lowest `count` bits of `value` so that fractional mantissa bits sort toward simpler (fewer trailing digits) values first during shortlex comparison.
    public static func reverseLowerBits(_ value: UInt64, count: Int) -> UInt64 {
        var x = value
        var reversed: UInt64 = 0
        for _ in 0 ..< count {
            reversed = (reversed << 1) | (x & 1)
            x >>= 1
        }
        return reversed
    }
}
