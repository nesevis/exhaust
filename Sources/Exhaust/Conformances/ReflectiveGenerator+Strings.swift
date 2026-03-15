//
//  ReflectiveGenerator+Strings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates a random Unicode character, optionally within the given range.
    static func character(in range: ClosedRange<Character>? = nil) -> ReflectiveGenerator<Character> {
        guard let range else { return characterGenerator(from: defaultScalarRangeSet) }
        let lower = range.lowerBound.unicodeScalars.min()!
        let upper = range.upperBound.unicodeScalars.max()!
        return .character(from: CharacterSet(charactersIn: lower ... upper))
    }

    /// Generates a random Unicode string with size-scaled or fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.string(length: 1...20))
    /// ```
    static func string(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        stringGenerator(from: defaultScalarRangeSet, length: length, scaling: scaling)
    }

    /// Generates a random printable ASCII string (U+0020--U+007E) with size-scaled or fixed length.
    static func asciiString(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        stringGenerator(from: asciiScalarRangeSet, length: length, scaling: scaling)
    }

    /// Convenience overload accepting `ClosedRange<Int>` for string length.
    static func string(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return string(length: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    /// Convenience overload accepting `ClosedRange<Int>` for ASCII string length.
    static func asciiString(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return asciiString(length: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    // MARK: - CharacterSet-based generators

    /// Generates a random character from the given `CharacterSet`.
    ///
    /// Uses `ScalarRangeSet` to flatten the character set into a single contiguous index space, then picks via `Gen.choose(in: 0...n-1)` with O(log n) lookup.
    /// Reduces toward the first scalar in the set (e.g. '0' for `.decimalDigits`).
    static func character(from characterSet: CharacterSet) -> ReflectiveGenerator<Character> {
        characterGenerator(from: characterSet.scalarRangeSet())
    }

    /// Generates a random character from the union of the given `CharacterSet`s.
    static func character(from sets: CharacterSet...) -> ReflectiveGenerator<Character> {
        let combined = sets.dropFirst().reduce(sets[0]) { $0.union($1) }
        return character(from: combined)
    }

    /// Generates a random string whose characters are drawn from the given `CharacterSet`.
    static func string(
        from characterSet: CharacterSet,
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        stringGenerator(from: characterSet.scalarRangeSet(), length: length, scaling: scaling)
    }
}

// MARK: - ScalarRangeSet-based generators (no CharacterSet reconstruction)

/// Builds a character generator directly from a pre-computed `ScalarRangeSet`.
private func characterGenerator(from srs: ScalarRangeSet) -> ReflectiveGenerator<Character> {
    Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return srs.index(of: scalar)
        },
        Gen.choose(in: 0 ... srs.scalarCount - 1)
            ._map { Character(srs.scalar(at: $0)) }
    )
}

/// Builds a string generator directly from a pre-computed `ScalarRangeSet`.
///
/// String <-> [Character] isn't bijective when the CharacterSet includes combining marks.
/// The generator produces single-scalar characters, but Array(string) splits by grapheme clusters — so if "e" followed by U+0301 (combining accent) were generated as two characters, the String merges them into "é", and Array(...) returns one Character instead of two. We use `unicodeScalars.map` in the backward direction to preserve the original scalar count.
private func stringGenerator(
    from srs: ScalarRangeSet,
    length: ClosedRange<UInt64>? = nil,
    scaling: SizeScaling<UInt64> = .linear
) -> ReflectiveGenerator<String> {
    let charGen = characterGenerator(from: srs)
    if let length {
        return Gen.arrayOf(charGen, within: length, scaling: scaling)
            .mapped(
                forward: { String($0) },
                backward: { $0.unicodeScalars.map { Character($0) } }
            )
    }
    return Gen.arrayOf(charGen)
        .mapped(
            forward: { String($0) },
            backward: { $0.unicodeScalars.map { Character($0) } }
        )
}

// MARK: - Pre-computed ScalarRangeSets

/// All assigned Unicode scalars minus control characters and illegals.
/// First scalar is U+0020 (space) — test case reduction produces readable counterexamples.
private let defaultScalarRangeSet: ScalarRangeSet =
    CharacterSet.illegalCharacters.inverted.subtracting(.controlCharacters).scalarRangeSet()

/// Printable ASCII (U+0020–U+007E).
private let asciiScalarRangeSet: ScalarRangeSet =
    CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
