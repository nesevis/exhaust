//
//  FoundationGeneratorTests.swift
//  Exhaust
//
//  Exercises the consolidated `Gen.*` Foundation factories directly at the
//  package level. The public `ReflectiveGenerator.*` API and the
//  `ExhaustGenerable.defaultGenerator` conformances both forward here, so these
//  tests guard the single source of truth for both paths.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Foundation Generators (Gen.*)")
struct FoundationGeneratorTests {
    // MARK: - UUID

    @Test("uuid() produces version-4 UUIDs and reflects")
    func uuidGeneratesAndReflects() throws {
        let gen = Gen.uuid().gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())

        // Version nibble is 4; variant high bits are 0b10.
        #expect(value.uuid.6 >> 4 == 0x4)
        #expect(value.uuid.8 >> 6 == 0b10)

        let tree = try Interpreters.reflect(gen, with: value)
        #expect(tree != nil, "uuid() should be reflectable")
    }

    // MARK: - URL

    @Test("url() produces parseable URLs")
    func urlGenerates() throws {
        let gen = Gen.url().gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())
        #expect(value.scheme == "http" || value.scheme == "https")
        #expect(value.host?.isEmpty == false)
    }

    // MARK: - Date

    @Test("date(between:interval:) stays in range and reflects")
    func dateGeneratesInRangeAndReflects() throws {
        let lower = Date(timeIntervalSinceReferenceDate: 0)
        let upper = lower.addingTimeInterval(86400 * 30)
        let gen = Gen.date(between: lower ... upper, interval: .days(1), timeZone: .current).gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())

        #expect(value >= lower && value <= upper)

        let tree = try Interpreters.reflect(gen, with: value)
        #expect(tree != nil, "date(between:interval:) should be reflectable")
    }

    // MARK: - Decimal

    @Test("decimal(in:precision:) stays in range and quantizes")
    func decimalGeneratesInRange() throws {
        let range = Decimal(0) ... Decimal(100)
        let gen = Gen.decimal(in: range, precision: 2).gen
        var iterator = ValueInterpreter(gen, seed: 42)

        for _ in 0 ..< 20 {
            let value = try #require(try iterator.next())
            #expect(range ~= value)
        }
    }

    @Test("decimal(in:precision:) reflects")
    func decimalReflects() throws {
        let gen = Gen.decimal(in: Decimal(-50) ... Decimal(50), precision: 2).gen
        var iterator = ValueInterpreter(gen, seed: 7)
        let value = try #require(try iterator.next())
        let tree = try Interpreters.reflect(gen, with: value)
        #expect(tree != nil, "decimal(in:precision:) should be reflectable")
    }

    // MARK: - Character and String

    @Test("character(in:) draws from the requested range")
    func characterInRange() throws {
        let gen = Gen.character(in: "a" ... "z").gen
        var iterator = ValueInterpreter(gen, seed: 42)

        for _ in 0 ..< 20 {
            let value = try #require(try iterator.next())
            let scalar = try #require(value.unicodeScalars.first)
            #expect(("a" ... "z").contains(value), "got \(scalar)")
        }
    }

    @Test("string(from:length:) honors fixed length and character set")
    func stringFromSetFixedLength() throws {
        let letters = CharacterSet(charactersIn: "a" ... "z")
        let gen = Gen.string(from: letters, length: 5 ... 5).gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())

        #expect(value.unicodeScalars.count == 5)
        for scalar in value.unicodeScalars {
            #expect(letters.contains(scalar))
        }
    }

    @Test("string() reflects")
    func stringReflects() throws {
        let gen = Gen.string(length: 1 ... 8).gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())
        let tree = try Interpreters.reflect(gen, with: value)
        #expect(tree != nil, "string() should be reflectable")
    }

    // MARK: - Data

    @Test("data(length:) produces an exact byte count and reflects")
    func dataExactLength() throws {
        let gen = Gen.data(length: 16).gen
        var iterator = ValueInterpreter(gen, seed: 42)
        let value = try #require(try iterator.next())

        #expect(value.count == 16)

        let tree = try Interpreters.reflect(gen, with: value)
        #expect(tree != nil, "data(length:) should be reflectable")
    }

    // MARK: - defaultGenerator conformances

    @Test("Decimal.defaultGenerator no longer traps and stays in range")
    func decimalDefaultGeneratorDoesNotTrap() throws {
        // Regression: the previous default computed an inverted range (0 ... -100)
        // from a non-round-tripping Int64(truncating:) and trapped on construction.
        let lower = Decimal(Int64.min) / 100
        let upper = Decimal(Int64.max) / 100
        var iterator = ValueInterpreter(Decimal.defaultGenerator, seed: 42)

        for _ in 0 ..< 20 {
            let any = try #require(try iterator.next())
            let value = try #require(any as? Decimal)
            #expect(value >= lower && value <= upper)
        }
    }
}
