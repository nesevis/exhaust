//
//  ReflectiveGenerator+Data.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates arbitrary `Data` values with size-scaled length.
    ///
    /// Each byte is drawn uniformly from 0 through 255. The data length scales with the interpreter's size parameter, producing shorter sequences early in a test run and longer ones later.
    ///
    /// ```swift
    /// let gen = #gen(.data())
    /// ```
    ///
    /// - Returns: A generator producing random `Data` of size-scaled length.
    static func data() -> ReflectiveGenerator<Data> {
        Gen.arrayOf(Gen.choose(in: UInt8.min ... UInt8.max))
            .mapped(
                forward: { Data($0) },
                backward: { Array($0) }
            )
    }

    /// Generates arbitrary `Data` values with length within a specified range.
    ///
    /// ```swift
    /// let gen = #gen(.data(length: 16...64))
    /// ```
    ///
    /// - Parameters:
    ///   - length: The allowed range of byte lengths.
    ///   - scaling: How data length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing `Data` with length in the given range.
    static func data(
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Data> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            within: range,
            scaling: scaling
        ).mapped(
            forward: { Data($0) },
            backward: { Array($0) }
        )
    }

    /// Generates arbitrary `Data` values of an exact fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.data(length: 32))
    /// ```
    ///
    /// - Parameter length: The exact number of bytes in each generated `Data`.
    /// - Returns: A generator producing `Data` of the specified length.
    static func data(
        length: UInt64
    ) -> ReflectiveGenerator<Data> {
        Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            exactly: length
        ).mapped(
            forward: { Data($0) },
            backward: { Array($0) }
        )
    }
}
