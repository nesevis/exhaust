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
    ///
    /// ```swift
    /// let gen = #gen(.character(in: "a"..."z"))
    /// ```
    ///
    /// - Parameter simplest: The character that each generated character reduces to when the reducer minimizes the counterexample. This character occupies index 0 in the shortlex ordering, so any character that is not essential to the property failure will be replaced by it. Defaults to space if the range contains it, otherwise the range's lower bound. Must be within the range.
    static func character(
        in range: ClosedRange<Character>? = nil,
        simplest: Unicode.Scalar? = nil
    ) -> ReflectiveGenerator<Character> {
        guard let range else {
            return characterGenerator(from: defaultScalarRangeSet)
        }
        let lower = range.lowerBound.unicodeScalars.min()!
        let upper = range.upperBound.unicodeScalars.max()!
        let characterSet = CharacterSet(charactersIn: lower ... upper)
        let bottom = resolveSimplest(simplest, in: characterSet)
        return characterGenerator(from: characterSet.scalarRangeSet(bottomCodepoint: bottom))
    }

    /// Generates a random Unicode string with size-scaled or fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.string(length: 1...20))
    /// ```
    static func string(
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        stringGenerator(from: defaultScalarRangeSet, length: length, scaling: scaling)
    }

    /// Generates a random printable ASCII string (U+0020--U+007E) with size-scaled or fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.asciiString(length: 1...20))
    /// ```
    static func asciiString(
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        stringGenerator(from: asciiScalarRangeSet, length: length, scaling: scaling)
    }

    /// Convenience overload accepting `ClosedRange<Int>` for string length.
    static func string(
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let uint64Range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return string(length: uint64Range, scaling: scaling)
    }

    /// Convenience overload accepting `ClosedRange<Int>` for ASCII string length.
    static func asciiString(
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let uint64Range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return asciiString(length: uint64Range, scaling: scaling)
    }

    // MARK: - CharacterSet-based generators

    /// Generates a random character from the given ``CharacterSet``.
    ///
    /// Uses ``ScalarRangeSet`` to flatten the character set into a single contiguous index space, then picks via ``Gen/choose(in:)`` with O(log n) lookup.
    ///
    /// ```swift
    /// let gen = #gen(.character(from: .letters))
    /// ```
    ///
    /// - Parameter simplest: The character that each generated character reduces to when the reducer minimizes the counterexample. Any character not essential to the property failure will be replaced by this one. Defaults to space if the set contains it, otherwise nil (the set's natural lower bound becomes index 0). Must be in the set if provided.
    static func character(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil
    ) -> ReflectiveGenerator<Character> {
        let bottom = resolveSimplest(simplest, in: characterSet)
        return characterGenerator(from: characterSet.scalarRangeSet(bottomCodepoint: bottom))
    }

    /// Generates a random character from the union of two or more ``CharacterSet``s.
    ///
    /// ```swift
    /// let gen = #gen(.character(from: .letters, .decimalDigits))
    /// ```
    static func character(from first: CharacterSet, _ rest: CharacterSet...) -> ReflectiveGenerator<Character> {
        let combined = rest.reduce(first) { $0.union($1) }
        return character(from: combined)
    }

    /// Generates a random string whose characters are drawn from the given ``CharacterSet``.
    ///
    /// ```swift
    /// let gen = #gen(.string(from: .letters, length: 1...10))
    /// ```
    ///
    /// - Parameter simplest: The character that each generated character reduces to when the reducer minimizes the counterexample. Any character not essential to the property failure will be replaced by this one. Defaults to space if the set contains it, otherwise nil (the set's natural lower bound becomes index 0). Must be in the set if provided.
    static func string(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil,
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        let bottom = resolveSimplest(simplest, in: characterSet)
        return stringGenerator(from: characterSet.scalarRangeSet(bottomCodepoint: bottom), length: length, scaling: scaling)
    }
}

// MARK: - Simplest Character Resolution

/// Resolves the bottom codepoint for a character set.
///
/// - If the caller provides an explicit `simplest`, validates it is in the set and returns it.
/// - If nil, returns space if the set contains it, otherwise nil (the set's natural lower bound becomes index 0).
private func resolveSimplest(
    _ explicit: Unicode.Scalar?,
    in characterSet: CharacterSet
) -> Unicode.Scalar? {
    if let explicit {
        precondition(
            characterSet.contains(explicit),
            "simplest scalar U+\(String(explicit.value, radix: 16, uppercase: true)) is not in the CharacterSet"
        )
        return explicit
    }
    if characterSet.contains(" ") {
        return " "
    }
    return nil
}

// MARK: - ScalarRangeSet-based generators (no CharacterSet reconstruction)

/// Builds a character generator directly from a pre-computed ``ScalarRangeSet``.
private func characterGenerator(from srs: ScalarRangeSet) -> ReflectiveGenerator<Character> {
    let operation = ReflectiveOperation.chooseBits(
        min: 0,
        max: UInt64(srs.scalarCount - 1),
        tag: .character,
        isRangeExplicit: true
    )
    let innerGen = ReflectiveGenerator<Character>.impure(operation: operation) { result in
        guard let convertible = result as? any BitPatternConvertible else {
            throw GeneratorError.typeMismatch(
                expected: "any BitPatternConvertible",
                actual: String(describing: Swift.type(of: result))
            )
        }
        return .pure(Character(srs.scalar(at: Int(convertible.bitPattern64))))
    }
    return Gen.contramap(
        { (char: Character) throws -> UInt32 in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return UInt32(srs.index(of: scalar))
        },
        innerGen
    )
}

/// Builds a string generator directly from a pre-computed ``ScalarRangeSet``.
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

/// All assigned Unicode scalars minus illegals. Reduces toward space (U+0020).
private let defaultScalarRangeSet: ScalarRangeSet =
    CharacterSet.illegalCharacters.inverted.scalarRangeSet(bottomCodepoint: " ")

/// Printable ASCII (U+0020–U+007E). Space is naturally at index 0; no bottom codepoint needed.
private let asciiScalarRangeSet: ScalarRangeSet =
    CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()
