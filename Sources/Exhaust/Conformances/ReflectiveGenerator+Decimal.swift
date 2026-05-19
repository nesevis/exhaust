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
    /// Designed for fixed-point use cases (currency, financial calculations) — not suitable for arbitrary-precision `Decimal` generation.
    ///
    /// Reflection snaps off-precision values to the nearest representable step and clamps out-of-range values to the nearest bound. This means `reflecting:` with a value that is not exactly representable at the requested precision, or that falls outside the range, will start reduction from the closest representable value rather than rejecting.
    ///
    /// - Parameters:
    ///   - range: The closed range of `Decimal` values to generate within.
    ///   - precision: The number of decimal places. Must be non-negative. Zero produces integer `Decimal` values.
    /// - Precondition: The range scaled by `10^precision` must fit within `Int64`.
    ///
    /// ```swift
    /// let gen = #gen(.decimal(in: Decimal(string: "0.00")! ... Decimal(string: "100.00")!, precision: 2))
    /// ```
    static func decimal(
        in range: ClosedRange<Decimal>,
        precision: UInt8
    ) -> ReflectiveGenerator<Decimal> {
        let multiplier = pow(10, Int(precision)) as Decimal
        let lowerStep = Int64(truncating: (range.lowerBound * multiplier) as NSDecimalNumber)
        let upperStep = Int64(truncating: (range.upperBound * multiplier) as NSDecimalNumber)

        precondition(
            lowerStep <= upperStep,
            "Lower bound must not exceed upper bound after scaling"
        )

        return Gen.choose(in: lowerStep ... upperStep).wrapped
            .mapped(
                forward: { step in
                    Decimal(step) / multiplier
                },
                backward: { target in
                    let scaled = Int64(truncating: (target * multiplier) as NSDecimalNumber)
                    return min(max(scaled, lowerStep), upperStep)
                }
            )
    }
}
