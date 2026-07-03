//
//  ReflectiveGenerator+Strings.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates a random Unicode character, optionally within the given range.
    ///
    /// When no range is specified, characters are drawn from all valid Unicode scalars except illegal characters and Private Use Areas. When a range is specified, only scalars within that range are used.
    ///
    /// ```swift
    /// let gen = #gen(.character(in: "a"..."z"))
    /// ```
    ///
    /// - Parameter simplest: The character that the reducer substitutes for any character not essential to the property failure. Unlike integers, characters are code points with no naturally minimal value — the reducer needs an explicit "zero" to drive toward. Defaults to space (U+0020) if the range contains it, otherwise the range's lower bound. Must be within the range.
    static func character(
        in range: ClosedRange<Character>? = nil,
        simplest: Unicode.Scalar? = nil
    ) -> ReflectiveGenerator<Character> {
        Gen.character(in: range, simplest: simplest)
    }

    /// Generates a random Unicode string with size-scaled or fixed length.
    ///
    /// Characters are drawn from all valid Unicode scalars except illegal characters (surrogates, non-characters) and the three Private Use Areas (U+E000–U+F8FF, U+F0000–U+FFFFD, U+100000–U+10FFFD). The remaining space includes assigned characters from all scripts plus unassigned-but-legal code points in the supplementary planes.
    ///
    /// When no length is specified, string length scales with the size parameter from 0 to 100 characters.
    ///
    /// For ASCII-only strings, use ``asciiString(length:scaling:)``. For a specific character set, use ``string(from:length:scaling:)``.
    ///
    /// ```swift
    /// let gen = #gen(.string(length: 1...20))
    /// ```
    static func string(
        length: ClosedRange<Int>? = nil,
        scaling: SizeScaling<Int> = .linear
    ) -> ReflectiveGenerator<String> {
        Gen.string(length: length.map(LengthConversion.uint64Range), scaling: LengthConversion.uint64Scaling(scaling))
    }

    /// Generates a random printable ASCII string (U+0020–U+007E) with size-scaled or fixed length.
    ///
    /// When no length is specified, string length scales with the size parameter from 0 to 100 characters.
    ///
    /// ```swift
    /// let gen = #gen(.asciiString(length: 1...20))
    /// ```
    static func asciiString(
        length: ClosedRange<Int>? = nil,
        scaling: SizeScaling<Int> = .linear
    ) -> ReflectiveGenerator<String> {
        Gen.asciiString(length: length.map(LengthConversion.uint64Range), scaling: LengthConversion.uint64Scaling(scaling))
    }

    // MARK: - CharacterSet-based generators

    /// Generates a random character from the given `CharacterSet`.
    ///
    /// Characters are drawn uniformly from the provided set.
    ///
    /// ```swift
    /// let gen = #gen(.character(from: .letters))
    /// ```
    ///
    /// - Parameter simplest: The character that each generated character reduces to when the reducer minimizes the counterexample. Unlike integers, characters are code points with no naturally minimal value — the reducer needs an explicit "zero" to drive toward. Any character not essential to the property failure will be replaced by this one. Defaults to space (U+0020) if the set contains it, otherwise the set's natural lower bound. Must be in the set if provided.
    static func character(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil
    ) -> ReflectiveGenerator<Character> {
        Gen.character(from: characterSet, simplest: simplest)
    }

    /// Generates a random character from the union of two or more `CharacterSet`s.
    ///
    /// ```swift
    /// let gen = #gen(.character(from: .letters, .decimalDigits))
    /// ```
    static func character(from first: CharacterSet, _ rest: CharacterSet...) -> ReflectiveGenerator<Character> {
        let combined = rest.reduce(first) { $0.union($1) }
        return character(from: combined)
    }

    /// Generates a random string whose characters are drawn from the given `CharacterSet`.
    ///
    /// ```swift
    /// let gen = #gen(.string(from: .letters, length: 1...10))
    /// ```
    ///
    /// - Parameter simplest: The character that each generated character reduces to when the reducer minimizes the counterexample. Unlike integers, characters are code points with no naturally minimal value — the reducer needs an explicit "zero" to drive toward. Any character not essential to the property failure will be replaced by this one. Defaults to space (U+0020) if the set contains it, otherwise the set's natural lower bound. Must be in the set if provided.
    static func string(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil,
        length: ClosedRange<Int>? = nil,
        scaling: SizeScaling<Int> = .linear
    ) -> ReflectiveGenerator<String> {
        Gen.string(from: characterSet, simplest: simplest, length: length.map(LengthConversion.uint64Range), scaling: LengthConversion.uint64Scaling(scaling))
    }
}
