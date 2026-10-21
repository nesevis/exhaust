//
//  DecimalGeneratorTests.swift
//  Exhaust
//

import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Decimal Generator")
struct DecimalGeneratorTests {
    @Test("Decimal bounds and precision hold for boundary fixtures", arguments: decimalDomains)
    func boundaryContracts(domain: DecimalDomain) throws {
        let values = try #example(.decimal(in: domain.range, precision: domain.precision), count: 50, seed: 42)
        #expect(values.count == 50)
        for value in values {
            #expect(domain.range.contains(value))
            #expect(hasPrecision(value, digits: domain.precision))
        }
    }

    @Test("Decimal bounds and precision hold for generated domains")
    func generatedDomains() {
        // Integral ticks construct aligned endpoints; bounded widths keep sampling inexpensive.
        let domains = #gen(.int(in: -100_000 ... 100_000), .int(in: 0 ... 100_000), .int(in: 0 ... 4))
        #exhaust(domains) { lowerTicks, width, precision in
            let scale = pow(Decimal(10), precision)
            let range = (Decimal(lowerTicks) / scale) ... (Decimal(lowerTicks + width) / scale)
            let values = try #example(.decimal(in: range, precision: precision), count: 20, seed: 42)
            #expect(values.count == 20)
            for value in values {
                #expect(range.contains(value))
                #expect(hasPrecision(value, digits: precision))
            }
        }
    }

    @Test("The same seed reproduces decimal samples")
    func deterministic() throws {
        let generator = #gen(.decimal(in: Decimal(0) ... Decimal(1000), precision: 2))
        let first = try #example(generator, count: 20, seed: 99)
        let second = try #example(generator, count: 20, seed: 99)
        #expect(first.count == 20)
        #expect(first == second)
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

// MARK: - Domains

struct DecimalDomain: Sendable {
    let range: ClosedRange<Decimal>
    let precision: Int
}

private let decimalDomains = [
    DecimalDomain(range: Decimal(string: "10.00")! ... Decimal(string: "99.99")!, precision: 2),
    DecimalDomain(range: Decimal(0) ... Decimal(100), precision: 3),
    DecimalDomain(range: Decimal(-50) ... Decimal(50), precision: 0),
    DecimalDomain(range: Decimal(string: "-100.50")! ... Decimal(string: "-0.25")!, precision: 2),
    DecimalDomain(range: Decimal(string: "3.14")! ... Decimal(string: "3.14")!, precision: 2),
    DecimalDomain(range: Decimal(Int64.max - 20) ... Decimal(Int64.max - 10), precision: 0),
    DecimalDomain(range: Decimal(string: "-10.5")! ... Decimal(string: "10.5")!, precision: 1),
]

private func hasPrecision(_ value: Decimal, digits: Int) -> Bool {
    var scaled = value * pow(Decimal(10), digits)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return scaled == rounded
}
