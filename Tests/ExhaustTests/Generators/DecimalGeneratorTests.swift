//
//  DecimalGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Foundation
import Testing

@Suite("Decimal Generator")
struct DecimalGeneratorTests {
    @Suite("Basic generation")
    struct BasicGeneration {
        @Test("Generated values are within range")
        func valuesWithinRange() throws {
            let lower = Decimal(string: "10.00")!
            let upper = Decimal(string: "99.99")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            let values = try #example(gen, count: 50, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }

        @Test("Generated values have correct precision")
        func correctPrecision() throws {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(100), precision: 3))
            let values = try #example(gen, count: 50, seed: 42)

            for value in values {
                // Multiplying by 10^3 should yield an integer
                let scaled = value * 1000
                let rounded = Decimal(Int64(truncating: scaled as NSDecimalNumber))
                #expect(scaled == rounded)
            }
        }

        @Test("Precision 0 produces integer Decimals")
        func integerDecimals() throws {
            let gen = #gen(.decimal(in: Decimal(-50) ... Decimal(50), precision: 0))
            let values = try #example(gen, count: 50, seed: 42)

            for value in values {
                let asInt = Int64(truncating: value as NSDecimalNumber)
                #expect(value == Decimal(asInt))
            }
        }

        @Test("Deterministic: same seed produces same values")
        func deterministic() throws {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(1000), precision: 2))

            let values1 = try #example(gen, count: 20, seed: 99)
            let values2 = try #example(gen, count: 20, seed: 99)
            #expect(values1 == values2)
        }
    }

    @Suite("Edge cases")
    struct EdgeCases {
        @Test("Negative range")
        func negativeRange() throws {
            let lower = Decimal(string: "-100.50")!
            let upper = Decimal(string: "-0.25")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 2))
            let values = try #example(gen, count: 30, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }

        @Test("Single-value range")
        func singleValueRange() throws {
            let value = Decimal(string: "3.14")!
            let gen = #gen(.decimal(in: value ... value, precision: 2))
            let values = try #example(gen, count: 5, seed: 42)

            for generated in values {
                #expect(generated == value)
            }
        }

        @Test("Large range near Int64 boundary stays in range")
        func largeRangeNearInt64Boundary() throws {
            let lower = Decimal(Int64.max - 20)
            let upper = Decimal(Int64.max - 10)
            let gen = #gen(.decimal(in: lower ... upper, precision: 0))
            let values = try #example(gen, count: 20, seed: 42)

            for value in values {
                #expect(value >= lower)
                #expect(value <= upper)
            }
        }

        @Test("Range spanning zero")
        func spanningZero() throws {
            let lower = Decimal(string: "-10.5")!
            let upper = Decimal(string: "10.5")!
            let gen = #gen(.decimal(in: lower ... upper, precision: 1))
            let values = try #example(gen, count: 50, seed: 42)

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
                #exhaust(gen, .suppress(.issueReporting)) { value in value < threshold }
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
                #exhaust(gen, .suppress(.issueReporting)) { value in value < threshold }
            )

            #expect(output == threshold)
        }
    }

    // MARK: - Reflection (backward mapping)

    @Suite("Reflection")
    struct ReflectionTests {
        @Test("Out-of-range decimal reflection clamps to nearest bound")
        func outOfRangeReflectionClamps() throws {
            let gen = #gen(.decimal(in: Decimal(10) ... Decimal(20), precision: 2))
            let outOfRange = Decimal(25)

            let tree = try #require(try Interpreters.reflect(gen.gen, with: outOfRange))
            let replayed = try #require(try Interpreters.replay(gen.gen, using: tree) as Decimal?)
            #expect(replayed == Decimal(20))
        }

        @Test("Off-precision decimal reflection snaps to nearest representable step")
        func offPrecisionReflectionSnaps() throws {
            let gen = #gen(.decimal(in: Decimal(0) ... Decimal(100), precision: 1))
            let offPrecision = Decimal(string: "12.345")!

            let tree = try #require(try Interpreters.reflect(gen.gen, with: offPrecision))
            let replayed = try #require(try Interpreters.replay(gen.gen, using: tree) as Decimal?)
            #expect(replayed == Decimal(string: "12.3")!)
        }

        @Test("In-range on-precision decimal reflection round-trips exactly")
        func onPrecisionRoundTrip() {
            let gen = #gen(.decimal(in: Decimal(10) ... Decimal(20), precision: 2))
            #expect(#examine(gen, .samples(20), .replay(42)).passed)
        }
    }
}
