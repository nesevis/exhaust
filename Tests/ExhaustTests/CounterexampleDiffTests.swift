//
//  CounterexampleDiffTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 23/2/2026.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("CounterexampleDiff")
struct CounterexampleDiffTests {
    private final class Person {
        init(name: String, age: Int, scores: [Int]) {
            self.name = name
            self.age = age
            self.scores = scores
        }

        var name: String
        var age: Int
        var scores: [Int]
    }

    private struct Address {
        var city: String
        var zip: Int
    }

    private struct PersonWithAddress {
        var name: String
        var address: Address
    }

    @Test("Flat struct shows changed fields only")
    func flatStructDiff() {
        let original = Person(name: "zqmfkwvxl", age: 42, scores: [88, 12, 71, 44])
        let shrunk = Person(name: "a", age: 1, scores: [3])

        let result = CounterexampleDiff.format(original: original, shrunk: shrunk)
        print(result)

        #expect(result.contains("name:"))
        #expect(result.contains("a \u{2190} zqmfkwvxl"))
        #expect(result.contains("age:"))
        #expect(result.contains("1 \u{2190} 42"))
        #expect(result.contains("scores:"))
        #expect(result.contains("[3] \u{2190} [88, 12, 71, 44]"))
    }

    @Test("Unchanged fields are omitted")
    func unchangedFieldsOmitted() {
        let original = Person(name: "same", age: 42, scores: [1])
        let shrunk = Person(name: "same", age: 1, scores: [1])

        let result = CounterexampleDiff.format(original: original, shrunk: shrunk)

        #expect(!result.contains("name:"))
        #expect(!result.contains("scores:"))
        #expect(result.contains("age:"))
    }

    @Test("Nested struct uses dotted paths")
    func nestedStructDottedPaths() {
        let original = PersonWithAddress(name: "Alice", address: Address(city: "New York", zip: 10001))
        let shrunk = PersonWithAddress(name: "Alice", address: Address(city: "a", zip: 0))

        let result = CounterexampleDiff.format(original: original, shrunk: shrunk)

        #expect(result.contains("address.city:"))
        #expect(result.contains("address.zip:"))
        #expect(!result.contains("name:"))
    }

    @Test("Identical values produce no visible change message")
    func identicalValues() {
        let value = Person(name: "a", age: 1, scores: [])
        let result = CounterexampleDiff.format(original: value, shrunk: value)

        #expect(result.contains("(no visible change)"))
    }

    @Test("Non-struct types use inline fallback format")
    func fallbackForNonStruct() {
        let result = CounterexampleDiff.format(original: 42, shrunk: 1)

        #expect(result.contains("1 \u{2190} 42"))
    }

    @Test("Tuples use inline fallback format")
    func fallbackForTuples() {
        let result = CounterexampleDiff.format(original: (1, "hello"), shrunk: (0, "a"))

        #expect(result.contains("\u{2190}"))
    }
}
