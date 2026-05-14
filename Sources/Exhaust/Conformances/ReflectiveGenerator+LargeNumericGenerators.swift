//
//  ReflectiveGenerator+LargeNumericGenerators.swift
//  Exhaust
//

import ExhaustCore

// MARK: - Int128 / UInt128 generators

public extension ReflectiveGenerator {
    /// Generates arbitrary ``UInt128`` values across the full range.
    ///
    /// ```swift
    /// let gen = #gen(.uint128())
    /// ```
    ///
    /// - Note: Test case reduction operates on each half of the value independently. Range-constrained generation and size-scaled generation are not supported.
    static func uint128() -> ReflectiveGenerator<UInt128> {
        Gen.zip(
            Gen.chooseBits(),
            Gen.chooseBits()
        ).wrapped.mapped(
            forward: { high, low in
                UInt128(high) << 64 | UInt128(low)
            },
            backward: { value in
                (UInt64(truncatingIfNeeded: value >> 64),
                 UInt64(truncatingIfNeeded: value))
            }
        )
    }

    /// Generates arbitrary ``Int128`` values across the full range.
    ///
    /// Test case reduction drives values toward zero.
    ///
    /// ```swift
    /// let gen = #gen(.int128())
    /// ```
    ///
    /// - Note: Test case reduction operates on each half of the value independently. Range-constrained generation and size-scaled generation are not supported.
    static func int128() -> ReflectiveGenerator<Int128> {
        Gen.zip(
            Gen.chooseBits(),
            Gen.chooseBits()
        ).wrapped.mapped(
            forward: { high, low in
                let bits = UInt128(high) << 64 | UInt128(low)
                return Int128(bitPattern: bits)
            },
            backward: { value in
                let bits = UInt128(bitPattern: value)
                return (UInt64(truncatingIfNeeded: bits >> 64),
                        UInt64(truncatingIfNeeded: bits))
            }
        )
    }
}
