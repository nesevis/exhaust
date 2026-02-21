//
//  FloatShortlex.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Utilities for float-specific shortlex/shrink ordering.
public enum FloatShortlex {
    @usableFromInline
    static let simpleIntegerUpperBound = 72_057_594_037_927_936.0 // 2^56

    @usableFromInline
    static let exponentMask: UInt64 = 0x7FF

    @usableFromInline
    static let mantissaMask: UInt64 = (UInt64(1) << 52) - 1

    @usableFromInline
    static let exponentBias: UInt64 = 1023

    @usableFromInline
    static let nonSimpleTagMask: UInt64 = UInt64(1) << 63

    /// Maps a `Double` into a lexical key matching Hypothesis-style float ordering.
    ///
    /// This ordering treats non-negative integral floats up to 2^56 as "simple"
    /// (key equals the integer value), and encodes other finite values by transformed
    /// exponent/mantissa so coarse semantic moves are cheap to discover.
    @inlinable
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
    @inlinable
    public static func shortlexKey(for value: Float) -> UInt64 {
        shortlexKey(for: Double(value))
    }

    @usableFromInline
    static func reverseLowerBits(_ value: UInt64, count: Int) -> UInt64 {
        var x = value
        var reversed: UInt64 = 0
        for _ in 0..<count {
            reversed = (reversed << 1) | (x & 1)
            x >>= 1
        }
        return reversed
    }
}
