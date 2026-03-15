//
//  DateGeneratorTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust
import ExhaustCore

@Suite("Date Generator")
struct DateGeneratorTests {
    // MARK: - Fixed reference dates for deterministic tests

    static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    static let jan1_2025 = Date(timeIntervalSinceReferenceDate: 757_382_400) // 2025-01-01 00:00:00 UTC

    // MARK: - date(between:interval:)

    @Suite("date(between:interval:)")
    struct BetweenStride {
        @Test("Generates dates within the specified range")
        func datesWithinRange() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 30) // 30 days
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= lower)
                    #expect(date <= upper)
                }
            }
        }

        @Test("Dates are quantized to stride intervals")
        func datesQuantizedToStride() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 7) // 7 days
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    let offset = date.timeIntervalSinceReferenceDate - lower.timeIntervalSinceReferenceDate
                    #expect(offset.truncatingRemainder(dividingBy: 3600) == 0)
                }
            }
        }

        @Test("Stride of seconds produces integral-second dates")
        func secondStride() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(3600) // 1 hour
            let gen = #gen(.date(between: lower ... upper, interval: .seconds(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let date = try iterator.next() {
                let ti = date.timeIntervalSinceReferenceDate
                #expect(ti == ti.rounded(.down))
            }
        }

        @Test("Deterministic: same seed produces same dates")
        func deterministic() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))

            var iter1 = ValueInterpreter(gen, seed: 99)
            var iter2 = ValueInterpreter(gen, seed: 99)

            for _ in 0 ..< 10 {
                let d1 = try iter1.next()
                let d2 = try iter2.next()
                #expect(d1 == d2)
            }
        }

        @Test("Week stride covers expected range")
        func weekStride() throws {
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 365) // ~1 year
            let gen = #gen(.date(between: lower ... upper, interval: .weeks(1)))
            var iterator = ValueInterpreter(gen, seed: 7)

            if let date = try iterator.next() {
                let offset = date.timeIntervalSince(lower)
                #expect(offset.truncatingRemainder(dividingBy: 604_800) == 0)
            }
        }
    }

    // MARK: - date(within:of:interval:)

    @Suite("date(within:of:interval:)")
    struct WithinSpan {
        @Test("Generates dates within fixed-length span of anchor")
        func fixedSpan() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(30), of: anchor, interval: .hours(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 30)
            let expectedUpper = anchor.addingTimeInterval(86400 * 30)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }

        @Test("Month span produces valid range (30-day months)")
        func monthSpan() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .months(6), of: anchor, interval: .days(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let offsetSeconds: TimeInterval = 6 * 2_592_000 // 6 * 30 days
            let expectedLower = anchor.addingTimeInterval(-offsetSeconds)
            let expectedUpper = anchor.addingTimeInterval(offsetSeconds)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }

        @Test("Year span produces valid range (365-day years)")
        func yearSpan() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .years(1), of: anchor, interval: .days(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let offsetSeconds: TimeInterval = 31_536_000 // 365 days
            let expectedLower = anchor.addingTimeInterval(-offsetSeconds)
            let expectedUpper = anchor.addingTimeInterval(offsetSeconds)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }
    }

    // MARK: - date(within: ClosedRange<DateSpan>, of:interval:)

    @Suite("date(within: ClosedRange<DateSpan>, of:interval:)")
    struct WithinSpanRange {
        @Test("Asymmetric span produces correct bounds")
        func asymmetricSpan() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(-7) ... .days(30), of: anchor, interval: .hours(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 7)
            let expectedUpper = anchor.addingTimeInterval(86400 * 30)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }

        @Test("Past-only range (both bounds negative)")
        func pastOnlyRange() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(-30) ... .days(-1), of: anchor, interval: .hours(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 30)
            let expectedUpper = anchor.addingTimeInterval(-86400)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }

        @Test("Mixed units in range bounds")
        func mixedUnits() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .hours(-12) ... .weeks(2), of: anchor, interval: .minutes(30)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-12 * 3600)
            let expectedUpper = anchor.addingTimeInterval(2 * 604_800)

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    #expect(date >= expectedLower)
                    #expect(date <= expectedUpper)
                }
            }
        }

        @Test("Dates are quantized to interval")
        func quantized() throws {
            let anchor = DateGeneratorTests.epoch
            let gen = #gen(.date(within: .days(-10) ... .days(10), of: anchor, interval: .hours(6)))
            var iterator = ValueInterpreter(gen, seed: 42)

            let lowerSeconds = anchor.addingTimeInterval(-86400 * 10).timeIntervalSinceReferenceDate

            for _ in 0 ..< 20 {
                if let date = try iterator.next() {
                    let offset = date.timeIntervalSinceReferenceDate - lowerSeconds
                    #expect(offset.truncatingRemainder(dividingBy: 6 * 3600) == 0)
                }
            }
        }
    }

    // MARK: - Shrinking

    @Suite("Shrinking")
    struct ShrinkingTests {
        @Test("Shrinks to boundary: date before noon")
        func shrinksToNoonBoundary() throws {
            // Range: Jan 1 – Jan 31 2025, hourly intervals
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 30)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))

            // Cutoff: noon on Jan 15
            let cutoff = lower.addingTimeInterval(86400 * 14 + 3600 * 12)
            let property: (Date) -> Bool = { $0 < cutoff }

            // Generate until we find a failing value
            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
            var failingTree: ChoiceTree?
            for _ in 0 ..< 100 {
                guard let (value, tree) = try iterator.next() else { break }
                if !property(value) {
                    failingTree = tree
                    break
                }
            }
            let tree = try #require(failingTree)

            let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))

            // Should shrink to exactly the cutoff (first failing hour)
            #expect(output == cutoff)
            // Verify it's still on an hourly boundary
            let offset = output.timeIntervalSince(lower)
            #expect(offset.truncatingRemainder(dividingBy: 3600) == 0)
        }

        @Test("Shrinks to boundary: date after a threshold")
        func shrinksToEarliestFailure() throws {
            // Range: full year 2025, daily intervals
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))

            // Property: date must be in the first 100 days
            let threshold = lower.addingTimeInterval(86400 * 100)
            let property: (Date) -> Bool = { $0 < threshold }

            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 1337)
            var failingTree: ChoiceTree?
            for _ in 0 ..< 500 {
                guard let (value, tree) = try iterator.next() else { break }
                if !property(value) {
                    failingTree = tree
                    break
                }
            }
            let tree = try #require(failingTree)

            let (_, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))

            // Should shrink to exactly the threshold (first failing day)
            #expect(output == threshold)
        }
    }

    // MARK: - DateSpan

    @Suite("DateSpan")
    struct DateSpanTests {
        @Test("Fixed spans convert to correct seconds", arguments: [
            (DateSpan.seconds(1), 1),
            (DateSpan.minutes(1), 60),
            (DateSpan.hours(1), 3600),
            (DateSpan.days(1), 86400),
            (DateSpan.weeks(1), 604_800),
            (DateSpan.minutes(5), 300),
            (DateSpan.hours(24), 86400),
            (DateSpan.days(7), 604_800),
            (DateSpan.months(1), 2_592_000),
            (DateSpan.years(1), 31_536_000),
        ])
        func fixedSecondsConversion(span: DateSpan, expectedSeconds: Int) {
            #expect(span.fixedSeconds == expectedSeconds)
        }
    }

    // MARK: - Reflection (backward mapping)

    @Suite("Reflection")
    struct ReflectionTests {
        @Test("Backward mapping round-trips through forward")
        func roundTrip() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))
            var iterator = ValueInterpreter(gen, seed: 42)

            if let date = try iterator.next() {
                let offset = date.timeIntervalSince(lower)
                #expect(offset.truncatingRemainder(dividingBy: 3600) == 0)
            }
        }
    }
}
