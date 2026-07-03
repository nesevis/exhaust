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
        Gen.data()
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
        scaling: SizeScaling<Int> = .linear
    ) -> ReflectiveGenerator<Data> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return Gen.data(within: range, scaling: uint64LengthScaling(scaling))
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
        length: Int
    ) -> ReflectiveGenerator<Data> {
        precondition(length >= 0, "Length must be non-negative")
        return Gen.data(length: UInt64(length))
    }

    // MARK: - Prefix Overloads

    /// Generates arbitrary `Data` values starting with fixed bytes, followed by a size-scaled random suffix.
    ///
    /// Use this when testing code that identifies binary formats by their leading magic bytes. The prefix is constant and never shrunk; only the random suffix participates in generation and reduction.
    ///
    /// ```swift
    /// let magic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    /// let gen = #gen(.data(prefix: magic))
    /// ```
    ///
    /// - Parameter prefix: Fixed bytes prepended to every generated value.
    /// - Returns: A generator producing `Data` starting with `prefix` followed by random bytes.
    static func data(
        prefix: [UInt8]
    ) -> ReflectiveGenerator<Data> {
        Gen.data(prefix: prefix)
    }

    /// Generates arbitrary `Data` values starting with fixed bytes, followed by a random suffix with length in the given range.
    ///
    /// The `length` parameter controls the number of random bytes after the prefix. The total byte count of each generated value equals the prefix length plus the suffix length.
    ///
    /// ```swift
    /// let magic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    /// let gen = #gen(.data(prefix: magic, length: 256...1024))
    /// ```
    ///
    /// - Parameters:
    ///   - prefix: Fixed bytes prepended to every generated value.
    ///   - length: The allowed range of random suffix byte lengths.
    ///   - scaling: How the suffix length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing `Data` starting with `prefix` followed by random bytes.
    static func data(
        prefix: [UInt8],
        length: ClosedRange<Int>,
        scaling: SizeScaling<Int> = .linear
    ) -> ReflectiveGenerator<Data> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return Gen.data(prefix: prefix, within: range, scaling: uint64LengthScaling(scaling))
    }

    /// Generates arbitrary `Data` values starting with fixed bytes, followed by exactly `length` random bytes.
    ///
    /// ```swift
    /// let magic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    /// let gen = #gen(.data(prefix: magic, length: 512))
    /// ```
    ///
    /// - Parameters:
    ///   - prefix: Fixed bytes prepended to every generated value.
    ///   - length: The exact number of random bytes after the prefix.
    /// - Returns: A generator producing `Data` starting with `prefix` followed by `length` random bytes.
    static func data(
        prefix: [UInt8],
        length: Int
    ) -> ReflectiveGenerator<Data> {
        precondition(length >= 0, "Length must be non-negative")
        return Gen.data(prefix: prefix, length: UInt64(length))
    }
}
