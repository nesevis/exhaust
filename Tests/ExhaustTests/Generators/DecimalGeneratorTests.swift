//
//  DecimalGeneratorTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Decimal Generator")
struct DecimalGeneratorTests {
    @Suite("Basic generation")
    struct BasicGeneration {
        @Test("Generated values are within range")
        func valuesWithinRange() {
            let lower = Decimal(string: "10.00")!
            let upper = Decimal(string: "99.99")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            let values = #example(gen, count: 50, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }

        @Test("Generated values have correct precision")
        func correctPrecision() {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(100), precision: 3))
            let values = #example(gen, count: 50, seed: 42)

            for value in values {
                // Multiplying by 10^3 should yield an integer
                let scaled = value * 1000
                let rounded = Decimal(Int64(truncating: scaled as NSDecimalNumber))
                #expect(scaled == rounded)
            }
        }

        @Test("Precision 0 produces integer Decimals")
        func integerDecimals() {
            let gen = #gen(.decimal(in: Decimal(-50) ... Decimal(50), precision: 0))
            let values = #example(gen, count: 50, seed: 42)

            for value in values {
                let asInt = Int64(truncating: value as NSDecimalNumber)
                #expect(value == Decimal(asInt))
            }
        }

        @Test("Deterministic: same seed produces same values")
        func deterministic() {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(1000), precision: 2))

            let values1 = #example(gen, count: 20, seed: 99)
            let values2 = #example(gen, count: 20, seed: 99)
            #expect(values1 == values2)
        }
    }

    @Suite("Edge cases")
    struct EdgeCases {
        @Test("Negative range")
        func negativeRange() {
            let lower = Decimal(string: "-100.50")!
            let upper = Decimal(string: "-0.25")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            let values = #example(gen, count: 30, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }

        @Test("Single-value range")
        func singleValueRange() {
            let value = Decimal(string: "3.14")!
            let gen = #gen(.decimal(in: value ... value, precision: 2))
            let values = #example(gen, count: 5, seed: 42)

            for generated in values {
                #expect(generated == value)
            }
        }

        @Test("Range spanning zero")
        func spanningZero() {
            let lower = Decimal(string: "-10.5")!
            let upper = Decimal(string: "10.5")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 1))
            let values = #example(gen, count: 50, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }
    }

    @Suite("Shrinking")
    struct ShrinkingTests {
        @Test("Shrinks toward zero when zero is in range")
        func shrinksTowardZero() throws {
            let gen = #gen(.decimal(in: Decimal(-100) ... Decimal(100), precision: 2))
            let threshold = Decimal(string: "50.00")!

            let output = try #require(
                #exhaust(gen, .suppressIssueReporting) { value in value < threshold }
            )

            // Should shrink to exactly the threshold (smallest failing value)
            #expect(output == threshold)
        }

        @Test("Shrinks toward lower bound when zero is not in range")
        func shrinksTowardLowerBound() throws {
            let lower = Decimal(string: "10.00")!
            let upper = Decimal(string: "100.00")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            let threshold = Decimal(string: "50.00")!

            let output = try #require(
                #exhaust(gen, .suppressIssueReporting) { value in value < threshold }
            )

            #expect(output == threshold)
        }
    }
}
