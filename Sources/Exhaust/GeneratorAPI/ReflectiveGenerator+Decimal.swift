//
//  ReflectiveGenerator+Decimal.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates `Decimal` values within the given range, quantized to the specified number of decimal places.
    ///
    /// Values are represented internally as `Int64` steps, so total precision is limited to approximately 18 significant digits shared between the integer and fractional parts. The effective integer range depends on `precision`:
    ///
    /// | `precision` | Step size | Effective integer range |
    /// |-------------|-----------|-------------------------|
    /// | 0           | 1         | ±9.2 × 10¹⁸             |
    /// | 2           | 0.01      | ±9.2 × 10¹⁶             |
    /// | 4           | 0.0001    | ±9.2 × 10¹⁴             |
    /// | 8           | 10⁻⁸      | ±9.2 × 10¹⁰             |
    ///
    /// Designed for fixed-point use cases (currency, financial calculations). It is not suitable for arbitrary-precision `Decimal` generation.
    ///
    /// Reflection snaps off-precision values to the nearest representable step and clamps out-of-range values to the nearest bound. This means `reflecting:` with a value that is not exactly representable at the requested precision, or that falls outside the range, will start reduction from the closest representable value rather than rejecting.
    ///
    /// - Parameters:
    ///   - range: The closed range of `Decimal` values to generate within.
    ///   - precision: The number of decimal places, from 0 through 38. Defaults to two. Zero produces integer `Decimal` values.
    /// - Precondition: The range scaled by `10^precision` must fit within `Int64`.
    ///
    /// ```swift
    /// let gen = #gen(.decimal(in: Decimal(string: "0.00")! ... Decimal(string: "100.00")!, precision: 2))
    /// ```
    static func decimal(
        in range: ClosedRange<Decimal>,
        precision: Int = 2
    ) -> ReflectiveGenerator<Decimal> {
        precondition(
            precision >= 0 && precision <= maximumDecimalPrecision,
            "precision must be in 0...\(maximumDecimalPrecision), got \(precision)"
        )
        return Gen.decimal(in: range, precision: UInt8(precision))
    }

    /// Generates `Decimal` values within the given whole-unit range, quantized to the given number of decimal places.
    ///
    /// Accepts `ClosedRange<Int>` so integer literals resolve without explicit type annotation. Each argument of a multi-argument `#gen` is checked against a type variable, and a bare literal range there commits to `ClosedRange<Int>` before the member is looked up, so without this overload `.decimal(in: 0 ... 100)` fails to compile inside `#gen(_:_:)`.
    ///
    /// For bounds with a fractional part, prefer ``decimal(minorUnits:precision:)`` over a floating-point literal. `Decimal` takes float literals through `Double`, so `19.99` written as a literal becomes `19.98999999999999488` and the generated domain is not the one the source says.
    ///
    /// ```swift
    /// let gen = #gen(.decimal(in: 0 ... 100))
    /// ```
    ///
    /// - Parameters:
    ///   - range: The closed range of whole-unit values to generate within.
    ///   - precision: The number of decimal places. Defaults to two.
    /// - Returns: A generator producing `Decimal` values within the range.
    static func decimal(
        in range: ClosedRange<Int>,
        precision: Int = 2
    ) -> ReflectiveGenerator<Decimal> {
        decimal(
            in: Decimal(range.lowerBound) ... Decimal(range.upperBound),
            precision: precision
        )
    }

    /// Generates `Decimal` values from a range expressed in minor units, the integral multiples of `10^-precision`.
    ///
    /// Every bound is an integer, so no value reaches `Decimal` through a binary floating-point literal. At `precision: 2` the minor unit is one hundredth, so `minorUnits: 0 ... 1999` covers `0.00` through `19.99`.
    ///
    /// Use this whenever a bound has a fractional part. The alternatives both cost something: a floating-point literal is silently inexact, and `Decimal(string:)` is exact but verbose and force-unwrapped at every bound.
    ///
    /// ```swift
    /// let gen = #gen(.decimal(minorUnits: 0 ... 1999, precision: 2))
    /// ```
    ///
    /// - Parameters:
    ///   - minorUnits: The closed range of steps, each worth `10^-precision`.
    ///   - precision: The number of decimal places. Defaults to two.
    /// - Returns: A generator producing `Decimal` values quantized to `precision` places.
    static func decimal(
        minorUnits: ClosedRange<Int>,
        precision: Int = 2
    ) -> ReflectiveGenerator<Decimal> {
        precondition(
            precision >= 0 && precision <= maximumDecimalPrecision,
            "precision must be in 0...\(maximumDecimalPrecision), got \(precision)"
        )
        let scale = pow(10, precision) as Decimal
        return decimal(
            in: Decimal(minorUnits.lowerBound) / scale ... Decimal(minorUnits.upperBound) / scale,
            precision: precision
        )
    }
}

// Decimal holds 38 significant digits. Past that, `pow(10, precision)` is NaN and every comparison
// against it is false, so the Int64 range check would reject the whole range and report it as a
// problem with the bounds rather than with the precision that caused it.

/// The largest `precision` the `decimal` generators accept.
private let maximumDecimalPrecision = 38
