//
//  DecimalGeneratorTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Decimal Generator")
struct DecimalGeneratorTests {
    @Suite("Basic generation")
    struct BasicGeneration {
        @Test("Generated values are within range")
        func valuesWithinRange() throws {
            let lower = Decimal(string: "10.00")!
            let upper = Decimal(string: "99.99")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 50 {
                if let value = try iterator.next() {
                    #expect(value >= lower)
                    #expect(value <= upper)
                }
            }
        }

        @Test("Generated values have correct precision")
        func correctPrecision() throws {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(100), precision: 3))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 50 {
                if let value = try iterator.next() {
                    // Multiplying by 10^3 should yield an integer
                    let scaled = value * 1000
                    let rounded = Decimal(Int64(truncating: scaled as NSDecimalNumber))
                    #expect(scaled == rounded)
                }
            }
        }

        @Test("Precision 0 produces integer Decimals")
        func integerDecimals() throws {
            let gen = #gen(.decimal(in: Decimal(-50) ... Decimal(50), precision: 0))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 50 {
                if let value = try iterator.next() {
                    let asInt = Int64(truncating: value as NSDecimalNumber)
                    #expect(value == Decimal(asInt))
                }
            }
        }

        @Test("Deterministic: same seed produces same values")
        func deterministic() throws {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(1000), precision: 2))

            var iter1 = ValueInterpreter(gen, seed: 99)
            var iter2 = ValueInterpreter(gen, seed: 99)

            for _ in 0 ..< 20 {
                let v1 = try iter1.next()
                let v2 = try iter2.next()
                #expect(v1 == v2)
            }
        }
    }

    @Suite("Edge cases")
    struct EdgeCases {
        @Test("Negative range")
        func negativeRange() throws {
            let lower = Decimal(string: "-100.50")!
            let upper = Decimal(string: "-0.25")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 30 {
                if let value = try iterator.next() {
                    #expect(value >= lower)
                    #expect(value <= upper)
                }
            }
        }

        @Test("Single-value range")
        func singleValueRange() throws {
            let value = Decimal(string: "3.14")!
            let gen = #gen(.decimal(in: value ... value, precision: 2))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 5 {
                if let generated = try iterator.next() {
                    #expect(generated == value)
                }
            }
        }

        @Test("Range spanning zero")
        func spanningZero() throws {
            let lower = Decimal(string: "-10.5")!
            let upper = Decimal(string: "10.5")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 1))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 50 {
                if let value = try iterator.next() {
                    #expect(value >= lower)
                    #expect(value <= upper)
                }
            }
        }
    }

    @Suite("Shrinking")
    struct ShrinkingTests {
        @Test("Shrinks toward zero when zero is in range")
        func shrinksTowardZero() throws {
            let gen = #gen(.decimal(in: Decimal(-100) ... Decimal(100), precision: 2))

            let threshold = Decimal(string: "50.00")!
            let property: (Decimal) -> Bool = { $0 < threshold }

            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
            var failingTree: ChoiceTree?
            for _ in 0 ..< 200 {
                guard let (value, tree) = try iterator.next() else { break }
                if !property(value) {
                    failingTree = tree
                    break
                }
            }
            let tree = try #require(failingTree)

            let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))

            // Should shrink to exactly the threshold (smallest failing value)
            #expect(output == threshold)
        }

        @Test("Shrinks toward lower bound when zero is not in range")
        func shrinksTowardLowerBound() throws {
            let lower = Decimal(string: "10.00")!
            let upper = Decimal(string: "100.00")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))

            let threshold = Decimal(string: "50.00")!
            let property: (Decimal) -> Bool = { $0 < threshold }

            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
            var failingTree: ChoiceTree?
            for _ in 0 ..< 200 {
                guard let (value, tree) = try iterator.next() else { break }
                if !property(value) {
                    failingTree = tree
                    break
                }
            }
            let tree = try #require(failingTree)

            let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))

            #expect(output == threshold)
        }
    }
}
