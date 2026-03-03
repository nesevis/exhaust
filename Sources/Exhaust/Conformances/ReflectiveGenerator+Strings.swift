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
        if let range {
            let charMin = range.lowerBound.unicodeScalars.min()?.value ?? 0
            let charMax = range.upperBound.unicodeScalars.max()?.value ?? 0
            return Gen.chooseCharacter(in: charMin.bitPattern64 ... charMax.bitPattern64)
        }
        return Gen.chooseCharacter()
    }

    static func string(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        if let length {
            return Gen.arrayOf(.character(), within: length, scaling: scaling)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(.character())
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }

    static func asciiString(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        if let length {
            return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]), within: length, scaling: scaling)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]))
            .mapped(forward: { String($0) }, backward: { Array($0) })
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
                        "Character has no scalars"
                    )
                }
                return srs.index(of: scalar)
            },
            Gen.choose(in: 0 ... srs.scalarCount - 1)
                .map { Character(srs.scalar(at: $0)) }
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
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        let charGen: ReflectiveGenerator<Character> = .character(from: characterSet)
        if let length {
            return Gen.arrayOf(charGen, within: length, scaling: scaling)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(charGen)
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
}
