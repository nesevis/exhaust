//
//  CharacterSetRangeExtractionTests.swift
//  ExhaustTests
//
//  NOTE: .character(from:), .string(from:), and #exhaust are Exhaust-only.
//  Character/string generators are inlined using ExhaustCore primitives.
//  #exhaust replaced with exhaustCheck helper.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("CharacterSet Range Extraction")
struct CharacterSetRangeExtractionTests {
    @Test("ScalarRangeSet round-trips back to the original CharacterSet", arguments: allSets)
    func scalarRangeSetRoundTrip(fixture: NamedCharacterSet) {
        let srs = fixture.set.scalarRangeSet()

        // Rebuild a CharacterSet from ScalarRangeSet's ranges.
        var rebuilt = CharacterSet()
        for range in srs.rangeSet.ranges {
            guard let lower = Unicode.Scalar(range.lowerBound),
                  let upper = Unicode.Scalar(range.upperBound - 1)
            else {
                Issue.record("Invalid scalar values in range \(range) for \(fixture.name)")
                continue
            }
            rebuilt.insert(charactersIn: lower ... upper)
        }

        #expect(rebuilt == fixture.set, "Round-trip failed for \(fixture.name)")
    }

    @Test("ScalarRangeSet range counts are positive", arguments: allSets)
    func scalarRangeSetRangeCountsPositive(fixture: NamedCharacterSet) {
        let srs = fixture.set.scalarRangeSet()
        #expect(srs.rangeCount > 0, "Expected positive range count for \(fixture.name)")
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

    @Test("ScalarRangeSet index(of:) round-trips with scalar(at:) for decimal digits")
    func scalarRangeSetIndexOfRoundTrip() {
        let srs = CharacterSet.decimalDigits.scalarRangeSet()
        for i in 0 ..< srs.scalarCount {
            let scalar = srs.scalar(at: i)
            #expect(srs.index(of: scalar) == i)
        }
    }

    @Test("ScalarRangeSet index(of:) round-trips with scalar(at:) when the bottom codepoint is a member of the set")
    func scalarRangeSetIndexOfRoundTripWithMemberBottomCodepoint() {
        let range: ClosedRange<Unicode.Scalar> = "a" ... "z"
        let srs = CharacterSet(charactersIn: range).scalarRangeSet(bottomCodepoint: "m")
        for index in 0 ..< srs.scalarCount {
            let scalar = srs.scalar(at: index)
            let roundTripped = srs.index(of: scalar)
            #expect(
                roundTripped == index,
                "scalar(at: \(index)) = '\(scalar)' maps back to index \(roundTripped) — the bottom codepoint must not be addressable at two indices"
            )
        }
    }

    // MARK: - Generator tests

    @Test("character(from: .decimalDigits) generates only digits")
    func characterFromDecimalDigits() throws {
        let gen = charGen(from: .decimalDigits)
        try exhaustCheck(gen) { char in
            char.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }

    @Test("character(from: .lowercaseLetters) generates only lowercase letters")
    func characterFromLowercaseLetters() throws {
        let gen = charGen(from: .lowercaseLetters)
        try exhaustCheck(gen) { char in
            char.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
        }
    }

    @Test("character(from:) round-trips through reflect and replay")
    func characterFromReflectionRoundTrip() throws {
        let gen = charGen(from: .decimalDigits)
        try exhaustCheck(gen) { value in
            guard let tree = try? Interpreters.reflect(gen, with: value),
                  let replayed = try? Interpreters.replay(gen, using: tree)
            else { return false }
            return replayed == value
        }
    }

    @Test("character(from: .decimalDigits) shrinks toward '0'")
    func characterFromShrinkingDirection() throws {
        let gen = charGen(from: .decimalDigits)
        // Property that fails for digits >= '5' — shrinking should find '5'
        let property: (Character) -> Bool = { $0 < "5" }

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 100)
        while let (value, tree) = try iterator.next() {
            guard property(value) == false else { continue }
            guard case let .reduced(_, _, shrunk) = try Interpreters.choiceGraphReduce(
                gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
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
}

// MARK: - Helpers

/// A CharacterSet fixture with a stable display name for parameterized tests.
struct NamedCharacterSet: Sendable, CustomStringConvertible {
    let set: CharacterSet
    let name: String

    var description: String {
        name
    }
}

private let allSets: [NamedCharacterSet] = [
    .init(set: .alphanumerics, name: "alphanumerics"),
    .init(set: .letters, name: "letters"),
    .init(set: .lowercaseLetters, name: "lowercaseLetters"),
    .init(set: .uppercaseLetters, name: "uppercaseLetters"),
    .init(set: .decimalDigits, name: "decimalDigits"),
    .init(set: .punctuationCharacters, name: "punctuationCharacters"),
    .init(set: .symbols, name: "symbols"),
    .init(set: .controlCharacters, name: "controlCharacters"),
    .init(set: .whitespaces, name: "whitespaces"),
    .init(set: .whitespacesAndNewlines, name: "whitespacesAndNewlines"),
    .init(set: CharacterSet(charactersIn: ("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar)), name: "a...z"),
    .init(set: CharacterSet.alphanumerics.union(.punctuationCharacters), name: "alphanumerics ∪ punctuation"),
]
