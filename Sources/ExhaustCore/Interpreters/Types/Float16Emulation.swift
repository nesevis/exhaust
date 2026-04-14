//
//  Float16Emulation.swift
//  Exhaust
//

import Foundation

// MARK: - IEEE 754 Binary16 Emulation

//
// Provides Double ↔ UInt64 (order-preserving encoded Float16 bit pattern) conversion
// without requiring the Float16 type, which is only available on ARM64.
//
// Binary16 layout (16 bits):
//   bit 15:     sign
//   bits 14–10: exponent (bias 15, all-ones = infinity/NaN)
//   bits 9–0:   mantissa (implicit leading 1 for normals)
//
// Order-preserving encoding (same scheme as Float/Double):
//   positive (sign bit clear): encoded = rawBits ^ 0x8000
//   negative (sign bit set):   encoded = ~rawBits

/// Platform-independent IEEE 754 binary16 (half-precision) emulation for the reduction pipeline.
package enum Float16Emulation {
    private static let signBitMask: UInt16 = 0x8000
    private static let exponentMask: UInt16 = 0x7C00
    private static let mantissaMask: UInt16 = 0x03FF
    private static let exponentBias = 15
    private static let mantissaBits = 10

    /// The maximum integer that can be represented exactly in half-precision (2^11 = 2048).
    public static let maxPreciseInteger: Double = 2048.0

    /// Greatest finite half-precision magnitude (65504).
    public static let greatestFiniteMagnitude: Double = 65504.0

    // MARK: - Encoded Bit Pattern → Double

    /// Converts an order-preserving encoded Float16 bit pattern to a `Double`.
    public static func doubleValue(fromEncoded encoded: UInt64) -> Double {
        let encoded16 = UInt16(encoded & 0xFFFF)
        let raw = decodeOrderPreserving(encoded16)
        return doubleFromRawBits(raw)
    }

    // MARK: - Double → Encoded Bit Pattern

    /// Converts a `Double` to an order-preserving encoded Float16 bit pattern.
    ///
    /// Values outside half-precision range saturate to infinity. NaN is preserved.
    public static func encodedBitPattern(from value: Double) -> UInt64 {
        let raw = rawBitsFromDouble(value)
        return UInt64(encodeOrderPreserving(raw))
    }

    // MARK: - Special Values

    /// Hypothesis-style special-value shortlist for half-precision, as `Double` values.
    public static let specialValues: [Double] = [
        greatestFiniteMagnitude,
        Double.infinity,
        Double.nan,
    ]

    // MARK: - Order-Preserving Encoding

    private static func decodeOrderPreserving(_ encoded: UInt16) -> UInt16 {
        if encoded & signBitMask == 0 {
            ~encoded
        } else {
            encoded ^ signBitMask
        }
    }

    private static func encodeOrderPreserving(_ raw: UInt16) -> UInt16 {
        if raw & signBitMask == 0 {
            raw ^ signBitMask
        } else {
            ~raw
        }
    }

    // MARK: - IEEE 754 Binary16 ↔ Double

    private static func doubleFromRawBits(_ raw: UInt16) -> Double {
        let sign: Double = (raw & signBitMask) != 0 ? -1.0 : 1.0
        let exponentBits = Int((raw & exponentMask) >> mantissaBits)
        let mantissa = raw & mantissaMask

        if exponentBits == 0 {
            if mantissa == 0 {
                // ±0
                return sign * 0.0
            }
            // Subnormal: (-1)^sign × mantissa × 2^(1 - bias - mantissaBits)
            return sign * Double(mantissa) * pow(2.0, Double(1 - exponentBias - mantissaBits))
        }

        if exponentBits == 0x1F {
            if mantissa == 0 {
                return sign * Double.infinity
            }
            return Double.nan
        }

        // Normal: (-1)^sign × (1 + mantissa/1024) × 2^(exponent - bias)
        let significand = 1.0 + Double(mantissa) / Double(1 << mantissaBits)
        return sign * significand * pow(2.0, Double(exponentBits - exponentBias))
    }

    private static func rawBitsFromDouble(_ value: Double) -> UInt16 {
        if value.isNaN {
            // Canonical NaN
            return 0x7E00
        }

        let sign: UInt16 = value.sign == .minus ? signBitMask : 0
        let magnitude = value.magnitude

        if magnitude.isInfinite {
            return sign | exponentMask
        }

        if magnitude == 0 {
            return sign
        }

        // Check for overflow → infinity
        if magnitude > greatestFiniteMagnitude {
            return sign | exponentMask
        }

        // Extract exponent and mantissa
        let exponent = Int(magnitude.exponent)
        let biasedExponent = exponent + exponentBias

        if biasedExponent <= 0 {
            // Subnormal or underflow
            let shift = 1 - exponent - exponentBias
            if shift > mantissaBits {
                return sign // Underflows to ±0
            }
            let mantissa = UInt16((magnitude / pow(2.0, Double(1 - exponentBias - mantissaBits))).rounded(.toNearestOrEven))
            return sign | (mantissa & mantissaMask)
        }

        if biasedExponent >= 0x1F {
            return sign | exponentMask // Overflow to infinity
        }

        // Normal number: round mantissa to 10 bits
        let scaledMantissa = (magnitude / pow(2.0, Double(exponent))) - 1.0
        var mantissa = UInt16((scaledMantissa * Double(1 << mantissaBits)).rounded(.toNearestOrEven))

        // Handle rounding overflow (mantissa rounds up to 1024)
        var adjustedExponent = UInt16(biasedExponent)
        if mantissa >= UInt16(1 << mantissaBits) {
            mantissa = 0
            adjustedExponent += 1
            if adjustedExponent >= 0x1F {
                return sign | exponentMask // Rounds to infinity
            }
        }

        return sign | (adjustedExponent << UInt16(mantissaBits)) | (mantissa & mantissaMask)
    }
}
