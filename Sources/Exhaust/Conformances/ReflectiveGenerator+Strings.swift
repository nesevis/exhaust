//
//  ReflectiveGenerator+Strings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

import Foundation
@_spi(ExhaustInternal) import ExhaustCore

public extension ReflectiveGenerator {
    static func character(in range: ClosedRange<Character>? = nil) -> ReflectiveGenerator<Character> {
        guard let range else { return .character(from: defaultCharacterSet) }
        let lower = range.lowerBound.unicodeScalars.min()!
        let upper = range.upperBound.unicodeScalars.max()!
        return .character(from: CharacterSet(charactersIn: lower ... upper))
    }

    static func string(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        .string(from: defaultCharacterSet, length: length, scaling: scaling)
    }

    static func asciiString(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        .string(from: asciiCharacterSet, length: length, scaling: scaling)
    }

    static func string(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return string(length: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    static func asciiString(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return asciiString(length: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    // MARK: - CharacterSet-based generators

    /// Generates a random character from the given `CharacterSet`.
    ///
    /// Uses `ScalarRangeSet` to flatten the character set into a single contiguous
    /// index space, then picks via `Gen.choose(in: 0...n-1)` with O(log n) lookup.
    /// Shrinks toward the first scalar in the set (e.g. '0' for `.decimalDigits`).
    static func character(from characterSet: CharacterSet) -> ReflectiveGenerator<Character> {
        let srs = characterSet.scalarRangeSet()
        return Gen.contramap(
            { (char: Character) throws -> Int in
                guard let scalar = char.unicodeScalars.first else {
                    throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                        "Character has no scalars",
                    )
                }
                return srs.index(of: scalar)
            },
            Gen.choose(in: 0 ... srs.scalarCount - 1)
                .map { Character(srs.scalar(at: $0)) },
        )
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
        scaling: SizeScaling<UInt64> = .linear,
    ) -> ReflectiveGenerator<String> {
        let charGen: ReflectiveGenerator<Character> = .character(from: characterSet)
        if let length {
            return Gen.arrayOf(charGen, within: length, scaling: scaling)
                .mapped(
                    forward: { String($0) },
                    // String <-> [Character] isn't bijective when the CharacterSet includes combining marks. The generator produces single-scalar characters, but Array(string) splits by grapheme clusters — so if "e" followed by U+0301 (combining accent) were generated as two characters, the String merges them into "é", and Array(...) returns one Character instead of two.
                    backward: { $0.unicodeScalars.map { Character($0) } },
                )
        }
        return Gen.arrayOf(charGen)
            .mapped(
                forward: { String($0) },
                backward: { $0.unicodeScalars.map { Character($0) } },
            )
    }
}

// MARK: - Default CharacterSets

/// All assigned Unicode scalars minus control characters and illegals.
/// First scalar is U+0020 (space) — shrinking produces readable counterexamples.
private let defaultCharacterSet: CharacterSet =
    .illegalCharacters.inverted.subtracting(.controlCharacters)

/// Printable ASCII (U+0020–U+007E).
private let asciiCharacterSet = CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!)
