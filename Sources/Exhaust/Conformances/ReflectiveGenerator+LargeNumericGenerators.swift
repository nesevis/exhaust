//
//  ReflectiveGenerator+LargeNumericGenerators.swift
//  Exhaust
//

import ExhaustCore

// MARK: - Int128 / UInt128 generators
//
// These are composite generators built from two UInt64 halves.
// Limitations:
// - Boundary analysis sees two independent UInt64 parameters, not one 128-bit value
// - Shrinking operates on each half independently (high half first, then low)
// - Range-constrained generation is not supported
// - Size scaling is not supported

public extension ReflectiveGenerator {
    /// Generates arbitrary `UInt128` values from two `UInt64` halves.
    static func uint128() -> ReflectiveGenerator<UInt128> {
        Gen.zip(
            Gen.choose(in: UInt64.min ... .max),
            Gen.choose(in: UInt64.min ... .max)
        ).mapped(
            forward: { high, low in
                UInt128(high) << 64 | UInt128(low)
            },
            backward: { value in
                (UInt64(truncatingIfNeeded: value >> 64),
                 UInt64(truncatingIfNeeded: value))
            }
        )
    }

    /// Generates arbitrary `Int128` values from two `UInt64` halves.
    ///
    /// The high half uses sign-bit XOR so that shrinking naturally drives
    /// toward zero: the mapped bit pattern orders negative → zero → positive.
    static func int128() -> ReflectiveGenerator<Int128> {
        Gen.zip(
            Gen.choose(in: UInt64.min ... .max),
            Gen.choose(in: UInt64.min ... .max)
        ).mapped(
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
