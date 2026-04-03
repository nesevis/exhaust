//
//  FloatReduction.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/2/2026.
//

/// Utilities for float-specific reduction phases used by `reduceValues`.
public enum FloatReduction {
    public static let doubleMantissaBits = 52

    public static let doubleExponentBias = 1023

    public static let doubleExponentMask: UInt64 = 0x7FF

    public static let doubleMantissaMask: UInt64 = (UInt64(1) << doubleMantissaBits) - 1

    public static let floatMantissaBits = 23

    public static let floatExponentBias = 127

    public static let floatExponentMask: UInt32 = 0xFF

    public static let floatMantissaMask: UInt32 = (UInt32(1) << floatMantissaBits) - 1

    public static let maxPreciseIntegerDouble = 9_007_199_254_740_992.0 // 2^53

    public static let maxPreciseIntegerFloat = 16_777_216.0 // 2^24

    /// Returns the cutoff above which `x + 1 == x` for a given float tag.
    public static let maxPreciseIntegerFloat16 = Float16Emulation.maxPreciseInteger // 2^11

    public static func maxPreciseInteger(for tag: TypeTag) -> Double {
        switch tag {
        case .double:
            maxPreciseIntegerDouble
        case .float:
            maxPreciseIntegerFloat
        case .float16:
            maxPreciseIntegerFloat16
        default:
            0
        }
    }

    /// Returns the Hypothesis-style special-value shortlist, in probe order.
    public static func specialValues(for tag: TypeTag) -> [Double] {
        switch tag {
        case .double:
            [Double.greatestFiniteMagnitude, Double.infinity, Double.nan]
        case .float:
            [Double(Float.greatestFiniteMagnitude), Double(Float.infinity), Double(Float.nan)]
        case .float16:
            Float16Emulation.specialValues
        default:
            []
        }
    }

    /// Exact integer ratio (`numerator / denominator`) for finite values, reduced by powers of two when representable as 64-bit integers.
    public static func integerRatio(
        for value: Double,
        tag: TypeTag
    ) -> (numerator: Int64, denominator: UInt64)? {
        switch tag {
        case .double:
            return integerRatio(value)
        case .float, .float16:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return integerRatio(narrowed)
        default:
            return nil
        }
    }

    public static func integerRatio(
        _ value: Double
    ) -> (numerator: Int64, denominator: UInt64)? {
        guard value.isFinite else { return nil }
        guard value != 0 else { return (0, 1) }

        let sign: Int64 = value.sign == .minus ? -1 : 1
        let bits = value.magnitude.bitPattern
        let exponentBits = Int((bits >> doubleMantissaBits) & doubleExponentMask)
        let mantissa = bits & doubleMantissaMask

        guard exponentBits != Int(doubleExponentMask) else { return nil }

        let significand: UInt64
        let exponent: Int
        if exponentBits == 0 {
            significand = mantissa
            exponent = 1 - doubleExponentBias - doubleMantissaBits
        } else {
            significand = (UInt64(1) << doubleMantissaBits) | mantissa
            exponent = exponentBits - doubleExponentBias - doubleMantissaBits
        }

        return buildRatio(sign: sign, significand: significand, exponent: exponent)
    }

    public static func integerRatio(
        _ value: Float
    ) -> (numerator: Int64, denominator: UInt64)? {
        guard value.isFinite else { return nil }
        guard value != 0 else { return (0, 1) }

        let sign: Int64 = value.sign == .minus ? -1 : 1
        let bits = value.magnitude.bitPattern
        let exponentBits = Int((bits >> floatMantissaBits) & floatExponentMask)
        let mantissa = bits & floatMantissaMask

        guard exponentBits != Int(floatExponentMask) else { return nil }

        let significand: UInt64
        let exponent: Int
        if exponentBits == 0 {
            significand = UInt64(mantissa)
            exponent = 1 - floatExponentBias - floatMantissaBits
        } else {
            significand = UInt64((UInt32(1) << floatMantissaBits) | mantissa)
            exponent = exponentBits - floatExponentBias - floatMantissaBits
        }

        return buildRatio(sign: sign, significand: significand, exponent: exponent)
    }

    public static func buildRatio(
        sign: Int64,
        significand: UInt64,
        exponent: Int
    ) -> (numerator: Int64, denominator: UInt64)? {
        guard significand > 0 else { return (0, 1) }
        var numerator = significand
        var denominator: UInt64 = 1

        if exponent >= 0 {
            guard exponent < 64 else { return nil }
            let (shifted, overflow) = numerator
                .multipliedReportingOverflow(by: UInt64(1) << exponent)
            guard overflow == false else { return nil }
            numerator = shifted
        } else {
            let shift = -exponent
            guard shift < 64 else { return nil }
            denominator = UInt64(1) << shift
        }

        let commonZeros = min(
            numerator.trailingZeroBitCount,
            denominator.trailingZeroBitCount
        )
        numerator >>= commonZeros
        denominator >>= commonZeros

        guard numerator <= UInt64(Int64.max) else { return nil }
        let magnitude = Int64(numerator)
        return (sign >= 0 ? magnitude : -magnitude, denominator)
    }
}
