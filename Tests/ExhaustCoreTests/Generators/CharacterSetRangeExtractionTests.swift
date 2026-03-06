//
//  CharacterSetRangeExtractionTests.swift
//  ExhaustTests
//
//  NOTE: .character(from:), .string(from:), and #exhaust are Exhaust-only.
//  Character/string generators are inlined using ExhaustCore primitives.
//  #exhaust replaced with exhaustCheck helper.
//

import Foundation
import Testing
@testable import ExhaustCore

@Suite("CharacterSet Range Extraction")
struct CharacterSetRangeExtractionTests {
    @Test("Alphanumerics round-trip")
    func alphanumerics() {
        verifyRoundTrip(.alphanumerics, name: "alphanumerics")
    }

    @Test("Letters round-trip")
    func letters() {
        verifyRoundTrip(.letters, name: "letters")
    }

    @Test("Lowercase letters round-trip")
    func lowercaseLetters() {
        verifyRoundTrip(.lowercaseLetters, name: "lowercaseLetters")
    }

    @Test("Uppercase letters round-trip")
    func uppercaseLetters() {
        verifyRoundTrip(.uppercaseLetters, name: "uppercaseLetters")
    }

    @Test("Decimal digits round-trip")
    func decimalDigits() {
        verifyRoundTrip(.decimalDigits, name: "decimalDigits")
    }

    @Test("Punctuation characters round-trip")
    func punctuationCharacters() {
        verifyRoundTrip(.punctuationCharacters, name: "punctuationCharacters")
    }

    @Test("Symbols round-trip")
    func symbols() {
        verifyRoundTrip(.symbols, name: "symbols")
    }

    @Test("Control characters round-trip")
    func controlCharacters() {
        verifyRoundTrip(.controlCharacters, name: "controlCharacters")
    }

    @Test("Whitespaces round-trip")
    func whitespaces() {
        verifyRoundTrip(.whitespaces, name: "whitespaces")
    }

    @Test("Whitespaces and newlines round-trip")
    func whitespacesAndNewlines() {
        verifyRoundTrip(.whitespacesAndNewlines, name: "whitespacesAndNewlines")
    }

    @Test("Custom a...z round-trip")
    func customLowercaseAZ() {
        let range: ClosedRange<Unicode.Scalar> = "a" ... "z"
        verifyRoundTrip(CharacterSet(charactersIn: range), name: "a...z")
    }

    @Test("Composite alphanumerics ∪ punctuation round-trip")
    func compositeAlphanumericsPunctuation() {
        verifyRoundTrip(
            CharacterSet.alphanumerics.union(.punctuationCharacters),
            name: "alphanumerics ∪ punctuation",
        )
    }

    @Test("Gap analysis across all predefined CharacterSets")
    func gapAnalysis() {
        for (characterSet, name) in allSets {
            let ranges = closedRanges(from: characterSet)
            let gaps = gapsBetween(ranges)
            guard !gaps.isEmpty else {
                print("[\(name)] \(ranges.count) range(s), no gaps")
                continue
            }

            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2]
            let average = gaps.reduce(0, +) / UInt64(gaps.count)
            let min = sorted.first!
            let max = sorted.last!

            print("[\(name)] \(ranges.count) ranges, \(gaps.count) gaps — "
                + "min: \(min), median: \(median), avg: \(average), max: \(max)")
        }
    }

    @Test("Coalescing nearby ranges at various thresholds")
    func coalesceAnalysis() {
        let thresholds: [UInt64] = [2, 4, 8, 16, 32, 64, 128, 256]

        for (characterSet, name) in allSets {
            let ranges = closedRanges(from: characterSet)
            guard ranges.count > 1 else { continue }

            let totalScalars = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
            var line = "[\(name)] raw: \(ranges.count)"

            for threshold in thresholds {
                let coalesced = coalesce(ranges, maxGap: threshold)
                let coalescedScalars = coalesced.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
                let wastePercent = Double(coalescedScalars - totalScalars) / Double(coalescedScalars) * 100
                line += "  ≤\(threshold): \(coalesced.count) (\(String(format: "%.1f", wastePercent))% waste)"
            }

            print(line)
        }
    }

    // MARK: - ScalarRangeSet tests

    @Test("ScalarRangeSet round-trip for all CharacterSets")
    func scalarRangeSetRoundTrip() {
        for (characterSet, name) in allSets {
            verifyScalarRangeSetRoundTrip(characterSet, name: name)
        }
    }

    @Test("ScalarRangeSet range counts are positive for all predefined CharacterSets")
    func scalarRangeSetRangeCountsPositive() {
        for (characterSet, name) in allSets {
            let srs = characterSet.scalarRangeSet()
            #expect(
                srs.rangeCount > 0,
                "Expected positive range count for \(name)",
            )
        }
    }

    @Test("ScalarRangeSet scalar(at:) covers full index space")
    func scalarAtIndexCoversFullSpace() {
        let srs = CharacterSet.decimalDigits.scalarRangeSet()
        var rebuilt = CharacterSet()
        for i in 0 ..< srs.scalarCount {
            rebuilt.insert(srs.scalar(at: i))
        }
        #expect(rebuilt == CharacterSet.decimalDigits)
    }

    @Test("ScalarRangeSet scalar(at:) boundary values for a...z")
    func scalarAtIndexBoundaries() {
        let range: ClosedRange<Unicode.Scalar> = "a" ... "z"
        let srs = CharacterSet(charactersIn: range).scalarRangeSet()
        #expect(srs.scalarCount == 26)
        #expect(srs.rangeCount == 1)
        #expect(srs.scalar(at: 0) == "a")
        #expect(srs.scalar(at: 25) == "z")
    }

    @Test("ScalarRangeSet summary: ranges vs pick-space size")
    func scalarRangeSetSummary() {
        for (characterSet, name) in allSets {
            let srs = characterSet.scalarRangeSet()
            print("[\(name)] \(srs.rangeCount) ranges, \(srs.scalarCount) scalars — 1 pick(0..<\(srs.scalarCount))")
        }
    }

    @Test("ScalarRangeSet index(of:) round-trips with scalar(at:) for decimal digits")
    func scalarRangeSetIndexOfRoundTrip() {
        let srs = CharacterSet.decimalDigits.scalarRangeSet()
        for i in 0 ..< srs.scalarCount {
            let scalar = srs.scalar(at: i)
            #expect(srs.index(of: scalar) == i)
        }
    }

    // MARK: - Generator tests

    @Test("character(from: .decimalDigits) generates only digits")
    func characterFromDecimalDigits() throws {
        let gen = characterGen(from: .decimalDigits)
        try exhaustCheck(gen) { char in
            char.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }

    @Test("character(from: .lowercaseLetters) generates only lowercase letters")
    func characterFromLowercaseLetters() throws {
        let gen = characterGen(from: .lowercaseLetters)
        try exhaustCheck(gen) { char in
            char.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
        }
    }

    @Test("character(from:) round-trips through reflect and replay")
    func characterFromReflectionRoundTrip() throws {
        let gen = characterGen(from: .decimalDigits)
        try exhaustCheck(gen) { value in
            guard let tree = try? Interpreters.reflect(gen, with: value),
                  let replayed = try? Interpreters.replay(gen, using: tree)
            else { return false }
            return replayed == value
        }
    }

    @Test("character(from: .decimalDigits) shrinks toward '0'")
    func characterFromShrinkingDirection() throws {
        let gen = characterGen(from: .decimalDigits)
        // Property that fails for digits >= '5' — shrinking should find '5'
        let property: (Character) -> Bool = { $0 < "5" }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 100)
        while let (value, tree) = try iterator.next() {
            guard !property(value) else { continue }
            guard let (_, shrunk) = try Interpreters.reduce(
                gen: gen, tree: tree, config: .fast, property: property,
            ) else { continue }
            // Shrunk value should be '5' (the smallest digit failing the property)
            #expect(shrunk == "5", "Expected shrunk digit to be '5', got '\(shrunk)'")
            return
        }
        Issue.record("No counterexample found to test shrinking")
    }

    @Test("string(from: .alphanumerics) generates strings whose scalars are all in .alphanumerics")
    func stringFromAlphanumerics() throws {
        let gen = stringGen(from: .alphanumerics, length: 1 ... 10)
        try exhaustCheck(gen) { string in
            string.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    @Test("Variadic character(from:) is equivalent to union")
    func variadicCharacterFromEquivalence() throws {
        let variadicGen: ReflectiveGenerator<Character> = characterGen(from: .letters.union(.decimalDigits))
        let unionGen: ReflectiveGenerator<Character> = characterGen(from: .letters.union(.decimalDigits))

        // Both should produce the same set of valid characters
        var variadicIterator = ValueAndChoiceTreeInterpreter(variadicGen, seed: 42, maxRuns: 200)
        var unionIterator = ValueAndChoiceTreeInterpreter(unionGen, seed: 42, maxRuns: 200)

        while let (variadicValue, _) = try variadicIterator.next(),
              let (unionValue, _) = try unionIterator.next()
        {
            #expect(variadicValue == unionValue, "Variadic and union generators should produce identical values with same seed")
        }
    }
}

// MARK: - Helpers

/// Builds a character generator from a CharacterSet using ExhaustCore primitives.
private func characterGen(from characterSet: CharacterSet) -> ReflectiveGenerator<Character> {
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

/// Builds a string generator from a CharacterSet using ExhaustCore primitives.
private func stringGen(
    from characterSet: CharacterSet,
    length: ClosedRange<UInt64>,
) -> ReflectiveGenerator<String> {
    let charGen = characterGen(from: characterSet)
    return Gen.contramap(
        { (s: String) throws -> [Character] in s.unicodeScalars.map { Character($0) } },
        Gen.arrayOf(charGen, within: length).map { String($0) },
    )
}

/// Replacement for `#exhaust` macro.
private func exhaustCheck<T>(
    _ gen: ReflectiveGenerator<T>,
    maxIterations: UInt64 = 100,
    seed: UInt64 = 42,
    property: (T) -> Bool,
) throws {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = try iter.next() {
        #expect(property(value), "Property failed for value: \(value)")
    }
}

private func verifyRoundTrip(_ characterSet: CharacterSet, name: String) {
    let srs = characterSet.scalarRangeSet()

    // Rebuild CharacterSet from ScalarRangeSet's ranges
    var rebuilt = CharacterSet()
    for range in srs.rangeSet.ranges {
        guard let lower = Unicode.Scalar(range.lowerBound),
              let upper = Unicode.Scalar(range.upperBound - 1)
        else {
            Issue.record("Invalid scalar values in range \(range) for \(name)")
            continue
        }
        rebuilt.insert(charactersIn: lower ... upper)
    }

    #expect(rebuilt == characterSet, "Round-trip failed for \(name)")
    print("[\(name)] \(srs.rangeCount) ranges")
}

private let allSets: [(CharacterSet, String)] = [
    (.alphanumerics, "alphanumerics"),
    (.letters, "letters"),
    (.lowercaseLetters, "lowercaseLetters"),
    (.uppercaseLetters, "uppercaseLetters"),
    (.decimalDigits, "decimalDigits"),
    (.punctuationCharacters, "punctuationCharacters"),
    (.symbols, "symbols"),
    (.controlCharacters, "controlCharacters"),
    (.whitespaces, "whitespaces"),
    (.whitespacesAndNewlines, "whitespacesAndNewlines"),
    (CharacterSet(charactersIn: ("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar)), "a...z"),
    (.alphanumerics.union(.punctuationCharacters), "alphanumerics ∪ punctuation"),
]

/// Converts a `CharacterSet` into `[ClosedRange<UInt64>]` via `ScalarRangeSet` for analysis tests.
private func closedRanges(from characterSet: CharacterSet) -> [ClosedRange<UInt64>] {
    let srs = characterSet.scalarRangeSet()
    return srs.rangeSet.ranges.map { range in
        UInt64(range.lowerBound) ... UInt64(range.upperBound - 1)
    }
}

private func gapsBetween(_ ranges: [ClosedRange<UInt64>]) -> [UInt64] {
    guard ranges.count > 1 else { return [] }
    return (1 ..< ranges.count).map { i in
        ranges[i].lowerBound - ranges[i - 1].upperBound - 1
    }
}

private func verifyScalarRangeSetRoundTrip(_ characterSet: CharacterSet, name: String) {
    let srs = characterSet.scalarRangeSet()

    // Rebuild CharacterSet from the RangeSet's ranges
    var rebuilt = CharacterSet()
    for range in srs.rangeSet.ranges {
        guard let lower = Unicode.Scalar(range.lowerBound),
              let upper = Unicode.Scalar(range.upperBound - 1)
        else {
            Issue.record("Invalid scalar values in range \(range) for \(name)")
            continue
        }
        rebuilt.insert(charactersIn: lower ... upper)
    }

    #expect(rebuilt == characterSet, "ScalarRangeSet round-trip failed for \(name)")
}

private func coalesce(_ ranges: [ClosedRange<UInt64>], maxGap: UInt64) -> [ClosedRange<UInt64>] {
    guard var current = ranges.first else { return [] }
    var result: [ClosedRange<UInt64>] = []
    for range in ranges.dropFirst() {
        if range.lowerBound - current.upperBound - 1 <= maxGap {
            current = current.lowerBound ... range.upperBound
        } else {
            result.append(current)
            current = range
        }
    }
    result.append(current)
    return result
}
